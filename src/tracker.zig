const std = @import("std");
const Allocator = std.mem.Allocator;
const bencode = @import("bencode.zig");
const proxy_mod = @import("proxy.zig");
const udp_tracker = @import("udp_tracker.zig");

const log = std.log.scoped(.tracker);

/// A peer returned by the tracker.
pub const Peer = struct {
    ip: [4]u8,
    port: u16,
};

/// Event sent to the tracker in an announce request.
pub const Event = enum {
    none,
    started,
    completed,
    stopped,

    pub fn queryValue(self: Event) ?[]const u8 {
        return switch (self) {
            .none => null,
            .started => "started",
            .completed => "completed",
            .stopped => "stopped",
        };
    }
};

/// Parameters for a tracker announce request.
pub const AnnounceRequest = struct {
    info_hash: [20]u8,
    peer_id: [20]u8,
    port: u16,
    uploaded: u64,
    downloaded: u64,
    left: u64,
    compact: bool,
    event: Event,
};

/// Parsed tracker announce response.
pub const AnnounceResponse = struct {
    interval: u64,
    min_interval: ?u64,
    complete: ?u64,
    incomplete: ?u64,
    peers: []const Peer,
    failure_reason: ?[]const u8,
    warning_message: ?[]const u8,

    pub fn deinit(self: AnnounceResponse, allocator: Allocator) void {
        allocator.free(self.peers);
        if (self.failure_reason) |s| allocator.free(s);
        if (self.warning_message) |s| allocator.free(s);
    }
};

pub const TrackerError = error{
    InvalidResponse,
    TrackerFailure,
    HttpError,
    OutOfMemory,
};

/// BEP 3 `interval` is required, but a tracker can still send 0 (or a
/// multi-hour value). 0 would re-announce every maintenance tick and, on a
/// proxied session, block the event loop on a SOCKS GET forever. Floor at
/// 60s (or the tracker's own min interval, whichever is larger) and cap at
/// 6h so a broken tracker cannot silence us until restart.
pub fn clampInterval(interval: u64, min_interval: ?u64) u64 {
    const floor: u64 = @max(min_interval orelse 60, 60);
    const raw = if (interval == 0) floor else interval;
    return std.math.clamp(raw, floor, 6 * 60 * 60);
}

