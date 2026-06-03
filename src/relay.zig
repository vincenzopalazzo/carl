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
    OutOfMemory,
} || ws.Error || nostr.Error;

/// One relay connection.
pub const Relay = struct {
    allocator: Allocator,
    url: []const u8, // borrowed
    conn: ws.Conn,

    pub fn connect(allocator: Allocator, url: []const u8, proxy: ?proxy_mod.Proxy) Error!Relay {
        const conn = ws.Conn.connect(allocator, url, .{ .proxy = proxy }) catch |err| {
            log.warn("relay connect to {s} failed: {}", .{ url, err });
            return error.ConnectFailed;
        };
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
    // recv() up to ws.Conn's default 30 s, even when the caller asked for
    // a shorter budget.
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
