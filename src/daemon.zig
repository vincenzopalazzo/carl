//! Localhost HTTP + WebSocket daemon: the thin backend the desktop GUI talks
//! to. Binds loopback only and guards every request with a shared token
//! (`X-Carl-Token`, or `?token=` for the WebSocket handshake the browser can't
//! set headers on). One thread per connection — fine for a single local GUI.
//!
//! REST endpoints serve JSON snapshots from the `TorrentManager` and the real
//! Nostr subsystems; `GET /ws` upgrades to a WebSocket that pushes a fresh
//! state snapshot once a second (the "live-ish" tick the prototype shows). The
//! full contract is in docs/daemon-api.md.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const http = @import("http.zig");
const ws_server = @import("ws_server.zig");
const manager_mod = @import("manager.zig");
const session_mod = @import("session.zig");
const api = @import("api.zig");
const nostr_config = @import("nostr_config.zig");
const proxy_mod = @import("proxy.zig");
const relay_mod = @import("relay.zig");
const nip35 = @import("nip35.zig");
const nostr_mod = @import("nostr.zig");
const secp = @import("secp.zig");
const nip19 = @import("nip19.zig");

const log = std.log.scoped(.daemon);

/// How often the WebSocket pushes a fresh state snapshot.
const push_interval_ns: u64 = std.time.ns_per_s;

pub const Daemon = struct {
    allocator: Allocator,
    manager: *manager_mod.Manager,
    token: []const u8,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

    /// Bind to 127.0.0.1:`port` and serve until `running` is cleared. Blocking.
    pub fn serve(self: *Daemon, port: u16) !void {
        const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
        var server = try addr.listen(.{ .reuse_address = true });
        defer server.deinit();

        log.info("daemon listening on http://127.0.0.1:{d}", .{port});
        // Poll the listen socket with a timeout rather than blocking in
        // accept(): Zig's accept() retries on EINTR, so a bare accept would
        // never observe the SIGINT-set `shutdown_requested`. Polling lets the
        // loop re-check the shutdown flags ~twice a second and exit cleanly.
        var pfd = [_]posix.pollfd{.{ .fd = server.stream.handle, .events = posix.POLL.IN, .revents = 0 }};
        while (self.running.load(.acquire) and !session_mod.shutdown_requested.load(.acquire)) {
            const ready = posix.poll(&pfd, 500) catch 0;
            if (ready == 0) continue;
            const conn = server.accept() catch {
                continue;
            };
            const ctx = self.allocator.create(Conn) catch {
                conn.stream.close();
                continue;
            };
            ctx.* = .{ .daemon = self, .stream = conn.stream };
            const t = std.Thread.spawn(.{}, Conn.run, .{ctx}) catch {
                conn.stream.close();
                self.allocator.destroy(ctx);
                continue;
            };
            t.detach();
        }
    }

    pub fn stop(self: *Daemon) void {
        self.running.store(false, .release);
    }
};

