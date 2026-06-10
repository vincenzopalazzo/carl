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
const metainfo = @import("metainfo.zig");
const api = @import("api.zig");
const nostr_config = @import("nostr_config.zig");
const proxy_mod = @import("proxy.zig");
const i2p_sam = @import("i2p_sam.zig");
const relay_mod = @import("relay.zig");
const nip35 = @import("nip35.zig");
const nostr_mod = @import("nostr.zig");
const secp = @import("secp.zig");
const nip19 = @import("nip19.zig");

const log = std.log.scoped(.daemon);

/// How often the WebSocket pushes a fresh state snapshot.
const push_interval_ns: u64 = std.time.ns_per_s;

/// Cap on concurrent connections, so a misbehaving client can't spawn unbounded
/// threads. A single GUI uses ~2 (one REST poll + one WebSocket); the headroom
/// covers bursts.
const max_conns: u32 = 64;

/// Recv timeout (seconds) on accepted sockets, so a client that connects and
/// then stalls (or lies about Content-Length) can't wedge a thread forever.
const recv_timeout_secs: u32 = 30;

/// Max request size held in memory (covers the "Seed a file" upload body).
const max_body: usize = 256 * 1024 * 1024;

/// How often the background prober refreshes relay reachability. The daemon
/// holds no persistent relay connections, so without this the UI could only
/// ever show relays as "configured" (never connected).
const probe_interval_ns: u64 = 30 * std.time.ns_per_s;