/// Build the full announce URL with query parameters.
pub fn buildAnnounceUrl(
    allocator: Allocator,
    announce_url: []const u8,
    req: AnnounceRequest,
) error{OutOfMemory}![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    // Base URL
    buf.appendSlice(allocator, announce_url) catch return error.OutOfMemory;

    // Separator: ? or &
    if (std.mem.indexOfScalar(u8, announce_url, '?') != null) {
        buf.append(allocator, '&') catch return error.OutOfMemory;
    } else {
        buf.append(allocator, '?') catch return error.OutOfMemory;
    }

    // info_hash (percent-encoded raw bytes)
    buf.appendSlice(allocator, "info_hash=") catch return error.OutOfMemory;
    try percentEncode(allocator, &buf, &req.info_hash);

    // peer_id (percent-encoded raw bytes)
    buf.appendSlice(allocator, "&peer_id=") catch return error.OutOfMemory;
    try percentEncode(allocator, &buf, &req.peer_id);

    // port
    buf.appendSlice(allocator, "&port=") catch return error.OutOfMemory;
    try appendInt(allocator, &buf, req.port);

    // uploaded
    buf.appendSlice(allocator, "&uploaded=") catch return error.OutOfMemory;
    try appendInt(allocator, &buf, req.uploaded);

    // downloaded
    buf.appendSlice(allocator, "&downloaded=") catch return error.OutOfMemory;
    try appendInt(allocator, &buf, req.downloaded);

    // left
    buf.appendSlice(allocator, "&left=") catch return error.OutOfMemory;
    try appendInt(allocator, &buf, req.left);

    // compact
    buf.appendSlice(allocator, "&compact=") catch return error.OutOfMemory;
    buf.append(allocator, if (req.compact) '1' else '0') catch return error.OutOfMemory;

    // event (omit if none)
    if (req.event.queryValue()) |ev| {
        buf.appendSlice(allocator, "&event=") catch return error.OutOfMemory;
        buf.appendSlice(allocator, ev) catch return error.OutOfMemory;
    }

    return buf.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

/// Parse a tracker announce response from bencoded bytes.
pub fn parseAnnounceResponse(
    allocator: Allocator,
    data: []const u8,
) TrackerError!AnnounceResponse {
    const root = bencode.decode(allocator, data) catch return error.InvalidResponse;
    defer root.deinit(allocator);

    // Check for failure
    if (root.dictGet("failure reason")) |fr| {
        if (fr.asString()) |s| {
            const reason = allocator.dupe(u8, s) catch return error.OutOfMemory;
            return .{
                .interval = 0,
                .min_interval = null,
                .complete = null,
                .incomplete = null,
                .peers = &.{},
                .failure_reason = reason,
                .warning_message = null,
            };
        }
    }

    const interval_val = root.dictGet("interval") orelse return error.InvalidResponse;
    const interval: u64 = std.math.cast(u64, interval_val.asInt() orelse return error.InvalidResponse) orelse return error.InvalidResponse;

    const min_interval = if (root.dictGet("min interval")) |v|
        if (v.asInt()) |i| std.math.cast(u64, i) else null
    else
        null;

    const complete = if (root.dictGet("complete")) |v|
        if (v.asInt()) |i| std.math.cast(u64, i) else null
    else
        null;

    const incomplete = if (root.dictGet("incomplete")) |v|
        if (v.asInt()) |i| std.math.cast(u64, i) else null
    else
        null;

    const warning_message = if (root.dictGet("warning message")) |wm|
        if (wm.asString()) |s|
            allocator.dupe(u8, s) catch return error.OutOfMemory
        else
            null
    else
        null;
    errdefer if (warning_message) |w| allocator.free(w);

    // Parse peers -- supports both compact (string) and dict (list) format
    const peers_val = root.dictGet("peers") orelse return error.InvalidResponse;
    const peers = switch (peers_val) {
        .string => |compact_data| try parseCompactPeers(allocator, compact_data),
        .list => |peer_list| try parseDictPeers(allocator, peer_list),
        else => return error.InvalidResponse,
    };

    return .{
        .interval = interval,
        .min_interval = min_interval,
        .complete = complete,
        .incomplete = incomplete,
        .peers = peers,
        .failure_reason = null,
        .warning_message = warning_message,
    };
}

/// Perform a tracker announce over whichever transport `announce_url` names.
/// Returns the parsed response. When `proxy` is set, the announce is tunneled
/// through it (fail-closed: no direct request).
///
/// This is the single dispatch point for every announce in carl — the session
/// loop, `carl announce`, and the seeding paths all come through here, so the
/// udp:// and proxy rules below cannot drift between callers.
pub fn announce(
    allocator: Allocator,
    announce_url: []const u8,
    req: AnnounceRequest,
    proxy: ?proxy_mod.Proxy,
) TrackerError!AnnounceResponse {
    if (!std.mem.startsWith(u8, announce_url, "udp://")) {
        return announceHttp(allocator, announce_url, req, proxy);
    }

    // BEP 15: udp:// goes to the UDP tracker client. UDP cannot be tunneled
    // through SOCKS/HTTP proxies, so with a proxy set we must not dial it
    // directly — that would leak the real IP. Rewrite
    // udp://host:port → http://host:port/announce (most public trackers serve
    // both protocols on the same port) and tunnel that instead.
    if (proxy != null) {
        var buf: [512]u8 = undefined;
        const http_url = udpAsHttpUrl(&buf, announce_url) orelse return error.HttpError;
        log.info("proxied: rewriting {s} -> {s}", .{ announce_url, http_url });
        return announceHttp(allocator, http_url, req, proxy);
    }

    return udp_tracker.announce(allocator, announce_url, req) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // TrackerError has no UDP-specific variant; log the real cause so a
        // bare "HttpError" on a udp:// URL is still diagnosable.
        else => {
            log.warn("UDP tracker {s} failed: {t}", .{ announce_url, err });
            return error.HttpError;
        },
    };
}