const Conn = struct {
    daemon: *Daemon,
    stream: std.net.Stream,

    fn run(self: *Conn) void {
        const a = self.daemon.allocator;
        defer {
            self.stream.close();
            a.destroy(self);
        }
        self.handle() catch |err| {
            log.debug("connection error: {}", .{err});
        };
    }

    fn handle(self: *Conn) !void {
        const a = self.daemon.allocator;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(a);

        // Read until the header block is complete.
        var tmp: [4096]u8 = undefined;
        while (std.mem.indexOf(u8, buf.items, "\r\n\r\n") == null) {
            const n = posix.recv(self.stream.handle, &tmp, 0) catch return;
            if (n == 0) return;
            try buf.appendSlice(a, tmp[0..n]);
            if (buf.items.len > 256 * 1024) return self.sendStatus(.bad_request);
        }

        // Probe to learn Content-Length, then read the whole body before the
        // final parse, so the parsed Request's slices don't dangle on realloc.
        const probe = http.parse(buf.items) catch return self.sendStatus(.bad_request);
        const need = probe.head_len + probe.contentLength();
        while (buf.items.len < need) {
            const n = posix.recv(self.stream.handle, &tmp, 0) catch break;
            if (n == 0) break;
            try buf.appendSlice(a, tmp[0..n]);
        }

        const req = http.parse(buf.items) catch return self.sendStatus(.bad_request);
        const body_end = @min(buf.items.len, req.head_len + req.contentLength());
        const body = buf.items[req.head_len..body_end];
        try self.route(&req, body);
    }

    fn route(self: *Conn, req: *const http.Request, body: []const u8) !void {
        // CORS preflight: answer before the token check so the browser can
        // proceed to the real, token-bearing request.
        if (std.mem.eql(u8, req.method, "OPTIONS")) return self.sendStatus(.no_content);

        if (!self.tokenOk(req)) return self.sendStatus(.unauthorized);

        const path = req.path;
        if (std.mem.eql(u8, path, "/ws")) return self.serveWebSocket(req);

        if (std.mem.eql(u8, req.method, "GET")) {
            if (std.mem.eql(u8, path, "/api/state")) return self.serveState();
            if (std.mem.eql(u8, path, "/api/transfers")) return self.serveTransfers();
            if (std.mem.eql(u8, path, "/api/seeds")) return self.serveSeeds();
            if (std.mem.eql(u8, path, "/api/relays")) return self.serveRelays();
            if (std.mem.eql(u8, path, "/api/identity")) return self.serveIdentity();
            if (std.mem.eql(u8, path, "/api/settings")) return self.serveSettings();
            return self.sendStatus(.not_found);
        }
        if (std.mem.eql(u8, req.method, "POST")) {
            if (std.mem.eql(u8, path, "/api/transfers")) return self.addTransfer(body);
            if (std.mem.eql(u8, path, "/api/search")) return self.search(req, body);
            if (std.mem.eql(u8, path, "/api/settings")) return self.updateSettings(body);
            return self.sendStatus(.not_found);
        }
        if (std.mem.eql(u8, req.method, "DELETE")) {
            if (std.mem.startsWith(u8, path, "/api/transfers/")) {
                const id = path["/api/transfers/".len..];
                const removed = self.daemon.manager.removeTransfer(id) catch false;
                return self.sendStatus(if (removed) .no_content else .not_found);
            }
            return self.sendStatus(.not_found);
        }
        return self.sendStatus(.method_not_allowed);
    }

    fn tokenOk(self: *Conn, req: *const http.Request) bool {
        const expected = self.daemon.token;
        if (req.header("x-carl-token")) |h| {
            if (std.mem.eql(u8, h, expected)) return true;
        }
        if (req.queryParam("token")) |q| {
            if (std.mem.eql(u8, q, expected)) return true;
        }
        return false;
    }

    // ----- GET handlers -----

    fn serveState(self: *Conn) !void {
        const a = self.daemon.allocator;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const json = try buildStateJson(arena.allocator(), self.daemon);
        try self.sendJson(.ok, json);
    }

    fn serveTransfers(self: *Conn) !void {
        const a = self.daemon.allocator;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const aa = arena.allocator();
        const transfers = try self.daemon.manager.snapshot(aa);
        const json = try api.transfersJson(aa, transfers);
        try self.sendJson(.ok, json);
    }

    fn serveSeeds(self: *Conn) !void {
        const a = self.daemon.allocator;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const aa = arena.allocator();
        const seeds = try self.daemon.manager.seeds(aa);
        var j = api.Json.init(aa);
        try j.beginArray();
        for (seeds) |s| try api.writeSeed(&j, s);
        try j.endArray();
        try self.sendJson(.ok, j.buf.items);
    }

    fn serveRelays(self: *Conn) !void {
        const a = self.daemon.allocator;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const aa = arena.allocator();
        const relays = try readRelayStates(aa);
        var j = api.Json.init(aa);
        try j.beginArray();
        for (relays) |r| try api.writeRelay(&j, r);
        try j.endArray();
        try self.sendJson(.ok, j.buf.items);
    }

    fn serveIdentity(self: *Conn) !void {
        const a = self.daemon.allocator;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const aa = arena.allocator();
        var j = api.Json.init(aa);
        try api.writeIdentity(&j, .{ .npub = try readNpub(aa) });
        try self.sendJson(.ok, j.buf.items);
    }

    fn serveSettings(self: *Conn) !void {
        const a = self.daemon.allocator;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const aa = arena.allocator();
        const relays = try nostr_config.readRelays(aa);
        var j = api.Json.init(aa);
        try api.writeSettings(&j, self.daemon.manager.settings(relays));
        try self.sendJson(.ok, j.buf.items);
    }

    // ----- POST/DELETE handlers -----

    fn addTransfer(self: *Conn, body: []const u8) !void {
        const a = self.daemon.allocator;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const aa = arena.allocator();

        const parsed = std.json.parseFromSlice(std.json.Value, aa, body, .{}) catch
            return self.sendStatus(.bad_request);
        const obj = if (parsed.value == .object) parsed.value.object else return self.sendStatus(.bad_request);
        const source = strField(obj, "source") orelse return self.sendStatus(.bad_request);
        const route_val = api.Route.parse(strField(obj, "route") orelse "direct") orelse .direct;
        const want_nostr = if (obj.get("nostr")) |v| (v == .bool and v.bool) else false;

        const id = self.daemon.manager.addTransfer(source, route_val, want_nostr) catch |err| {
            log.warn("addTransfer failed: {}", .{err});
            return self.sendStatus(.bad_request);
        };
        defer a.free(id);

        var j = api.Json.init(aa);
        try j.beginObject();
        try j.keyString("id", id);
        try j.endObject();
        try self.sendJson(.ok, j.buf.items);
    }

    fn updateSettings(self: *Conn, body: []const u8) !void {
        const a = self.daemon.allocator;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const aa = arena.allocator();

        const parsed = std.json.parseFromSlice(std.json.Value, aa, body, .{}) catch
            return self.sendStatus(.bad_request);
        if (parsed.value == .object) {
            if (strField(parsed.value.object, "route")) |r| {
                if (api.Route.parse(r)) |rt| self.daemon.manager.setRoute(rt);
            }
        }
        // Echo the (possibly updated) settings back.
        const relays = try nostr_config.readRelays(aa);
        var j = api.Json.init(aa);
        try api.writeSettings(&j, self.daemon.manager.settings(relays));
        try self.sendJson(.ok, j.buf.items);
    }

    fn search(self: *Conn, req: *const http.Request, body: []const u8) !void {
        const a = self.daemon.allocator;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const aa = arena.allocator();

        // Query from JSON body {"query": "..."} or ?q= fallback.
        var query: []const u8 = req.queryParam("q") orelse "";
        if (body.len > 0) {
            if (std.json.parseFromSlice(std.json.Value, aa, body, .{})) |p| {
                if (p.value == .object) {
                    if (strField(p.value.object, "query")) |q| query = q;
                }
            } else |_| {}
        }

        const json = runSearch(aa, self.daemon, query) catch |err| {
            log.warn("search failed: {}", .{err});
            return self.sendJson(.ok, "[]");
        };
        try self.sendJson(.ok, json);
    }

    // ----- WebSocket -----

    fn serveWebSocket(self: *Conn, req: *const http.Request) !void {
        if (!req.isWebSocketUpgrade()) return self.sendStatus(.bad_request);
        const key = req.header("sec-websocket-key") orelse return self.sendStatus(.bad_request);

        var accept: [28]u8 = undefined;
        ws_server.acceptKey(key, &accept);

        const a = self.daemon.allocator;
        var hdr: [256]u8 = undefined;
        const upgrade = std.fmt.bufPrint(&hdr, "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n\r\n", .{accept}) catch return;
        self.sendAll(upgrade) catch return;

        // Push a fresh snapshot every interval until the client closes (send
        // fails) or the daemon stops. We don't read client frames — a localhost
        // GUI only needs the push channel — so a closed socket is detected by
        // the next send failing.
        while (self.daemon.running.load(.acquire) and !session_mod.shutdown_requested.load(.acquire)) {
            var arena = std.heap.ArenaAllocator.init(a);
            const json = buildStateJson(arena.allocator(), self.daemon) catch {
                arena.deinit();
                break;
            };
            ws_server.sendText(a, self.stream, json) catch {
                arena.deinit();
                break;
            };
            arena.deinit();
            // Sleep in small steps so the push thread observes shutdown promptly
            // (within ~100ms) rather than holding the process open for a full
            // tick — keeps teardown responsive.
            var slept: u64 = 0;
            while (slept < push_interval_ns and
                self.daemon.running.load(.acquire) and
                !session_mod.shutdown_requested.load(.acquire)) : (slept += 100 * std.time.ns_per_ms)
            {
                std.Thread.sleep(100 * std.time.ns_per_ms);
            }
        }
        ws_server.sendClose(a, self.stream);
    }

    // ----- response writers -----

    fn sendJson(self: *Conn, status: http.Status, json: []const u8) !void {
        const resp = try http.jsonResponse(self.daemon.allocator, status, json);
        defer self.daemon.allocator.free(resp);
        try self.sendAll(resp);
    }

    fn sendStatus(self: *Conn, status: http.Status) !void {
        // A tiny JSON body keeps clients that always parse JSON happy.
        try self.sendJson(status, "{}");
    }

    fn sendAll(self: *Conn, buf: []const u8) !void {
        var off: usize = 0;
        while (off < buf.len) {
            const n = posix.send(self.stream.handle, buf[off..], 0) catch return error.SendFailed;
            if (n == 0) return error.Closed;
            off += n;
        }
    }
};

