//! High-level Nostr relay client used by `carl search`, `carl seed`, and the
//! `--nostr-relay` integration in `carl download`. Wraps the lower-level
//! ws.Conn + nostr message codec into the synchronous "subscribe and collect
//! until EOSE" and "publish and wait for OK" patterns carl uses.
//!
//! The simple mode (single relay, blocking) is what `carl search` uses. A
//! multi-relay fan-out builds on top.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ws = @import("ws.zig");
const proxy_mod = @import("proxy.zig");
const nostr = @import("nostr.zig");

const log = std.log.scoped(.relay);

pub const Error = error{
    ConnectFailed,
    PublishFailed,
    SubscribeFailed,
    NotConnected,
    /// The shared health table says this relay is in backoff (or its URL is
    /// unusable), so the dial was never attempted. Callers skip to the next one.
    Skipped,
    OutOfMemory,
} || ws.Error || nostr.Error;

// ===========================================================================
// Per-relay connect health
// ===========================================================================
// Every subsystem that dials relays (the daemon's prober, the GUI search, the
// manager's peer discovery and completion broadcast, `seeding.publish`, the
// follow poller) shares one table keyed by relay URL. A relay that fails is
// backed off individually, so a permanently-503 relay stops being hammered
// even while its neighbours answer fine -- the exact hole in the old global
// "were ALL relays down this cycle?" streak, which a single healthy relay
// reset forever.

/// Why a relay is not dialable right now.
pub const Skip = enum {
    /// Dialable.
    none,
    /// Recent transient failure(s); wait out the backoff.
    backoff,
    /// The URL itself is unusable (won't parse). Permanent until the config
    /// changes -- retrying can only ever fail the same way.
    invalid,
};

/// How a dial ended, from the health table's point of view.
pub const Failure = enum {
    /// DNS/TCP/TLS/handshake failure, a 503 from the CDN in front of the
    /// relay, ... -- it may well work later, so back off and retry.
    transient,
    /// The URL can't be dialed at all. No amount of retrying helps.
    invalid,
};

/// First backoff step after a failed dial, and the ceiling it doubles to.
pub const backoff_base_ms: i64 = 30 * std.time.ms_per_s;
pub const backoff_max_ms: i64 = 5 * 60 * std.time.ms_per_s;

/// Backoff for the `fails`th consecutive failure: 30s, 60s, 120s, 240s, then
/// 300s forever (the cap). Zero failures means "dial now".
pub fn backoffMs(fails: u32) i64 {
    if (fails == 0) return 0;
    // Clamp the shift well before it could overflow the i64; the cap below
    // makes anything past the 4th step identical anyway.
    const shift: u6 = @intCast(@min(fails - 1, 8));
    return @min(backoff_base_ms << shift, backoff_max_ms);
}

/// The state machine for one relay. Default = healthy, dial away.
pub const RelayHealth = struct {
    /// Consecutive transient failures since the last success.
    fails: u32 = 0,
    /// Wall-clock ms before which the relay is skipped. 0 = dialable now.
    until_ms: i64 = 0,
    /// URL is structurally unusable; skip until the config changes.
    invalid: bool = false,

    pub fn skip(self: RelayHealth, now_ms: i64) Skip {
        if (self.invalid) return .invalid;
        if (now_ms < self.until_ms) return .backoff;
        return .none;
    }

    /// A successful dial clears everything, including the `invalid` flag (the
    /// config must have changed for the dial to have worked at all).
    pub fn onSuccess(self: *RelayHealth) void {
        self.* = .{};
    }

    pub fn onFailure(self: *RelayHealth, now_ms: i64, class: Failure) void {
        switch (class) {
            .invalid => {
                self.invalid = true;
                self.fails = 0;
                self.until_ms = 0;
            },
            .transient => {
                self.fails +|= 1;
                self.until_ms = now_ms + backoffMs(self.fails);
            },
        }
    }
};

