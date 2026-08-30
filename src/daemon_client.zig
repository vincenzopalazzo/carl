//! CLI <-> daemon bridge.
//!
//! A running `carl daemon` (standalone or the desktop app's sidecar) publishes
//! a small discovery file, `<config>/daemon.json` (mode 0600, next to the
//! nsec), holding its loopback port, auth token, and pid. CLI commands use it
//! to share one reality with the GUI instead of running invisible parallel
//! sessions:
//!
//!   - `carl download <source>` forwards the add to the daemon (the transfer
//!     shows up in the GUI, survives CLI exit, and persists across daemon
//!     restarts like any GUI-added transfer). `--standalone` or an explicit
//!     `--output-dir` keeps the old in-process behavior.
//!   - `carl status` prints the daemon's transfers — the same rows the GUI
//!     renders.
//!
//! A stale discovery file (daemon kill -9'd) is harmless: the liveness probe
//! is a real authenticated request, so the CLI simply falls back to a
//! standalone session.

const std = @import("std");
const api = @import("api.zig");
const nostr_config = @import("nostr_config.zig");

const Allocator = std.mem.Allocator;

const log = std.log.scoped(.daemon_client);

/// Largest response we buffer off the loopback socket. /api/state with a few
/// transfers is tens of KB; 8 MiB leaves generous headroom without letting a
/// misbehaving peer on the port eat memory.
const max_response_bytes: usize = 8 * 1024 * 1024;

pub const Discovery = struct {
    port: u16,
    token: []u8,
    pid: std.posix.pid_t,

    pub fn deinit(self: *Discovery, a: Allocator) void {
        a.free(self.token);
    }
};

pub fn discoveryPath(a: Allocator) ![]u8 {
    const dir = try nostr_config.configDir(a);
    defer a.free(dir);
    return std.fmt.allocPrint(a, "{s}/daemon.json", .{dir});
}

/// Daemon side: publish the discovery file (0600 — it carries the auth token).
/// Best-effort: a daemon that can't write it still serves; only the CLI
/// integration degrades (to standalone sessions).
pub fn writeDiscovery(a: Allocator, port: u16, token: []const u8) !void {
    const path = try discoveryPath(a);
    defer a.free(path);
    var j = api.Json.init(a);
    defer j.buf.deinit(a);
    try j.beginObject();
    try j.keyNumber("port", port);
    try j.keyString("token", token);
    try j.keyNumber("pid", std.c.getpid());
    try j.endObject();
    var f = try std.fs.cwd().createFile(path, .{ .truncate = true, .mode = 0o600 });
    defer f.close();
    try f.writeAll(j.buf.items);
}

/// Daemon side: unpublish on clean shutdown. A stale file left by kill -9 is
/// filtered out by the reader's liveness probe.
pub fn removeDiscovery(a: Allocator) void {
    const path = discoveryPath(a) catch return;
    defer a.free(path);
    std.fs.cwd().deleteFile(path) catch {};
}