// ===========================================================================
// JSON builders (arena-allocated; caller frees the arena)
// ===========================================================================

/// The combined initial-load payload and the per-tick WebSocket push.
fn buildStateJson(arena: Allocator, daemon: *Daemon) ![]u8 {
    const transfers = try daemon.manager.snapshot(arena);
    const seeds = try daemon.manager.seeds(arena);
    const relays = try readRelayStates(arena);
    const settings_relays = try nostr_config.readRelays(arena);
    const npub = try readNpub(arena);

    var j = api.Json.init(arena);
    try j.beginObject();
    try j.key("transfers");
    try j.beginArray();
    for (transfers) |t| try api.writeTransfer(&j, t);
    try j.endArray();
    try j.key("seeds");
    try j.beginArray();
    for (seeds) |s| try api.writeSeed(&j, s);
    try j.endArray();
    try j.key("relays");
    try j.beginArray();
    for (relays) |r| try api.writeRelay(&j, r);
    try j.endArray();
    try j.key("identity");
    try api.writeIdentity(&j, .{ .npub = npub });
    try j.key("settings");
    try api.writeSettings(&j, daemon.manager.settings(settings_relays));
    try j.endObject();
    return j.buf.items;
}

/// Read configured relays into `api.Relay` rows. The daemon doesn't hold
/// persistent relay connections, so state is reported as "configured"; the
/// clearnet/tor split is derived from the URL.
fn readRelayStates(arena: Allocator) ![]api.Relay {
    const urls = try nostr_config.readRelays(arena);
    const out = try arena.alloc(api.Relay, urls.len);
    for (urls, 0..) |url, i| {
        out[i] = .{ .url = url, .state = "configured", .net = relayNet(url), .events = 0 };
    }
    return out;
}