/// Health for every relay URL carl has dialed. Guarded by its own mutex: the
/// prober, the session threads, and the daemon's request threads all touch it.
pub const HealthTable = struct {
    allocator: Allocator,
    mutex: std.Thread.Mutex = .{},
    map: std.StringHashMapUnmanaged(RelayHealth) = .empty,

    /// Upper bound on tracked relays. The configured set is a handful of URLs;
    /// the cap just keeps a pathological config (or a churn of edited relay
    /// lists) from growing the table without limit. Past it, new relays are
    /// simply untracked (always dialable) rather than evicting live state.
    const max_entries: usize = 64;

    pub fn deinit(self: *HealthTable) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.map.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.map.deinit(self.allocator);
        self.map = .empty;
    }

    pub fn skipAt(self: *HealthTable, url: []const u8, now_ms: i64) Skip {
        self.mutex.lock();
        defer self.mutex.unlock();
        const e = self.map.get(url) orelse return .none;
        return e.skip(now_ms);
    }

    pub fn skip(self: *HealthTable, url: []const u8) Skip {
        return self.skipAt(url, std.time.milliTimestamp());
    }

    /// Clear this relay's backoff. Untracked relays are healthy by definition,
    /// so a success on one allocates nothing.
    pub fn recordSuccess(self: *HealthTable, url: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const e = self.map.getPtr(url) orelse return;
        // Say so when a relay comes back, otherwise recovery is invisible in
        // the log (successes are silent) and a later first-failure line looks
        // like the backoff forgot its history.
        if (e.fails > 0 or e.invalid) log.info("relay {s}: reachable again", .{url});
        e.onSuccess();
    }

    pub fn recordFailureAt(self: *HealthTable, url: []const u8, class: Failure, now_ms: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var e: RelayHealth = self.map.get(url) orelse blk: {
            if (self.map.count() >= max_entries) return;
            break :blk .{};
        };
        const first = e.fails == 0 and !e.invalid;
        e.onFailure(now_ms, class);

        const key = self.map.getKey(url) orelse (self.allocator.dupe(u8, url) catch return);
        self.map.put(self.allocator, key, e) catch {
            // Only reachable when the key was freshly duped and the put OOM'd.
            if (self.map.getKey(url) == null) self.allocator.free(key);
            return;
        };

        // Log the transition once, then stay quiet: a relay that is down for an
        // hour should cost a handful of lines, not one per attempt.
        if (first) {
            switch (class) {
                .invalid => log.warn("relay {s}: unusable URL, not dialing again until the config changes", .{url}),
                .transient => log.info("relay {s}: unreachable, backing off {d}s", .{ url, @divTrunc(backoffMs(e.fails), std.time.ms_per_s) }),
            }
        } else {
            switch (class) {
                // An unusable URL has no backoff (fails stays 0); saying
                // "backing off 0s" here made the skip logic look broken.
                .invalid => log.debug("relay {s}: still unusable, waiting for a config change", .{url}),
                .transient => log.debug("relay {s}: still failing, backing off {d}s", .{ url, @divTrunc(backoffMs(e.fails), std.time.ms_per_s) }),
            }
        }
    }

    pub fn recordFailure(self: *HealthTable, url: []const u8, class: Failure) void {
        self.recordFailureAt(url, class, std.time.milliTimestamp());
    }
};

/// The process-wide table. One instance so a failure observed by the prober
/// also holds back peer discovery, publishing, and the follow poller. Keys are
/// duped from the page allocator and live for the process; the set is bounded
/// by `HealthTable.max_entries`.
var global_health: HealthTable = .{ .allocator = std.heap.page_allocator };

pub fn health() *HealthTable {
    return &global_health;
}

/// Whether a caller honors the health table.
pub const Gate = enum {
    /// Background/periodic caller (the prober, peer re-discovery, the follow
    /// poller): honor the skip list. These run again on their own schedule, so
    /// skipping a relay costs nothing but the politeness it buys.
    honor,
    /// One-shot operation whose only alternative is doing nothing at all (an
    /// explicit publish, a user's search when every relay happens to be backed
    /// off): dial anyway. The outcome is still recorded.
    force,
};

/// Gate for a one-shot operation over `urls`: honor the skip list as long as it
/// leaves at least one relay to talk to, otherwise force the dial. This is what
/// keeps the skip list from silently turning a publish or a search into a
/// no-op when every relay happens to be in backoff.
pub fn oneShotGate(urls: []const []const u8) Gate {
    return gateFor(health(), urls, std.time.milliTimestamp());
}

fn gateFor(table: *HealthTable, urls: []const []const u8, now_ms: i64) Gate {
    for (urls) |u| {
        if (table.skipAt(u, now_ms) == .none) return .honor;
    }
    return .force;
}