/// udp://host:port[/anything] → http://host:port/announce
fn udpAsHttpUrl(buf: []u8, udp_url: []const u8) ?[]const u8 {
    const rest = udp_url["udp://".len..];
    const slash_pos = std.mem.indexOfScalar(u8, rest, '/');
    const host_port = rest[0 .. slash_pos orelse rest.len];
    const url = std.fmt.bufPrint(buf, "http://{s}/announce", .{host_port}) catch return null;
    return url;
}

fn announceHttp(
    allocator: Allocator,
    announce_url: []const u8,
    req: AnnounceRequest,
    proxy: ?proxy_mod.Proxy,
) TrackerError!AnnounceResponse {
    const url = buildAnnounceUrl(allocator, announce_url, req) catch return error.OutOfMemory;
    defer allocator.free(url);

    if (proxy) |px| return announceThroughProxy(allocator, px, url);

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_body: std.ArrayList(u8) = .empty;
    defer response_body.deinit(allocator);

    var adapt_buf: [4096]u8 = undefined;
    const deprecated_writer = response_body.writer(allocator);
    var adapter = deprecated_writer.adaptToNewApi(&adapt_buf);

    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &adapter.new_interface,
    }) catch return error.HttpError;

    if (result.status != .ok) return error.HttpError;

    // Flush the adapter's buffered tail: a response smaller than the adapter
    // buffer (announce responses almost always are) would otherwise never
    // reach `response_body` and parse as empty.
    const buffered = adapter.new_interface.buffered();
    if (buffered.len > 0) {
        response_body.appendSlice(allocator, buffered) catch return error.OutOfMemory;
    }

    return parseAnnounceResponse(allocator, response_body.items);
}

/// Announce by tunneling the GET through the proxy. `http://` goes in plaintext,
/// `https://` runs TLS over the proxied stream -- both via `proxy.httpGet`, so
/// nothing is ever sent directly.
fn announceThroughProxy(allocator: Allocator, proxy: proxy_mod.Proxy, url: []const u8) TrackerError!AnnounceResponse {
    const body = proxy_mod.httpGet(allocator, proxy, url, null) catch |err| {
        log.debug("proxied tracker announce failed: {}", .{err});
        return error.HttpError;
    };
    defer allocator.free(body);
    return parseAnnounceResponse(allocator, body);
}

// --- Internal helpers ---

/// Percent-encode raw bytes for URL query parameters.
fn percentEncode(allocator: Allocator, buf: *std.ArrayList(u8), data: []const u8) error{OutOfMemory}!void {
    for (data) |byte| {
        if (isUnreserved(byte)) {
            buf.append(allocator, byte) catch return error.OutOfMemory;
        } else {
            buf.append(allocator, '%') catch return error.OutOfMemory;
            const hex = "0123456789ABCDEF";
            buf.append(allocator, hex[byte >> 4]) catch return error.OutOfMemory;
            buf.append(allocator, hex[byte & 0x0f]) catch return error.OutOfMemory;
        }
    }
}

fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => true,
        else => false,
    };
}

fn appendInt(allocator: Allocator, buf: *std.ArrayList(u8), value: anytype) error{OutOfMemory}!void {
    var num_buf: [20]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{value}) catch unreachable;
    buf.appendSlice(allocator, num_str) catch return error.OutOfMemory;
}

/// Parse compact peer format: 6 bytes per peer (4 IP + 2 port, big-endian).
fn parseCompactPeers(allocator: Allocator, data: []const u8) TrackerError![]Peer {
    if (data.len % 6 != 0) return error.InvalidResponse;

    const count = data.len / 6;
    const peers = allocator.alloc(Peer, count) catch return error.OutOfMemory;
    errdefer allocator.free(peers);

    for (0..count) |i| {
        const offset = i * 6;
        peers[i] = .{
            .ip = .{ data[offset], data[offset + 1], data[offset + 2], data[offset + 3] },
            .port = @as(u16, data[offset + 4]) << 8 | @as(u16, data[offset + 5]),
        };
    }

    return peers;
}