fn relayNet(url: []const u8) []const u8 {
    return if (std.mem.indexOf(u8, url, ".onion") != null) "tor" else "clearnet";
}

/// The local npub, or "" when no key is configured. The nsec is never exposed.
fn readNpub(arena: Allocator) ![]const u8 {
    const sk = nostr_config.readSecretKey(arena) catch return "";
    const pk = secp.publicKeyFromSecret(sk) catch return "";
    return nip19.encode32(arena, .npub, pk) catch "";
}

fn strField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

// ===========================================================================
// Nostr search → DiscoverResult JSON
// ===========================================================================

fn runSearch(arena: Allocator, daemon: *Daemon, query: []const u8) ![]u8 {
    const relay_urls = try nostr_config.readRelays(arena);

    // Match the route the manager is configured for, so search over Tor/proxy
    // doesn't leak the real IP.
    var proxy: ?proxy_mod.Proxy = null;
    if (daemon.manager.cfg.route != .direct) {
        proxy = proxy_mod.parseUrl(daemon.manager.cfg.socks) catch null;
    }

    const filter: nostr_mod.Filter = .{
        .kinds = &[_]u32{nip35.kind_torrent},
        .limit = 100,
    };

    var results: std.ArrayList(api.DiscoverResult) = .empty;
    var seen: std.ArrayList([40]u8) = .empty;
    const now = std.time.timestamp();

    for (relay_urls) |url| {
        if (results.items.len >= 50) break;
        var r = relay_mod.Relay.connect(arena, url, proxy) catch continue;
        defer r.deinit();
        const events = relay_mod.subscribeAndCollect(arena, &r, filter, .{
            .timeout_ms = 12_000,
            .max_events = 200,
            .verify_signatures = true,
        }) catch continue;

        for (events) |ev| {
            const entry = nip35.parseEvent(arena, ev) catch continue;
            if (!textMatches(entry.title, query) and !textMatches(entry.description, query)) continue;

            var ih_hex: [40]u8 = undefined;
            secp.toHex(&entry.info_hash, &ih_hex);
            if (containsHash(seen.items, ih_hex)) continue;
            try seen.append(arena, ih_hex);

            var total: u64 = 0;
            for (entry.files) |f| total += f.size;

            const author = nip19.encode32(arena, .npub, ev.pubkey) catch "";
            const found_on = try arena.alloc([]const u8, 1);
            found_on[0] = url;

            try results.append(arena, .{
                .id = try arena.dupe(u8, &ih_hex),
                .title = try arena.dupe(u8, entry.title),
                .hash = try arena.dupe(u8, &ih_hex),
                .size = total,
                .files = @intCast(entry.files.len),
                .trackers = @intCast(entry.trackers.len),
                .desc = try arena.dupe(u8, entry.description),
                .verified = true, // collected with verify_signatures = true
                .relays = found_on,
                .author = author,
                .age = try formatAge(arena, now - ev.created_at),
            });
            if (results.items.len >= 50) break;
        }
    }

    var j = api.Json.init(arena);
    try j.beginArray();
    for (results.items) |d| try api.writeDiscoverResult(&j, d);
    try j.endArray();
    return j.buf.items;
}