/// `Relay.connect` behind the shared health gate. Returns `error.Skipped`
/// without touching the network when `gate` is `.honor` and the relay is
/// backing off (or its URL is unusable).
pub fn dial(allocator: Allocator, url: []const u8, proxy: ?proxy_mod.Proxy, gate: Gate) Error!Relay {
    if (gate == .honor) {
        switch (health().skip(url)) {
            .none => {},
            .backoff => {
                log.debug("relay {s}: skipped, backing off", .{url});
                return error.Skipped;
            },
            .invalid => {
                log.debug("relay {s}: skipped, unusable URL", .{url});
                return error.Skipped;
            },
        }
    }
    return Relay.connect(allocator, url, proxy);
}

/// A URL we can't even parse will never work until the config changes;
/// everything else (DNS, TCP, TLS, a 503 from the CDN in front of the relay)
/// might come back.
fn classify(err: ws.Error) Failure {
    return switch (err) {
        error.InvalidUrl => .invalid,
        else => .transient,
    };
}

/// One relay connection.
pub const Relay = struct {
    allocator: Allocator,
    url: []const u8, // borrowed
    conn: ws.Conn,

    /// Dial `url`, recording the outcome in the shared health table. This is
    /// the unconditional dial; `dial()` above adds the skip gate on top. Both
    /// record, so even the CLI's one-shot commands teach the table.
    pub fn connect(allocator: Allocator, url: []const u8, proxy: ?proxy_mod.Proxy) Error!Relay {
        // Relay traffic is tunneled through `--proxy` so the relay never sees our
        // real IP -- `ws://` rides the SOCKS tunnel directly (e.g. an onion
        // relay; Tor secures it), `wss://` runs cert-verified TLS on top of the
        // proxied stream (the proxy only ever sees ciphertext).
        const conn = ws.Conn.connect(allocator, url, .{ .proxy = proxy }) catch |err| {
            log.debug("relay connect to {s} failed: {}", .{ url, err });
            health().recordFailure(url, classify(err));
            return error.ConnectFailed;
        };
        health().recordSuccess(url);
        return .{ .allocator = allocator, .url = url, .conn = conn };
    }

    pub fn deinit(self: *Relay) void {
        self.conn.writeClose() catch {};
        self.conn.deinit();
    }

    /// Subscribe with `filters` under `sub_id`. Returns when the REQ is on the wire.
    pub fn subscribe(self: *Relay, sub_id: []const u8, filters: []const nostr.Filter) Error!void {
        const msg = try nostr.encodeReq(self.allocator, sub_id, filters);
        defer self.allocator.free(msg);
        self.conn.writeText(msg) catch return error.SubscribeFailed;
    }

    pub fn close(self: *Relay, sub_id: []const u8) Error!void {
        const msg = try nostr.encodeClose(self.allocator, sub_id);
        defer self.allocator.free(msg);
        self.conn.writeText(msg) catch return error.SubscribeFailed;
    }

    pub fn publish(self: *Relay, event: nostr.Event) Error!void {
        const msg = try nostr.encodeEvent(self.allocator, event);
        defer self.allocator.free(msg);
        self.conn.writeText(msg) catch return error.PublishFailed;
    }

    /// Read the next relay message. Caller owns the returned RelayMessage and
    /// must call `.deinit(allocator)` when done.
    pub fn read(self: *Relay) Error!nostr.RelayMessage {
        const msg = self.conn.readMessage() catch |err| switch (err) {
            error.Closed => return error.NotConnected,
            error.Timeout => return error.NotConnected,
            else => return error.SubscribeFailed,
        };
        defer self.allocator.free(msg.payload);
        return try nostr.parseRelayMessage(self.allocator, msg.payload);
    }
};

/// Search options for `searchTorrents` / `subscribeAndCollect`.
pub const SearchOptions = struct {
    /// Hard timeout for waiting on EOSE or events. Use 0 for no limit.
    timeout_ms: u64 = 15_000,
    /// Max events to collect before stopping (defends against malicious relays).
    max_events: usize = 1_000,
    /// If true, require Schnorr signature verification on every event.
    verify_signatures: bool = true,
};

