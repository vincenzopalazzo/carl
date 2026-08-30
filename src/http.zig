//! Minimal HTTP/1.1 request parsing and response building for the daemon.
//!
//! The repo has no HTTP server (only `std.http.Client` for outbound tracker /
//! relay traffic), and `std.http.Server`'s API has churned across Zig
//! releases, so this is a small hand-rolled subset matching the codebase's
//! roll-your-own-protocol style. It handles exactly what the localhost GUI
//! needs: a request line, headers, an optional Content-Length body, and
//! `Connection`/`Upgrade` lookups for the WebSocket handshake.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_headers = 48;

pub const Error = error{
    /// The buffer does not yet contain a full header block.
    Incomplete,
    Malformed,
    TooManyHeaders,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// A parsed request head. All slices borrow from the buffer passed to `parse`,
/// so the buffer must outlive the `Request`.
pub const Request = struct {
    method: []const u8,
    /// Full request target, e.g. "/api/search?q=debian".
    target: []const u8,
    /// Path portion of `target` (before '?').
    path: []const u8,
    /// Query portion of `target` (after '?'), empty if none.
    query: []const u8,
    version: []const u8,
    headers: [max_headers]Header,
    header_count: usize,
    /// Byte length of the head including the terminating CRLFCRLF. The body (if
    /// any) begins at this offset in the original buffer.
    head_len: usize,

    /// Case-insensitive header lookup.
    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        for (self.headers[0..self.header_count]) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    /// Parse `Content-Length`, defaulting to 0 when absent/invalid.
    pub fn contentLength(self: *const Request) usize {
        const v = self.header("content-length") orelse return 0;
        return std.fmt.parseUnsigned(usize, std.mem.trim(u8, v, " \t"), 10) catch 0;
    }

    /// True when this request is a WebSocket upgrade.
    pub fn isWebSocketUpgrade(self: *const Request) bool {
        const upgrade = self.header("upgrade") orelse return false;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, upgrade, " \t"), "websocket")) return false;
        const conn = self.header("connection") orelse return false;
        // Connection may be a comma list, e.g. "keep-alive, Upgrade".
        var it = std.mem.splitScalar(u8, conn, ',');
        while (it.next()) |part| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " \t"), "upgrade")) return true;
        }
        return false;
    }

    /// Look up a query parameter value (no percent-decoding beyond '+'→space is
    /// performed; the daemon's params are simple). Returns a slice into the
    /// request buffer, or null.
    pub fn queryParam(self: *const Request, name: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, self.query, '&');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
        }
        return null;
    }
};

/// Parse the request head out of `data`. Returns `Incomplete` until the full
/// header block (ending in CRLFCRLF) is present.
pub fn parse(data: []const u8) Error!Request {
    const head_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return error.Incomplete;
    const head = data[0..head_end];
    var lines = std.mem.splitSequence(u8, head, "\r\n");

    const request_line = lines.next() orelse return error.Malformed;
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = parts.next() orelse return error.Malformed;
    const target = parts.next() orelse return error.Malformed;
    const version = parts.next() orelse return error.Malformed;
    if (method.len == 0 or target.len == 0) return error.Malformed;

    const q = std.mem.indexOfScalar(u8, target, '?');
    const path = if (q) |i| target[0..i] else target;
    const query = if (q) |i| target[i + 1 ..] else "";

    var req = Request{
        .method = method,
        .target = target,
        .path = path,
        .query = query,
        .version = version,
        .headers = undefined,
        .header_count = 0,
        .head_len = head_end + 4,
    };

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.Malformed;
        if (req.header_count >= max_headers) return error.TooManyHeaders;
        req.headers[req.header_count] = .{
            .name = std.mem.trim(u8, line[0..colon], " \t"),
            .value = std.mem.trim(u8, line[colon + 1 ..], " \t"),
        };
        req.header_count += 1;
    }

    return req;
}

/// Status codes the daemon emits.
pub const Status = enum(u16) {
    ok = 200,
    no_content = 204,
    bad_request = 400,
    unauthorized = 401,
    not_found = 404,
    method_not_allowed = 405,
    conflict = 409,
    internal_error = 500,

    fn reason(self: Status) []const u8 {
        return switch (self) {
            .ok => "OK",
            .no_content => "No Content",
            .bad_request => "Bad Request",
            .unauthorized => "Unauthorized",
            .not_found => "Not Found",
            .method_not_allowed => "Method Not Allowed",
            .conflict => "Conflict",
            .internal_error => "Internal Server Error",
        };
    }
};

/// Build a complete HTTP/1.1 JSON response. `Connection: close` is always sent
/// (the daemon uses one request per connection). Caller owns the result.
pub fn jsonResponse(allocator: Allocator, status: Status, body: []const u8) Allocator.Error![]u8 {
    return response(allocator, status, "application/json", body);
}