fn containsHash(seen: []const [40]u8, h: [40]u8) bool {
    for (seen) |s| {
        if (std.mem.eql(u8, &s, &h)) return true;
    }
    return false;
}

/// Case-insensitive ASCII substring match; an empty needle matches everything.
fn textMatches(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var off: usize = 0;
    const max_off = haystack.len - needle.len + 1;
    while (off < max_off) : (off += 1) {
        var match = true;
        for (needle, 0..) |n, i| {
            if (std.ascii.toLower(haystack[off + i]) != std.ascii.toLower(n)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn formatAge(arena: Allocator, secs_ago: i64) ![]const u8 {
    const s: u64 = if (secs_ago < 0) 0 else @intCast(secs_ago);
    if (s < 3600) return std.fmt.allocPrint(arena, "{d}m ago", .{s / 60});
    if (s < 86400) return std.fmt.allocPrint(arena, "{d}h ago", .{s / 3600});
    return std.fmt.allocPrint(arena, "{d}d ago", .{s / 86400});
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "relayNet: onion vs clearnet" {
    try testing.expectEqualStrings("tor", relayNet("ws://abc.onion"));
    try testing.expectEqualStrings("clearnet", relayNet("wss://relay.damus.io"));
}

test "textMatches: case-insensitive substring" {
    try testing.expect(textMatches("Debian 12.5", "debian"));
    try testing.expect(textMatches("anything", "")); // empty needle
    try testing.expect(!textMatches("arch", "debian"));
}

test "formatAge: buckets" {
    const a = testing.allocator;
    const m = try formatAge(a, 120);
    defer a.free(m);
    try testing.expectEqualStrings("2m ago", m);
    const h = try formatAge(a, 7200);
    defer a.free(h);
    try testing.expectEqualStrings("2h ago", h);
    const d = try formatAge(a, 172800);
    defer a.free(d);
    try testing.expectEqualStrings("2d ago", d);
}

test "buildStateJson: produces the five top-level keys" {
    const a = testing.allocator;
    var mgr = try manager_mod.Manager.init(a, .{});
    defer mgr.deinit();
    var d = Daemon{ .allocator = a, .manager = &mgr, .token = "tok" };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const json = try buildStateJson(arena.allocator(), &d);

    var p = try std.json.parseFromSlice(std.json.Value, arena.allocator(), json, .{});
    defer p.deinit();
    const o = p.value.object;
    try testing.expect(o.get("transfers").? == .array);
    try testing.expect(o.get("seeds").? == .array);
    try testing.expect(o.get("relays").? == .array);
    try testing.expect(o.get("identity").? == .object);
    try testing.expect(o.get("settings").? == .object);
    try testing.expectEqual(@as(usize, 0), o.get("transfers").?.array.items.len);
}