/// Read and validate the discovery file: the daemon must answer an
/// authenticated request on the published port (this is also the liveness
/// probe). Returns null when no usable daemon is around.
pub fn read(a: Allocator) ?Discovery {
    const path = discoveryPath(a) catch return null;
    defer a.free(path);
    const data = std.fs.cwd().readFileAlloc(a, path, 4096) catch return null;
    defer a.free(data);
    const parsed = std.json.parseFromSlice(std.json.Value, a, data, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const obj = parsed.value.object;
    const port_v = obj.get("port") orelse return null;
    const token_v = obj.get("token") orelse return null;
    if (port_v != .integer or token_v != .string) return null;
    const pid_v = obj.get("pid");
    var disc: Discovery = .{
        .port = @intCast(port_v.integer),
        .token = a.dupe(u8, token_v.string) catch return null,
        .pid = if (pid_v != null and pid_v.? == .integer) @intCast(pid_v.?.integer) else 0,
    };
    // Liveness: an authenticated GET must succeed, otherwise the file is
    // stale (or something else owns the port now).
    const body = fetch(a, &disc, "GET", "/api/transfers", null) catch {
        disc.deinit(a);
        return null;
    };
    a.free(body);
    return disc;
}

pub const ForwardResult = struct {
    id: []u8,
    route: []u8,

    pub fn deinit(self: *ForwardResult, a: Allocator) void {
        a.free(self.id);
        a.free(self.route);
    }
};

/// Hand a download to the running daemon. `proxy_requested` maps the CLI's
/// `--proxy` flag onto the daemon's `proxy` route; otherwise the daemon's own
/// configured default route is used, so a plain `carl download` can't
/// accidentally go clearnet while the daemon anonymizes.
pub fn forwardDownload(a: Allocator, disc: *const Discovery, source: []const u8, proxy_requested: bool, want_nostr: bool) !ForwardResult {
    const route = if (proxy_requested)
        try a.dupe(u8, "proxy")
    else
        try daemonRoute(a, disc);
    errdefer a.free(route);

    var j = api.Json.init(a);
    defer j.buf.deinit(a);
    try j.beginObject();
    try j.keyString("source", source);
    try j.keyString("route", route);
    try j.keyBool("nostr", want_nostr);
    try j.endObject();

    const body = try fetch(a, disc, "POST", "/api/transfers", j.buf.items);
    defer a.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadResponse;
    const id_v = parsed.value.object.get("id") orelse return error.BadResponse;
    if (id_v != .string) return error.BadResponse;
    return .{ .id = try a.dupe(u8, id_v.string), .route = route };
}

/// The daemon's configured default route (from GET /api/state -> settings).
/// Doubles as a second liveness probe. Falls back to "direct" only when the
/// state payload is unreadable.
fn daemonRoute(a: Allocator, disc: *const Discovery) ![]u8 {
    const body = fetch(a, disc, "GET", "/api/state", null) catch
        return a.dupe(u8, "direct");
    defer a.free(body);
    const parsed = std.json.parseFromSlice(std.json.Value, a, body, .{}) catch
        return a.dupe(u8, "direct");
    defer parsed.deinit();
    if (parsed.value != .object) return a.dupe(u8, "direct");
    const settings = parsed.value.object.get("settings") orelse return a.dupe(u8, "direct");
    if (settings != .object) return a.dupe(u8, "direct");
    const route = settings.object.get("route") orelse return a.dupe(u8, "direct");
    if (route != .string) return a.dupe(u8, "direct");
    return a.dupe(u8, route.string);
}

/// One HTTP/1.1 request against the daemon's loopback server; returns the
/// response body on a 2xx status. The daemon answers `Connection: close`, so
/// the body is delimited by EOF.
pub fn fetch(a: Allocator, disc: *const Discovery, method: []const u8, path: []const u8, body: ?[]const u8) ![]u8 {
    const addr = try std.net.Address.parseIp4("127.0.0.1", disc.port);
    const stream = std.net.tcpConnectToAddress(addr) catch return error.DaemonUnreachable;
    defer stream.close();

    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(a);
    try req.appendSlice(a, method);
    try req.append(a, ' ');
    try req.appendSlice(a, path);
    try req.appendSlice(a, " HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Carl-Token: ");
    try req.appendSlice(a, disc.token);
    try req.appendSlice(a, "\r\nConnection: close\r\n");
    if (body) |b| {
        const len_hdr = try std.fmt.allocPrint(a, "Content-Type: application/json\r\nContent-Length: {d}\r\n", .{b.len});
        defer a.free(len_hdr);
        try req.appendSlice(a, len_hdr);
    }
    try req.appendSlice(a, "\r\n");
    if (body) |b| try req.appendSlice(a, b);
    try stream.writeAll(req.items);

    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(a);
    var chunk: [16384]u8 = undefined;
    while (raw.items.len < max_response_bytes) {
        const n = try stream.read(&chunk);
        if (n == 0) break;
        try raw.appendSlice(a, chunk[0..n]);
    }

    const header_end = std.mem.indexOf(u8, raw.items, "\r\n\r\n") orelse return error.BadResponse;
    const head = raw.items[0..header_end];
    // "HTTP/1.1 200 OK" — only the status code matters.
    const sp1 = std.mem.indexOfScalar(u8, head, ' ') orelse return error.BadResponse;
    const rest = head[sp1 + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    const code = std.fmt.parseInt(u16, rest[0..sp2], 10) catch return error.BadResponse;
    if (code == 401) return error.Unauthorized;
    if (code < 200 or code >= 300) return error.HttpStatus;
    return try a.dupe(u8, raw.items[header_end + 4 ..]);
}