/// Subscribe to one relay with the given filter, collecting matching events
/// until EOSE or timeout. Returns a slice of verified events; caller frees
/// each event via `.deinit(allocator)` and the outer slice via `allocator.free`.
pub fn subscribeAndCollect(
    allocator: Allocator,
    relay: *Relay,
    filter: nostr.Filter,
    opts: SearchOptions,
) Error![]nostr.Event {
    var sub_id_buf: [16]u8 = undefined;
    std.crypto.random.bytes(sub_id_buf[0..8]);
    var sub_id_hex: [16]u8 = undefined;
    const hex = "0123456789abcdef";
    for (sub_id_buf[0..8], 0..) |b, i| {
        sub_id_hex[i * 2] = hex[b >> 4];
        sub_id_hex[i * 2 + 1] = hex[b & 0x0F];
    }
    const sub_id: []const u8 = &sub_id_hex;

    // Tighten the underlying socket's recv timeout so opts.timeout_ms is a
    // true upper bound, not just a soft per-iteration check. Without this,
    // a relay that opens then goes silent could keep us inside a single
    // recv() for ws.Conn's whole default recv timeout (20-30 s), even when the
    // caller asked for a shorter budget.
    if (opts.timeout_ms > 0) {
        const tv: std.posix.timeval = .{
            .sec = @intCast(opts.timeout_ms / 1000),
            .usec = @intCast((opts.timeout_ms % 1000) * 1000),
        };
        std.posix.setsockopt(
            relay.conn.stream.handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            std.mem.asBytes(&tv),
        ) catch {};
    }

    try relay.subscribe(sub_id, &[_]nostr.Filter{filter});

    const start = std.time.milliTimestamp();
    var events: std.ArrayList(nostr.Event) = .empty;
    errdefer {
        for (events.items) |e| e.deinit(allocator);
        events.deinit(allocator);
    }

    while (true) {
        if (opts.timeout_ms > 0) {
            const elapsed = std.time.milliTimestamp() - start;
            if (elapsed > @as(i64, @intCast(opts.timeout_ms))) {
                log.info("relay {s}: timeout after {d}ms", .{ relay.url, elapsed });
                break;
            }
        }

        const msg = relay.read() catch |err| {
            log.warn("relay {s}: read failed: {}", .{ relay.url, err });
            break;
        };

        switch (msg) {
            .event => |e| {
                defer allocator.free(e.sub_id);
                if (!std.mem.eql(u8, e.sub_id, sub_id)) {
                    e.event.deinit(allocator);
                    continue;
                }
                // Cap-check BEFORE signature verification so a relay that
                // floods us with events can't make us burn O(N) Schnorr
                // verifications past the max we're willing to collect.
                if (events.items.len >= opts.max_events) {
                    e.event.deinit(allocator);
                    break;
                }
                if (opts.verify_signatures and !nostr.verify(e.event, allocator)) {
                    log.debug("relay {s}: dropped event with bad signature", .{relay.url});
                    e.event.deinit(allocator);
                    continue;
                }
                events.append(allocator, e.event) catch {
                    e.event.deinit(allocator);
                    return error.OutOfMemory;
                };
            },
            .eose => |s| {
                defer allocator.free(s);
                if (std.mem.eql(u8, s, sub_id)) break;
            },
            .ok => |o| {
                allocator.free(o.event_id_hex);
                allocator.free(o.message);
            },
            .notice => |n| {
                log.info("relay {s} NOTICE: {s}", .{ relay.url, n });
                allocator.free(n);
            },
            .closed => |c| {
                defer allocator.free(c.sub_id);
                defer allocator.free(c.message);
                if (std.mem.eql(u8, c.sub_id, sub_id)) {
                    log.warn("relay {s} closed sub: {s}", .{ relay.url, c.message });
                    break;
                }
            },
            .auth => |challenge| allocator.free(challenge),
        }
    }

    relay.close(sub_id) catch {};
    return events.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

/// Publish an event to a single relay and wait for the relay's OK response
/// (or timeout). Returns true if the relay accepted the event.
pub fn publishAndWait(
    allocator: Allocator,
    relay: *Relay,
    event: nostr.Event,
    timeout_ms: u64,
) bool {
    relay.publish(event) catch return false;

    var event_id_hex: [nostr.event_id_len * 2]u8 = undefined;
    const hex = "0123456789abcdef";
    for (event.id, 0..) |b, i| {
        event_id_hex[i * 2] = hex[b >> 4];
        event_id_hex[i * 2 + 1] = hex[b & 0x0F];
    }

    const start = std.time.milliTimestamp();
    while (true) {
        if (timeout_ms > 0) {
            const elapsed = std.time.milliTimestamp() - start;
            if (elapsed > @as(i64, @intCast(timeout_ms))) return false;
        }
        const msg = relay.read() catch return false;
        defer msg.deinit(allocator);

        switch (msg) {
            .ok => |o| {
                if (std.mem.eql(u8, o.event_id_hex, &event_id_hex)) {
                    if (!o.accepted) {
                        log.warn("relay {s} rejected event: {s}", .{ relay.url, o.message });
                    }
                    return o.accepted;
                }
            },
            .notice => |n| log.info("relay {s} NOTICE: {s}", .{ relay.url, n }),
            else => {}, // ignore unrelated traffic
        }
    }
}

/// Default relay set used when the user doesn't provide one explicitly. These
/// are well-known public Nostr relays.
pub const default_relays: []const []const u8 = &.{
    "wss://relay.damus.io",
    "wss://nos.lol",
    "wss://relay.nostr.band",
};

// ===========================================================================
// Tests
// ===========================================================================
// Relay & subscribeAndCollect themselves can't be tested without a live
// network or a mock relay (deferred to a follow-up); the unit tests here
// cover what's testable in isolation.

test "default_relays is non-empty and all wss://" {
    try std.testing.expect(default_relays.len >= 1);
    for (default_relays) |r| try std.testing.expect(std.mem.startsWith(u8, r, "wss://"));
}

test "backoffMs: 30s doubling, capped at 5 minutes" {
    try std.testing.expectEqual(@as(i64, 0), backoffMs(0));
    try std.testing.expectEqual(@as(i64, 30_000), backoffMs(1));
    try std.testing.expectEqual(@as(i64, 60_000), backoffMs(2));
    try std.testing.expectEqual(@as(i64, 120_000), backoffMs(3));
    try std.testing.expectEqual(@as(i64, 240_000), backoffMs(4));
    // 5th step would be 480s; the cap holds it at 300s from here on.
    try std.testing.expectEqual(backoff_max_ms, backoffMs(5));
    try std.testing.expectEqual(backoff_max_ms, backoffMs(1000));
}

test "RelayHealth: fresh relay is dialable" {
    const h: RelayHealth = .{};
    try std.testing.expectEqual(Skip.none, h.skip(0));
    try std.testing.expectEqual(Skip.none, h.skip(1_000_000));
}

test "RelayHealth: transient failure backs off, then becomes dialable again" {
    var h: RelayHealth = .{};
    h.onFailure(1_000, .transient);
    try std.testing.expectEqual(Skip.backoff, h.skip(1_000));
    try std.testing.expectEqual(Skip.backoff, h.skip(30_999));
    // The deadline itself is not "before", so the relay is dialable again.
    try std.testing.expectEqual(Skip.none, h.skip(31_000));

    // Second consecutive failure doubles the wait.
    h.onFailure(31_000, .transient);
    try std.testing.expectEqual(@as(u32, 2), h.fails);
    try std.testing.expectEqual(Skip.backoff, h.skip(90_999));
    try std.testing.expectEqual(Skip.none, h.skip(91_000));
}

test "RelayHealth: success resets the backoff immediately" {
    var h: RelayHealth = .{};
    h.onFailure(0, .transient);
    h.onFailure(30_000, .transient);
    h.onFailure(90_000, .transient);
    try std.testing.expectEqual(Skip.backoff, h.skip(90_001));
    h.onSuccess();
    try std.testing.expectEqual(Skip.none, h.skip(90_001));
    try std.testing.expectEqual(@as(u32, 0), h.fails);
    // ...and the next failure starts again at the first step, not the cap.
    h.onFailure(90_001, .transient);
    try std.testing.expectEqual(@as(i64, 90_001 + 30_000), h.until_ms);
}

test "RelayHealth: invalid is permanent until the config changes" {
    var h: RelayHealth = .{};
    h.onFailure(0, .invalid);
    try std.testing.expectEqual(Skip.invalid, h.skip(0));
    // No deadline can expire it -- a year later it is still skipped.
    try std.testing.expectEqual(Skip.invalid, h.skip(365 * 24 * 3600 * 1000));
    // A dial that somehow succeeds (the user fixed the URL) clears it.
    h.onSuccess();
    try std.testing.expectEqual(Skip.none, h.skip(0));
}

test "RelayHealth: invalid wins over a pending backoff" {
    var h: RelayHealth = .{};
    h.onFailure(0, .transient);
    h.onFailure(0, .invalid);
    try std.testing.expectEqual(Skip.invalid, h.skip(10_000_000));
}

test "classify: only an unparseable URL is permanent" {
    try std.testing.expectEqual(Failure.invalid, classify(error.InvalidUrl));
    try std.testing.expectEqual(Failure.transient, classify(error.ConnectFailed));
    try std.testing.expectEqual(Failure.transient, classify(error.HandshakeFailed)); // the 503-from-Cloudflare case
    try std.testing.expectEqual(Failure.transient, classify(error.DnsResolveFailed));
    try std.testing.expectEqual(Failure.transient, classify(error.Timeout));
}

test "HealthTable: tracks relays independently" {
    var t: HealthTable = .{ .allocator = std.testing.allocator };
    defer t.deinit();

    // One relay 503s forever while its neighbour answers: the healthy one must
    // not reset the failing one's backoff (the bug this whole thing fixes).
    t.recordFailureAt("wss://relay.damus.io", .transient, 0);
    t.recordSuccess("wss://nos.lol");
    try std.testing.expectEqual(Skip.backoff, t.skipAt("wss://relay.damus.io", 0));
    try std.testing.expectEqual(Skip.none, t.skipAt("wss://nos.lol", 0));

    // Repeated failures keep growing that one relay's wait.
    t.recordFailureAt("wss://relay.damus.io", .transient, 30_000);
    try std.testing.expectEqual(Skip.backoff, t.skipAt("wss://relay.damus.io", 89_999));
    try std.testing.expectEqual(Skip.none, t.skipAt("wss://relay.damus.io", 90_000));

    // And a success wipes it.
    t.recordSuccess("wss://relay.damus.io");
    try std.testing.expectEqual(Skip.none, t.skipAt("wss://relay.damus.io", 0));
}

test "HealthTable: unknown relays are dialable and cost nothing" {
    var t: HealthTable = .{ .allocator = std.testing.allocator };
    defer t.deinit();
    try std.testing.expectEqual(Skip.none, t.skipAt("wss://never.seen", 0));
    t.recordSuccess("wss://never.seen"); // must not allocate an entry
    try std.testing.expectEqual(@as(usize, 0), t.map.count());
}

test "HealthTable: invalid URLs stay skipped" {
    var t: HealthTable = .{ .allocator = std.testing.allocator };
    defer t.deinit();
    t.recordFailureAt("ftp://nope", .invalid, 0);
    try std.testing.expectEqual(Skip.invalid, t.skipAt("ftp://nope", 0));
    try std.testing.expectEqual(Skip.invalid, t.skipAt("ftp://nope", backoff_max_ms * 100));
}

test "gateFor: honors the skip list until it would silence every relay" {
    var t: HealthTable = .{ .allocator = std.testing.allocator };
    defer t.deinit();
    const urls = [_][]const u8{ "wss://relay.damus.io", "wss://nos.lol" };

    // All healthy -> honor.
    try std.testing.expectEqual(Gate.honor, gateFor(&t, &urls, 0));

    // One backing off, one fine -> still honor (the publish reaches nos.lol).
    t.recordFailureAt("wss://relay.damus.io", .transient, 0);
    try std.testing.expectEqual(Gate.honor, gateFor(&t, &urls, 0));

    // Every relay unusable -> force, so a one-shot publish/search still tries
    // instead of silently doing nothing.
    t.recordFailureAt("wss://nos.lol", .invalid, 0);
    try std.testing.expectEqual(Gate.force, gateFor(&t, &urls, 0));

    // Once the backoff expires the healthy-again relay pulls it back to honor.
    try std.testing.expectEqual(Gate.honor, gateFor(&t, &urls, 30_000));

    // An empty relay list has nothing to protect; force is the harmless answer.
    try std.testing.expectEqual(Gate.force, gateFor(&t, &.{}, 0));
}

test "SearchOptions defaults are sensible" {
    const opts: SearchOptions = .{};
    // Default timeout long enough to round-trip several relays, short enough
    // that `carl search` doesn't appear hung.
    try std.testing.expect(opts.timeout_ms >= 5_000 and opts.timeout_ms <= 60_000);
    // Default max_events bounded — we don't want to silently accept floods.
    try std.testing.expect(opts.max_events > 0 and opts.max_events <= 10_000);
    // Verification on by default — incoming events are untrusted.
    try std.testing.expect(opts.verify_signatures);
}