/// Build a complete response with an arbitrary content type. Caller owns it.
pub fn response(allocator: Allocator, status: Status, content_type: []const u8, body: []const u8) Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var line: [64]u8 = undefined;
    const status_line = std.fmt.bufPrint(&line, "HTTP/1.1 {d} {s}\r\n", .{ @intFromEnum(status), status.reason() }) catch unreachable;
    try buf.appendSlice(allocator, status_line);
    try buf.appendSlice(allocator, "Content-Type: ");
    try buf.appendSlice(allocator, content_type);
    try buf.appendSlice(allocator, "\r\n");
    var clen: [48]u8 = undefined;
    const clen_line = std.fmt.bufPrint(&clen, "Content-Length: {d}\r\n", .{body.len}) catch unreachable;
    try buf.appendSlice(allocator, clen_line);
    // The GUI runs in a webview on a different origin (tauri://, file://,
    // http://localhost), so allow cross-origin reads. The token guard, not
    // CORS, is what protects the daemon. `Allow-Methods` is required for the
    // browser preflight to permit POST/DELETE (and the X-Carl-Token GET) —
    // without it the browser blocks every non-simple request.
    try buf.appendSlice(allocator, "Access-Control-Allow-Origin: *\r\n");
    try buf.appendSlice(allocator, "Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS\r\n");
    // Wildcard so custom headers (X-Carl-Token and the X-Carl-Filename/Route/
    // Nostr upload headers) all pass the browser preflight. Requests are never
    // credentialed, so `*` applies; the token is the actual guard.
    try buf.appendSlice(allocator, "Access-Control-Allow-Headers: *\r\n");
    try buf.appendSlice(allocator, "Connection: close\r\n\r\n");
    try buf.appendSlice(allocator, body);
    return buf.toOwnedSlice(allocator);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "parse: GET with query and headers" {
    const raw = "GET /api/search?q=debian&limit=10 HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Carl-Token: abc123\r\n\r\n";
    const req = try parse(raw);
    try testing.expectEqualStrings("GET", req.method);
    try testing.expectEqualStrings("/api/search", req.path);
    try testing.expectEqualStrings("q=debian&limit=10", req.query);
    try testing.expectEqualStrings("abc123", req.header("x-carl-token").?);
    try testing.expectEqualStrings("debian", req.queryParam("q").?);
    try testing.expectEqualStrings("10", req.queryParam("limit").?);
    try testing.expectEqual(@as(?[]const u8, null), req.queryParam("missing"));
}

test "parse: Incomplete until CRLFCRLF" {
    try testing.expectError(error.Incomplete, parse("GET / HTTP/1.1\r\nHost: x\r\n"));
}

test "parse: POST body offset via head_len + Content-Length" {
    const raw = "POST /api/transfers HTTP/1.1\r\nContent-Length: 7\r\n\r\nmagnet:";
    const req = try parse(raw);
    try testing.expectEqualStrings("POST", req.method);
    try testing.expectEqual(@as(usize, 7), req.contentLength());
    try testing.expectEqualStrings("magnet:", raw[req.head_len..]);
}

test "parse: case-insensitive header lookup" {
    const raw = "GET / HTTP/1.1\r\nCoNtEnT-tYpE: application/json\r\n\r\n";
    const req = try parse(raw);
    try testing.expectEqualStrings("application/json", req.header("content-type").?);
}

test "isWebSocketUpgrade: detects upgrade with comma-listed Connection" {
    const raw = "GET /ws HTTP/1.1\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Key: x\r\n\r\n";
    const req = try parse(raw);
    try testing.expect(req.isWebSocketUpgrade());
}

test "isWebSocketUpgrade: false for plain GET" {
    const raw = "GET / HTTP/1.1\r\nHost: x\r\n\r\n";
    const req = try parse(raw);
    try testing.expect(!req.isWebSocketUpgrade());
}

test "jsonResponse: well-formed status line, content-length, body" {
    const allocator = testing.allocator;
    const body = "{\"ok\":true}";
    const resp = try jsonResponse(allocator, .ok, body);
    defer allocator.free(resp);
    try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, resp, "Content-Type: application/json\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Content-Length: 11\r\n") != null);
    // CORS preflight needs Allow-Methods or the browser blocks POST/DELETE.
    try testing.expect(std.mem.indexOf(u8, resp, "Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Access-Control-Allow-Origin: *\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, resp, body));
}

test "response: 401 reason phrase" {
    const allocator = testing.allocator;
    const resp = try jsonResponse(allocator, .unauthorized, "{}");
    defer allocator.free(resp);
    try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 401 Unauthorized\r\n"));
}