pub const Daemon = struct {
    allocator: Allocator,
    manager: *manager_mod.Manager,
    token: []const u8,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    conns: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Last relay-health probe result (owned). Guarded by `health_mutex`.
    health_mutex: std.Thread.Mutex = .{},
    health: []api.Relay = &.{},
    /// Last SOCKS-proxy-health probe (proxy/tor route), guarded by `health_mutex`.
    /// `proxy_probed` is false until the first probe lands (UI shows "checking").
    proxy_state: proxy_mod.ProxyState = .ok,
    proxy_reply: ?u8 = null,
    proxy_probed: bool = false,

    /// Bind to 127.0.0.1:`port` and serve until `running` is cleared. Blocking.
    pub fn serve(self: *Daemon, port: u16) !void {
        const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
        var server = try addr.listen(.{ .reuse_address = true });
        defer server.deinit();

        log.info("daemon listening on http://127.0.0.1:{d}", .{port});

        // Background relay-health prober: refreshes connected/unreachable status
        // so the UI's relay strip is real, without probing on every state tick.
        if (std.Thread.spawn(.{}, Daemon.relayHealthLoop, .{self})) |p| {
            p.detach();
        } else |_| {}

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

            // Shed load past the cap rather than spawning unbounded threads.
            if (self.conns.fetchAdd(1, .monotonic) >= max_conns) {
                _ = self.conns.fetchSub(1, .monotonic);
                conn.stream.close();
                continue;
            }
            setRecvTimeout(conn.stream, recv_timeout_secs);

            const ctx = self.allocator.create(Conn) catch {
                _ = self.conns.fetchSub(1, .monotonic);
                conn.stream.close();
                continue;
            };
            ctx.* = .{ .daemon = self, .stream = conn.stream };
            const t = std.Thread.spawn(.{}, Conn.run, .{ctx}) catch {
                _ = self.conns.fetchSub(1, .monotonic);
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

    /// Free the cached relay health. Call after `serve` returns (and the prober
    /// has wound down) before the allocator is torn down.
    pub fn deinit(self: *Daemon) void {
        self.health_mutex.lock();
        const h = self.health;
        self.health = &.{};
        self.health_mutex.unlock();
        freeHealth(self.allocator, h);
    }

    /// Snapshot current relay health into `arena`. Before the first probe lands,
    /// falls back to the configured list (state "configured").
    fn healthSnapshot(self: *Daemon, arena: Allocator) ![]api.Relay {
        self.health_mutex.lock();
        defer self.health_mutex.unlock();
        if (self.health.len == 0) {
            const urls = try nostr_config.readRelays(arena);
            const out = try arena.alloc(api.Relay, urls.len);
            for (urls, 0..) |url, i| {
                out[i] = .{ .url = url, .state = "configured", .net = relayNet(url), .events = 0 };
            }
            return out;
        }
        const out = try arena.alloc(api.Relay, self.health.len);
        for (self.health, 0..) |r, i| {
            // state/net are static strings; only url is owned by the cache.
            out[i] = .{ .url = try arena.dupe(u8, r.url), .state = r.state, .net = r.net, .events = r.events };
        }
        return out;
    }

    /// Snapshot transport health for the API. `endpoint` is duped into `arena`.
    /// Maps the direct route to "disabled" and the pre-first-probe window to
    /// "checking"; otherwise reflects the last probe. The same `proxy` health
    /// shape carries both the SOCKS health (proxy/tor) and the SAM-bridge health
    /// (i2p), so the GUI shows live transport status on every anonymized route.
    fn proxyHealthSnapshot(self: *Daemon, arena: Allocator) !api.ProxyHealth {
        const route = self.manager.cfg.route;
        // The i2p route's endpoint is the SAM bridge, not the SOCKS URL.
        const endpoint = if (route == .i2p)
            try arena.dupe(u8, self.manager.cfg.i2p_sam)
        else blk: {
            // Mask any SOCKS auth credentials before exposing the endpoint.
            const raw = self.manager.cfg.socks;
            const rbuf = try arena.alloc(u8, raw.len + 4);
            break :blk try arena.dupe(u8, proxy_mod.redactUrl(raw, rbuf));
        };
        // Only the direct route has no transport to probe.
        if (route == .direct)
            return .{ .state = "disabled", .endpoint = endpoint };

        self.health_mutex.lock();
        const probed = self.proxy_probed;
        const st = self.proxy_state;
        const reply = self.proxy_reply;
        self.health_mutex.unlock();

        if (!probed) return .{ .state = "checking", .endpoint = endpoint };

        var detail: []const u8 = "";
        if (st == .rejected) {
            detail = if (route == .i2p)
                "not a SAM bridge (no HELLO REPLY)"
            else if (reply) |b|
                std.fmt.allocPrint(arena, "SOCKS5 replied 0x{x:0>2}", .{b}) catch ""
            else
                "";
        }
        return .{ .state = st.jsonName(), .endpoint = endpoint, .detail = detail };
    }

    /// Probe the active transport once and cache the result: the SOCKS proxy on
    /// the proxy/tor route, or the SAM bridge on the i2p route. Greeting only —
    /// never opens an upstream connection or creates a session.
    fn probeProxy(self: *Daemon) void {
        const route = self.manager.cfg.route;
        if (route == .direct) {
            // Don't fabricate an "ok": mark unprobed so that if the route later
            // switches to an anonymized one, the snapshot shows an honest
            // "checking" until a real probe lands. The direct route is reported
            // as "disabled" by the snapshot regardless.
            self.health_mutex.lock();
            self.proxy_probed = false;
            self.health_mutex.unlock();
            return;
        }
        if (route == .i2p) {
            const bridge = i2p_sam.parseUrl(self.manager.cfg.i2p_sam) catch {
                // Malformed SAM address is a config error; surface it as
                // "rejected" so the route doesn't silently look healthy.
                self.publishProxy(.rejected, null);
                return;
            };
            // Map SAM health onto the shared ProxyState shape.
            const state: proxy_mod.ProxyState = switch (i2p_sam.classifyBridge(self.allocator, bridge, 5)) {
                .ok => .ok,
                .not_running => .not_running,
                .timeout => .timeout,
                .handshake_failed => .rejected,
            };
            self.publishProxy(state, null);
            return;
        }
        const proxy = proxy_mod.parseUrl(self.manager.cfg.socks) catch {
            // Malformed proxy URL is a config error the user must fix; surface it
            // as "rejected" so the route doesn't silently look healthy.
            self.publishProxy(.rejected, null);
            return;
        };
        const probe = proxy_mod.classifySocks5(self.allocator, proxy, 5);
        self.publishProxy(probe.state, probe.reply);
    }

    fn publishProxy(self: *Daemon, state: proxy_mod.ProxyState, reply: ?u8) void {
        self.health_mutex.lock();
        self.proxy_state = state;
        self.proxy_reply = reply;
        self.proxy_probed = true;
        self.health_mutex.unlock();
    }

    fn relayHealthLoop(self: *Daemon) void {
        while (self.running.load(.acquire) and !session_mod.shutdown_requested.load(.acquire)) {
            self.probeRelays();
            self.probeProxy();
            // Persist any newly-resolved magnet torrents (headless coverage; the
            // WS push also does this ~1/s when the GUI is connected).
            self.manager.checkpoint();
            var slept: u64 = 0;
            while (slept < probe_interval_ns and
                self.running.load(.acquire) and
                !session_mod.shutdown_requested.load(.acquire)) : (slept += 250 * std.time.ns_per_ms)
            {
                std.Thread.sleep(250 * std.time.ns_per_ms);
            }
        }
    }

    /// Probe each configured relay once (open + close a connection) and publish
    /// the connected/unreachable result. Onion relays are only probed when a
    /// proxy is set (otherwise they're unreachable by definition).
    fn probeRelays(self: *Daemon) void {
        const a = self.allocator;
        const urls = nostr_config.readRelays(a) catch return;
        defer nostr_config.freeRelays(a, urls);

        var proxy: ?proxy_mod.Proxy = null;
        // Only proxy/Tor route relay traffic through the SOCKS endpoint. The i2p
        // route's `socks` is irrelevant (SAM, not SOCKS); routing relays over it
        // would (wrongly) require Tor. Nostr-over-I2P is a follow-up.
        if (self.manager.cfg.route.usesSocks()) {
            proxy = proxy_mod.parseUrl(self.manager.cfg.socks) catch null;
        }

        var list: std.ArrayList(api.Relay) = .empty;
        for (urls) |url| {
            const onion = std.mem.indexOf(u8, url, ".onion") != null;
            var state: []const u8 = "configured";
            if (!(onion and proxy == null)) {
                if (relay_mod.Relay.connect(a, url, proxy)) |r| {
                    var rc = r;
                    rc.deinit();
                    state = "connected";
                } else |_| {
                    state = "unreachable";
                }
            }
            const dup = a.dupe(u8, url) catch {
                freeHealth(a, list.toOwnedSlice(a) catch &.{});
                return;
            };
            list.append(a, .{ .url = dup, .state = state, .net = relayNet(url), .events = 0 }) catch {
                a.free(dup);
                freeHealth(a, list.toOwnedSlice(a) catch &.{});
                return;
            };
        }
        const fresh = list.toOwnedSlice(a) catch {
            for (list.items) |r| a.free(r.url);
            list.deinit(a);
            return;
        };

        self.health_mutex.lock();
        const old = self.health;
        self.health = fresh;
        self.health_mutex.unlock();
        freeHealth(a, old);
    }
};

const Conn = struct {
    daemon: *Daemon,
    stream: std.net.Stream,

    fn run(self: *Conn) void {
        const a = self.daemon.allocator;
        defer {
            _ = self.daemon.conns.fetchSub(1, .monotonic);
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
        if (need > max_body) return self.sendStatus(.bad_request);
        while (buf.items.len < need) {
            const n = posix.recv(self.stream.handle, &tmp, 0) catch break;
            if (n == 0) break;
            try buf.appendSlice(a, tmp[0..n]);
        }
        // A short read (recv timeout / peer hangup) leaves a truncated body. Do
        // not process it: POST /api/seeds would write a partial file and seed a
        // corrupt torrent.
        if (buf.items.len < need) return self.sendStatus(.bad_request);

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
            if (std.mem.eql(u8, path, "/api/seeds")) return self.createSeed(req, body);
            if (std.mem.eql(u8, path, "/api/torrents")) return self.createTorrent(body);
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
            if (constantTimeEql(h, expected)) return true;
        }
        if (req.queryParam("token")) |q| {
            if (constantTimeEql(q, expected)) return true;
        }
        return false;
    }

    // ----- GET handlers -----

    fn serveState(self: *Conn) !void {
        const a = self.daemon.allocator;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const aa = arena.allocator();
        const relays = try self.daemon.healthSnapshot(aa);
        const npub = try readNpub(aa);
        const json = try buildStateJson(aa, self.daemon, relays, npub);
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
        const relays = try self.daemon.healthSnapshot(aa);
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

    /// POST /api/seeds — body is the raw file content (so a browser drag-drop or
    /// the Tauri shell can upload directly). Headers: X-Carl-Filename (required),
    /// X-Carl-Route (direct|proxy|tor|i2p, default tor), X-Carl-Nostr (true|false).
    /// Writes the file into the download dir, creates a torrent in-process, and
    /// starts seeding it; returns { id }.
    fn createSeed(self: *Conn, req: *const http.Request, body: []const u8) !void {
        const a = self.daemon.allocator;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const aa = arena.allocator();

        const raw_name = req.header("x-carl-filename") orelse return self.sendStatus(.bad_request);
        // Sanitize to a bare filename — never let the client write outside the dir.
        const filename = std.fs.path.basename(raw_name);
        if (filename.len == 0 or body.len == 0) return self.sendStatus(.bad_request);
        const route_val = api.Route.parse(req.header("x-carl-route") orelse "tor") orelse .tor;
        const want_nostr = if (req.header("x-carl-nostr")) |h| std.mem.eql(u8, h, "true") else false;

        const dir = self.daemon.manager.downloadDirDup(aa) catch return self.sendStatus(.internal_error);
        std.fs.cwd().makePath(dir) catch {};
        const full = std.fmt.allocPrint(aa, "{s}/{s}", .{ dir, filename }) catch
            return self.sendStatus(.internal_error);
        {
            var f = std.fs.cwd().createFile(full, .{ .truncate = true }) catch
                return self.sendStatus(.internal_error);
            defer f.close();
            f.writeAll(body) catch return self.sendStatus(.internal_error);
        }

        const id = self.daemon.manager.addSeed(full, route_val, want_nostr) catch |err| {
            log.warn("addSeed failed: {}", .{err});
            if (err == error.TorControlFailed) {
                return self.sendError(.bad_request, "Tor hidden service setup failed: carl couldn't reach Tor's ControlPort. Enable it in your torrc (ControlPort 9051 + CookieAuthentication 1) and restart Tor, then retry the Tor seed.");
            }
            return self.sendStatus(.bad_request);
        };
        defer a.free(id);

        var j = api.Json.init(aa);
        try j.beginObject();
        try j.keyString("id", id);
        try j.endObject();
        try self.sendJson(.ok, j.buf.items);
    }

    /// Outcome of building a .torrent on disk, in arena memory.
    const TorrentBuilt = struct {
        out_path: []const u8,
        info_hash_hex: [40]u8,
        size: u64,
        files: usize,
    };

    /// Shared by the HTTP route and the WebSocket command: build a .torrent from
    /// a server-side `src_path` (file OR directory), write it next to the source
    /// as `<src>.torrent`, and return a summary. The output path is derived from
    /// the source (never client-supplied) so a request can't make the daemon
    /// overwrite an arbitrary file. Creation is path-based (folders can't be
    /// uploaded as bytes); the daemon binds loopback and is token-guarded, and
    /// the desktop supplies the path from a native picker.
    fn doCreateTorrent(
        self: *Conn,
        aa: Allocator,
        src_path: []const u8,
        trackers: []const []const u8,
        comment: ?[]const u8,
    ) !TorrentBuilt {
        const res = metainfo.buildTorrent(self.daemon.allocator, src_path, .{
            .trackers = trackers,
            .comment = comment,
            .created_by = "carl",
            .creation_date = std.time.timestamp(),
        }) catch return error.CreateFailed;
        defer self.daemon.allocator.free(res.data);

        // Derive `<src>.torrent`, trimming a trailing slash so a directory path
        // "/a/b/" yields "/a/b.torrent" (beside it), not "/a/b/.torrent" (inside).
        const sep = [_]u8{std.fs.path.sep};
        const trimmed = std.mem.trimRight(u8, src_path, &sep);
        const base_path = if (trimmed.len == 0) src_path else trimmed;
        const out_path = try std.fmt.allocPrint(aa, "{s}.torrent", .{base_path});
        {
            var f = std.fs.cwd().createFile(out_path, .{ .truncate = true }) catch return error.WriteFailed;
            defer f.close();
            f.writeAll(res.data) catch return error.WriteFailed;
        }

        var hex: [40]u8 = undefined;
        secp.toHex(&res.info_hash, &hex);
        return .{
            .out_path = out_path,
            .info_hash_hex = hex,
            .size = res.total_length,
            .files = res.file_count,
        };
    }

    /// Pull the optional tracker list and comment out of a parsed create-torrent
    /// request object. Trackers default to empty (trackerless).
    fn parseCreateBody(aa: Allocator, obj: std.json.ObjectMap) !struct {
        trackers: []const []const u8,
        comment: ?[]const u8,
    } {
        var trackers: std.ArrayList([]const u8) = .empty;
        if (obj.get("trackers")) |v| {
            if (v == .array) {
                for (v.array.items) |it| {
                    if (it == .string and it.string.len > 0) try trackers.append(aa, it.string);
                }
            }
        }
        return .{
            .trackers = try trackers.toOwnedSlice(aa),
            .comment = strField(obj, "comment"),
        };
    }

    /// POST /api/torrents — body is JSON {path, trackers?, comment?}. `path` is a
    /// server-side file or directory; creates `<path>.torrent` on disk and
    /// returns { path, infoHash, size, files }.
    fn createTorrent(self: *Conn, body: []const u8) !void {
        const a = self.daemon.allocator;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const aa = arena.allocator();

        const parsed = std.json.parseFromSlice(std.json.Value, aa, body, .{}) catch
            return self.sendStatus(.bad_request);
        const obj = if (parsed.value == .object) parsed.value.object else return self.sendStatus(.bad_request);
        const src_path = strField(obj, "path") orelse return self.sendStatus(.bad_request);
        if (src_path.len == 0) return self.sendStatus(.bad_request);
        const opts = parseCreateBody(aa, obj) catch return self.sendStatus(.internal_error);

        const built = self.doCreateTorrent(aa, src_path, opts.trackers, opts.comment) catch |err| {
            log.warn("createTorrent failed for '{s}': {}", .{ src_path, err });
            // Bad input (unreadable/empty source) → 400; disk/write failure → 500.
            return self.sendStatus(if (err == error.WriteFailed) .internal_error else .bad_request);
        };

        var j = api.Json.init(aa);
        try j.beginObject();
        try j.keyString("path", built.out_path);
        try j.keyString("infoHash", &built.info_hash_hex);
        try j.keyNumber("size", built.size);
        try j.keyNumber("files", built.files);
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
            const obj = parsed.value.object;
            if (strField(obj, "route")) |r| {
                if (api.Route.parse(r)) |rt| self.daemon.manager.setRoute(rt);
            }
            if (strField(obj, "downloadDir")) |dir| {
                if (dir.len > 0) self.daemon.manager.setDownloadDir(dir) catch {};
            }
            // Relays: a JSON array of strings, persisted to the config file so
            // the prober, search, and the CLI all pick them up.
            if (obj.get("relays")) |v| {
                if (v == .array) {
                    var list: std.ArrayList([]const u8) = .empty;
                    for (v.array.items) |item| {
                        if (item == .string) {
                            const t = std.mem.trim(u8, item.string, " \t\r\n");
                            if (t.len > 0) try list.append(aa, t);
                        }
                    }
                    nostr_config.writeRelays(a, list.items) catch {};
                }
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

        // Query from JSON body {"query": "..."} or ?q= fallback (percent-decoded).
        var query: []const u8 = if (req.queryParam("q")) |q| (percentDecode(aa, q) catch q) else "";
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

        // Read the npub once for the connection (it's read from the keyfile);
        // relay health is an in-memory snapshot taken cheaply per tick.
        var conn_arena = std.heap.ArenaAllocator.init(a);
        defer conn_arena.deinit();
        const npub: []const u8 = readNpub(conn_arena.allocator()) catch "";

        // Push a fresh snapshot every interval until the client closes (send
        // fails) or the daemon stops. We don't read client frames — a localhost
        // GUI only needs the push channel — so a closed socket is detected by
        // the next send failing.
        while (self.daemon.running.load(.acquire) and !session_mod.shutdown_requested.load(.acquire)) {
            // Drain any pending client command frames (e.g. create_torrent)
            // before the push, without stalling the cadence: poll with a 0ms
            // timeout and handle only what's already buffered.
            while (socketReadable(self.stream.handle)) {
                const frame = ws_server.readFrame(a, self.stream) catch {
                    ws_server.sendClose(a, self.stream);
                    return;
                };
                defer frame.deinit(a);
                switch (frame.opcode) {
                    .text => self.handleWsCommand(frame.payload) catch {},
                    .ping => ws_server.sendPong(a, self.stream, frame.payload) catch {},
                    .close => {
                        ws_server.sendClose(a, self.stream);
                        return;
                    },
                    else => {},
                }
            }

            // Cheap when nothing changed; captures a resolved magnet's .torrent
            // within ~1s so a restart resumes it as a complete torrent.
            self.daemon.manager.checkpoint();
            var arena = std.heap.ArenaAllocator.init(a);
            const relays: []const api.Relay = self.daemon.healthSnapshot(arena.allocator()) catch &.{};
            const json = buildStateJson(arena.allocator(), self.daemon, relays, npub) catch {
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

    /// Handle one client text frame as a JSON command. Currently the only
    /// command is `create_torrent` — mirroring POST /api/torrents over the
    /// socket so the desktop can request creation and get a `torrent_created`
    /// result frame back. Unknown commands are ignored.
    fn handleWsCommand(self: *Conn, payload: []const u8) !void {
        const a = self.daemon.allocator;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const aa = arena.allocator();

        const parsed = std.json.parseFromSlice(std.json.Value, aa, payload, .{}) catch return;
        if (parsed.value != .object) return;
        const obj = parsed.value.object;
        const cmd = strField(obj, "cmd") orelse return;
        if (!std.mem.eql(u8, cmd, "create_torrent")) return;

        const req_id = strField(obj, "reqId") orelse "";
        const src_path = strField(obj, "path") orelse return self.wsCreateError(aa, req_id, "missing path");
        if (src_path.len == 0) return self.wsCreateError(aa, req_id, "missing path");
        const opts = parseCreateBody(aa, obj) catch return self.wsCreateError(aa, req_id, "bad request");

        const built = self.doCreateTorrent(aa, src_path, opts.trackers, opts.comment) catch
            return self.wsCreateError(aa, req_id, "create failed");

        var j = api.Json.init(aa);
        try j.beginObject();
        try j.keyString("type", "torrent_created");
        try j.keyString("reqId", req_id);
        try j.keyBool("ok", true);
        try j.keyString("path", built.out_path);
        try j.keyString("infoHash", &built.info_hash_hex);
        try j.keyNumber("size", built.size);
        try j.keyNumber("files", built.files);
        try j.endObject();
        ws_server.sendText(a, self.stream, j.buf.items) catch {};
    }

    /// Send a `torrent_created` failure frame for a WebSocket create command.
    fn wsCreateError(self: *Conn, aa: Allocator, req_id: []const u8, msg: []const u8) void {
        var j = api.Json.init(aa);
        j.beginObject() catch return;
        j.keyString("type", "torrent_created") catch return;
        j.keyString("reqId", req_id) catch return;
        j.keyBool("ok", false) catch return;
        j.keyString("error", msg) catch return;
        j.endObject() catch return;
        ws_server.sendText(self.daemon.allocator, self.stream, j.buf.items) catch {};
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

    /// Like `sendStatus` but with an `{ "error": "<message>" }` body so the GUI
    /// can show a specific, actionable reason instead of a bare status code.
    fn sendError(self: *Conn, status: http.Status, message: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.daemon.allocator);
        defer arena.deinit();
        var j = api.Json.init(arena.allocator());
        j.beginObject() catch return self.sendStatus(status);
        j.keyString("error", message) catch return self.sendStatus(status);
        j.endObject() catch return self.sendStatus(status);
        try self.sendJson(status, j.buf.items);
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
///
/// `relay_urls` and `npub` are passed in (read from config by the caller)
/// rather than read here, so the WebSocket push can read them once per
/// connection instead of hitting the filesystem on every tick. Transfers and
/// seeds are always read live from the manager.
fn buildStateJson(arena: Allocator, daemon: *Daemon, relays: []const api.Relay, npub: []const u8) ![]u8 {
    const transfers = try daemon.manager.snapshot(arena);
    const seeds = try daemon.manager.seeds(arena);

    // Settings echoes the relay URLs; derive them from the probed list.
    const relay_urls = try arena.alloc([]const u8, relays.len);
    for (relays, 0..) |r, i| relay_urls[i] = r.url;

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
    try j.key("proxy");
    try api.writeProxyHealth(&j, try daemon.proxyHealthSnapshot(arena));
    try j.key("identity");
    try api.writeIdentity(&j, .{ .npub = npub });
    try j.key("settings");
    try api.writeSettings(&j, daemon.manager.settings(relay_urls));
    try j.endObject();
    return j.buf.items;
}

/// Free an owned relay-health list (the url strings, then the slice).
fn freeHealth(a: Allocator, list: []api.Relay) void {
    for (list) |r| a.free(r.url);
    if (list.len > 0) a.free(list);
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

/// Non-blocking readability probe (poll with a 0ms timeout) so the WebSocket
/// push loop can opportunistically drain client command frames without stalling.
/// A half-closed socket also polls readable; the subsequent read then fails and
/// the caller closes the connection.
fn socketReadable(fd: posix.socket_t) bool {
    var pfd = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    const ready = posix.poll(&pfd, 0) catch return false;
    return ready > 0;
}

/// Set a recv timeout on an accepted socket so a stalled client can't wedge its
/// thread forever. Best-effort (a failed setsockopt just leaves the default).
fn setRecvTimeout(stream: std.net.Stream, secs: u32) void {
    const tv = posix.timeval{ .sec = @intCast(secs), .usec = 0 };
    posix.setsockopt(stream.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
}

/// Length-checked, content-constant-time slice equality for the auth token.
/// (The token length is not secret, so an early length mismatch is fine.)
fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Percent-decode a query-string value (`%XX` escapes, `+` → space). Caller
/// owns the result.
fn percentDecode(arena: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '%' and i + 2 < s.len) {
            if (hexDigit(s[i + 1])) |hi| {
                if (hexDigit(s[i + 2])) |lo| {
                    try out.append(arena, (hi << 4) | lo);
                    i += 3;
                    continue;
                }
            }
        }
        try out.append(arena, if (c == '+') ' ' else c);
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

// ===========================================================================
// Nostr search → DiscoverResult JSON
// ===========================================================================

fn runSearch(arena: Allocator, daemon: *Daemon, query: []const u8) ![]u8 {
    // Use the prober's health view: skip relays already known unreachable so a
    // dead relay's connect timeout doesn't stall the whole search.
    const health = daemon.healthSnapshot(arena) catch &.{};

    // Match the route the manager is configured for, so search over Tor/proxy
    // doesn't leak the real IP. The i2p route's `socks` is a SAM endpoint, not a
    // SOCKS proxy, so don't route relay search through it (Nostr-over-I2P is a
    // follow-up; until then i2p relay search is clearnet like the transfer side).
    var proxy: ?proxy_mod.Proxy = null;
    if (daemon.manager.cfg.route.usesSocks()) {
        proxy = proxy_mod.parseUrl(daemon.manager.cfg.socks) catch null;
    }

    const filter: nostr_mod.Filter = .{
        .kinds = &[_]u32{nip35.kind_torrent},
        .limit = 100,
    };

    var results: std.ArrayList(api.DiscoverResult) = .empty;
    var seen: std.ArrayList([40]u8) = .empty;
    const now = std.time.timestamp();

    for (health) |relay| {
        if (results.items.len >= 50) break;
        if (std.mem.eql(u8, relay.state, "unreachable")) continue;
        const url = relay.url;
        var r = relay_mod.Relay.connect(arena, url, proxy) catch continue;
        defer r.deinit();
        const events = relay_mod.subscribeAndCollect(arena, &r, filter, .{
            .timeout_ms = 7_000,
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
    const relays = [_]api.Relay{
        .{ .url = "wss://relay.damus.io", .state = "connected", .net = "clearnet", .events = 0 },
        .{ .url = "ws://abc.onion", .state = "unreachable", .net = "tor", .events = 0 },
    };
    const json = try buildStateJson(arena.allocator(), &d, &relays, "npub1test");

    var p = try std.json.parseFromSlice(std.json.Value, arena.allocator(), json, .{});
    defer p.deinit();
    const o = p.value.object;
    try testing.expect(o.get("transfers").? == .array);
    try testing.expect(o.get("seeds").? == .array);
    try testing.expect(o.get("relays").? == .array);
    try testing.expect(o.get("identity").? == .object);
    try testing.expect(o.get("settings").? == .object);
    try testing.expectEqual(@as(usize, 0), o.get("transfers").?.array.items.len);
    try testing.expectEqual(@as(usize, 2), o.get("relays").?.array.items.len);
    try testing.expectEqualStrings("connected", o.get("relays").?.array.items[0].object.get("state").?.string);
    try testing.expectEqualStrings("tor", o.get("relays").?.array.items[1].object.get("net").?.string);
    try testing.expectEqualStrings("npub1test", o.get("identity").?.object.get("npub").?.string);
}

test "constantTimeEql" {
    try testing.expect(constantTimeEql("abc123", "abc123"));
    try testing.expect(!constantTimeEql("abc123", "abc124"));
    try testing.expect(!constantTimeEql("abc", "abcd")); // length mismatch
    try testing.expect(constantTimeEql("", ""));
}

test "percentDecode: escapes and plus" {
    const a = testing.allocator;
    const r1 = try percentDecode(a, "big%20buck+bunny");
    defer a.free(r1);
    try testing.expectEqualStrings("big buck bunny", r1);
    // Trailing/invalid escapes are passed through literally.
    const r2 = try percentDecode(a, "100%");
    defer a.free(r2);
    try testing.expectEqualStrings("100%", r2);
    const r3 = try percentDecode(a, "%zz");
    defer a.free(r3);
    try testing.expectEqualStrings("%zz", r3);
}