/// Parse dictionary peer format: list of dicts with "ip", "port", "peer id" keys.
fn parseDictPeers(allocator: Allocator, peer_list: []const bencode.Value) TrackerError![]Peer {
    var peers: std.ArrayList(Peer) = .empty;
    errdefer peers.deinit(allocator);

    for (peer_list) |entry| {
        const ip_val = entry.dictGet("ip") orelse continue;
        const ip_str = ip_val.asString() orelse continue;
        const port_val = entry.dictGet("port") orelse continue;
        const port_int = port_val.asInt() orelse continue;

        const ip = parseIpv4(ip_str) orelse continue;
        peers.append(allocator, .{
            .ip = ip,
            .port = std.math.cast(u16, port_int) orelse continue,
        }) catch return error.OutOfMemory;
    }

    return peers.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

/// Parse an IPv4 address string like "192.168.1.1" into 4 bytes.
fn parseIpv4(s: []const u8) ?[4]u8 {
    var result: [4]u8 = undefined;
    var octet: usize = 0;
    var start: usize = 0;

    for (s, 0..) |c, i| {
        if (c == '.') {
            if (octet >= 3) return null;
            const val = std.fmt.parseUnsigned(u8, s[start..i], 10) catch return null;
            result[octet] = val;
            octet += 1;
            start = i + 1;
        }
    }

    if (octet != 3) return null;
    const val = std.fmt.parseUnsigned(u8, s[start..], 10) catch return null;
    result[3] = val;

    return result;
}

// --- Tests ---

test "build announce URL" {
    const allocator = std.testing.allocator;

    const url = try buildAnnounceUrl(allocator, "http://tracker.example.com/announce", .{
        .info_hash = [_]u8{0x12} ** 20,
        .peer_id = [_]u8{0xAB} ** 20,
        .port = 6881,
        .uploaded = 0,
        .downloaded = 0,
        .left = 1024,
        .compact = true,
        .event = .started,
    });
    defer allocator.free(url);

    // Verify starts with base URL
    try std.testing.expect(std.mem.startsWith(u8, url, "http://tracker.example.com/announce?"));

    // Verify contains required params
    try std.testing.expect(std.mem.indexOf(u8, url, "info_hash=%12") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "&port=6881") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "&uploaded=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "&left=1024") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "&compact=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "&event=started") != null);
}

test "build announce URL with existing query params" {
    const allocator = std.testing.allocator;

    const url = try buildAnnounceUrl(allocator, "http://tracker.example.com/announce?passkey=abc", .{
        .info_hash = [_]u8{0} ** 20,
        .peer_id = [_]u8{0} ** 20,
        .port = 6881,
        .uploaded = 0,
        .downloaded = 0,
        .left = 0,
        .compact = true,
        .event = .none,
    });
    defer allocator.free(url);

    // Should use & instead of ? since URL already has query params
    try std.testing.expect(std.mem.startsWith(u8, url, "http://tracker.example.com/announce?passkey=abc&"));
    // event=none should be omitted
    try std.testing.expect(std.mem.indexOf(u8, url, "event=") == null);
}

test "parse compact peers" {
    const allocator = std.testing.allocator;

    // Two peers: 192.168.1.1:6881 and 10.0.0.1:80
    const compact = [_]u8{
        192, 168, 1, 1, 0x1A, 0xE1, // 192.168.1.1:6881
        10, 0, 0, 1, 0x00, 0x50, // 10.0.0.1:80
    };

    // Build response: d8:intervali900e5:peers12:<compact>e
    var resp_buf: std.ArrayList(u8) = .empty;
    defer resp_buf.deinit(allocator);
    resp_buf.appendSlice(allocator, "d8:intervali900e5:peers12:") catch unreachable;
    resp_buf.appendSlice(allocator, &compact) catch unreachable;
    resp_buf.append(allocator, 'e') catch unreachable;

    const resp = try parseAnnounceResponse(allocator, resp_buf.items);
    defer resp.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 900), resp.interval);
    try std.testing.expectEqual(@as(usize, 2), resp.peers.len);

    try std.testing.expectEqual([4]u8{ 192, 168, 1, 1 }, resp.peers[0].ip);
    try std.testing.expectEqual(@as(u16, 6881), resp.peers[0].port);

    try std.testing.expectEqual([4]u8{ 10, 0, 0, 1 }, resp.peers[1].ip);
    try std.testing.expectEqual(@as(u16, 80), resp.peers[1].port);
}

test "parse dict peers" {
    const allocator = std.testing.allocator;

    const resp_data =
        "d8:intervali1800e5:peersld2:ip11:192.168.1.14:porti6881eed2:ip8:10.0.0.14:porti80eeee";

    const resp = try parseAnnounceResponse(allocator, resp_data);
    defer resp.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 1800), resp.interval);
    try std.testing.expectEqual(@as(usize, 2), resp.peers.len);

    try std.testing.expectEqual([4]u8{ 192, 168, 1, 1 }, resp.peers[0].ip);
    try std.testing.expectEqual(@as(u16, 6881), resp.peers[0].port);
}

test "parse failure response" {
    const allocator = std.testing.allocator;

    const resp_data = "d14:failure reason15:torrent unknowne";

    const resp = try parseAnnounceResponse(allocator, resp_data);
    defer resp.deinit(allocator);

    try std.testing.expect(resp.failure_reason != null);
    try std.testing.expectEqualStrings("torrent unknown", resp.failure_reason.?);
    try std.testing.expectEqual(@as(usize, 0), resp.peers.len);
}

test "parse response with optional fields" {
    const allocator = std.testing.allocator;

    // Compact peers with complete/incomplete/min interval
    var resp_buf: std.ArrayList(u8) = .empty;
    defer resp_buf.deinit(allocator);
    resp_buf.appendSlice(allocator, "d8:completei50e10:incompletei10e8:intervali900e12:min intervali300e5:peers0:e") catch unreachable;

    const resp = try parseAnnounceResponse(allocator, resp_buf.items);
    defer resp.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 900), resp.interval);
    try std.testing.expectEqual(@as(u64, 300), resp.min_interval.?);
    try std.testing.expectEqual(@as(u64, 50), resp.complete.?);
    try std.testing.expectEqual(@as(u64, 10), resp.incomplete.?);
    try std.testing.expectEqual(@as(usize, 0), resp.peers.len);
}

test "percent encode" {
    const allocator = std.testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    // Unreserved chars pass through
    try percentEncode(allocator, &buf, "abc123");
    try std.testing.expectEqualStrings("abc123", buf.items);

    // Reset
    buf.clearRetainingCapacity();

    // Binary data gets encoded
    try percentEncode(allocator, &buf, &[_]u8{ 0x00, 0xFF, 0x20 });
    try std.testing.expectEqualStrings("%00%FF%20", buf.items);
}

test "parse IPv4" {
    const ip = parseIpv4("192.168.1.1").?;
    try std.testing.expectEqual([4]u8{ 192, 168, 1, 1 }, ip);

    try std.testing.expect(parseIpv4("invalid") == null);
    try std.testing.expect(parseIpv4("1.2.3") == null);
    try std.testing.expect(parseIpv4("1.2.3.4.5") == null);
}

test "udp as http url rewrite" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "http://tracker.example.com:1337/announce",
        udpAsHttpUrl(&buf, "udp://tracker.example.com:1337/announce").?,
    );
    try std.testing.expectEqualStrings(
        "http://tracker.example.com:1337/announce",
        udpAsHttpUrl(&buf, "udp://tracker.example.com:1337").?,
    );
}

test "clampInterval floors zero and honors min interval" {
    try std.testing.expectEqual(@as(u64, 60), clampInterval(0, null));
    try std.testing.expectEqual(@as(u64, 120), clampInterval(0, 120));
    try std.testing.expectEqual(@as(u64, 1800), clampInterval(1800, null));
    try std.testing.expectEqual(@as(u64, 900), clampInterval(60, 900));
    try std.testing.expectEqual(@as(u64, 6 * 60 * 60), clampInterval(99_999, null));
}

test "build announce URL never includes ip= (no listen-IP leak)" {
    const allocator = std.testing.allocator;
    const url = try buildAnnounceUrl(allocator, "http://tracker.example.com/announce", .{
        .info_hash = [_]u8{0} ** 20,
        .peer_id = [_]u8{0} ** 20,
        .port = 0,
        .uploaded = 0,
        .downloaded = 0,
        .left = 1,
        .compact = true,
        .event = .none,
    });
    defer allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "ip=") == null);
    try std.testing.expect(std.mem.indexOf(u8, url, "&port=0") != null);
}
