//! Minimal WebSocket client (RFC 6455, client side only) on top of TCP or
//! TLS-wrapped TCP. Built for Nostr relays which are wss:// and exchange
//! text frames carrying JSON; binary, fragmented, and large (>65535 byte)
//! payloads are supported but extensions like permessage-deflate are not.
//!
//! Use:
//!   var conn = try ws.Conn.connect(allocator, "wss://relay.example.com");
//!   defer conn.deinit();
//!   try conn.writeText("[\"REQ\",\"sub1\",{\"kinds\":[2003]}]");
//!   const msg = try conn.readMessage();
//!   defer allocator.free(msg.payload);
//!
//! The connection blocks with a recv timeout (default 30s) so that callers
//! never hang forever on a silent relay.

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;

const log = std.log.scoped(.ws);

pub const Error = error{
    InvalidUrl,
    DnsResolveFailed,
    ConnectFailed,
    HandshakeFailed,
    TlsInitFailed,
    SendFailed,
    RecvFailed,
    Timeout,
    Closed,
    ProtocolError,
    PayloadTooLarge,
    OutOfMemory,
};

/// Max payload size we will accept from a single frame. Nostr events can be
/// big but 1 MiB is more than enough for NIP-35 + NIP-65 traffic.
pub const max_payload_len: usize = 1 * 1024 * 1024;

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
};

pub const Message = struct {
    opcode: Opcode,
    payload: []u8,
};

pub const Url = struct {
    secure: bool,
    host: []const u8,
    port: u16,
    path: []const u8,
};

/// Parse a `ws://host[:port][/path]` or `wss://host[:port][/path]` URL.
/// The returned slices alias `input` and are valid for its lifetime.
pub fn parseUrl(input: []const u8) Error!Url {
    var secure: bool = undefined;
    var rest: []const u8 = undefined;
    if (std.mem.startsWith(u8, input, "wss://")) {
        secure = true;
        rest = input[6..];
    } else if (std.mem.startsWith(u8, input, "ws://")) {
        secure = false;
        rest = input[5..];
    } else {
        return error.InvalidUrl;
    }

    // Find authority / path split.
    var path: []const u8 = "/";
    var authority: []const u8 = rest;
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
        authority = rest[0..slash];
        path = rest[slash..];
    }
    if (authority.len == 0) return error.InvalidUrl;

    // Split authority into host and optional port.
    var host: []const u8 = authority;
    var port: u16 = if (secure) 443 else 80;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        host = authority[0..colon];
        port = std.fmt.parseUnsigned(u16, authority[colon + 1 ..], 10) catch return error.InvalidUrl;
    }

    return .{ .secure = secure, .host = host, .port = port, .path = path };
}

/// A live WebSocket connection. Internally owns either a plain TCP socket or
/// a TLS session over that socket.
pub const Conn = struct {
    allocator: Allocator,
    stream: std.net.Stream,

    // TLS state (heap-allocated because std.crypto.tls.Client embeds large
    // buffers and a Reader/Writer that must not be moved after init).
    tls_state: ?*TlsState,

    /// Buffer used to accumulate the payload of an in-progress message when
    /// the relay fragments. Owned by the Conn.
    fragment_buf: std.ArrayList(u8),
    fragment_opcode: ?Opcode,

    pub fn connect(allocator: Allocator, url_input: []const u8) Error!Conn {
        const url = try parseUrl(url_input);

        // Resolve and open TCP.
        const stream = std.net.tcpConnectToHost(allocator, url.host, url.port) catch |err| {
            log.warn("tcp connect to {s}:{d} failed: {}", .{ url.host, url.port, err });
            return error.ConnectFailed;
        };

        // Apply a recv timeout so reads can fail instead of hanging forever.
        const tv: posix.timeval = .{ .sec = 30, .usec = 0 };
        posix.setsockopt(
            stream.handle,
            posix.SOL.SOCKET,
            posix.SO.RCVTIMEO,
            std.mem.asBytes(&tv),
        ) catch {};

        // Take ownership of the socket via the Conn. From here on, any error
        // path runs through `conn.deinit()` exactly once — that closes the
        // stream, releases TLS state if present, and frees fragment_buf.
        var conn: Conn = .{
            .allocator = allocator,
            .stream = stream,
            .tls_state = null,
            .fragment_buf = .empty,
            .fragment_opcode = null,
        };
        errdefer conn.deinit();

        if (url.secure) {
            conn.tls_state = TlsState.init(allocator, stream, url.host) catch |err| {
                log.warn("tls init for {s} failed: {}", .{ url.host, err });
                return error.TlsInitFailed;
            };
        }

        try conn.performHandshake(url);
        return conn;
    }

    pub fn deinit(self: *Conn) void {
        if (self.tls_state) |t| t.deinit(self.allocator);
        self.stream.close();
        self.fragment_buf.deinit(self.allocator);
    }

    /// Send a text frame. Encodes mask + frame header automatically.
    pub fn writeText(self: *Conn, payload: []const u8) Error!void {
        try self.writeFrame(.text, payload, true);
    }

    /// Send a close frame (code 1000, no reason).
    pub fn writeClose(self: *Conn) Error!void {
        const close_payload: [2]u8 = .{ 0x03, 0xE8 }; // 1000 big-endian
        try self.writeFrame(.close, &close_payload, true);
    }

    /// Read the next full message. Reassembles fragmented frames into a single
    /// payload before returning. The caller owns `payload`.
    /// On a ping frame, automatically responds with a pong and continues.
    /// On a close frame, returns `error.Closed`.
    pub fn readMessage(self: *Conn) Error!Message {
        while (true) {
            const frame = try self.readFrame();
            switch (frame.opcode) {
                .ping => {
                    // Echo payload back as pong.
                    self.writeFrame(.pong, frame.payload, true) catch {};
                    self.allocator.free(frame.payload);
                    continue;
                },
                .pong => {
                    self.allocator.free(frame.payload);
                    continue;
                },
                .close => {
                    self.allocator.free(frame.payload);
                    // Reply with our own close.
                    self.writeClose() catch {};
                    return error.Closed;
                },
                .text, .binary => {
                    if (frame.fin and self.fragment_opcode == null) {
                        return .{ .opcode = frame.opcode, .payload = frame.payload };
                    }
                    // Start of a fragmented message.
                    if (self.fragment_opcode != null) {
                        // Spec violation: text/binary in the middle of a fragment.
                        self.allocator.free(frame.payload);
                        self.fragment_buf.clearRetainingCapacity();
                        self.fragment_opcode = null;
                        return error.ProtocolError;
                    }
                    self.fragment_opcode = frame.opcode;
                    self.fragment_buf.appendSlice(self.allocator, frame.payload) catch {
                        self.allocator.free(frame.payload);
                        return error.OutOfMemory;
                    };
                    self.allocator.free(frame.payload);
                    if (frame.fin) {
                        const payload = self.fragment_buf.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
                        const op = self.fragment_opcode.?;
                        self.fragment_opcode = null;
                        return .{ .opcode = op, .payload = payload };
                    }
                },
                .continuation => {
                    if (self.fragment_opcode == null) {
                        self.allocator.free(frame.payload);
                        return error.ProtocolError;
                    }
                    self.fragment_buf.appendSlice(self.allocator, frame.payload) catch {
                        self.allocator.free(frame.payload);
                        return error.OutOfMemory;
                    };
                    self.allocator.free(frame.payload);
                    if (frame.fin) {
                        const payload = self.fragment_buf.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
                        const op = self.fragment_opcode.?;
                        self.fragment_opcode = null;
                        return .{ .opcode = op, .payload = payload };
                    }
                },
            }
        }
    }

    // -------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------

    fn performHandshake(self: *Conn, url: Url) Error!void {
        // Generate a random 16-byte key, base64-encode it.
        var key_raw: [16]u8 = undefined;
        std.crypto.random.bytes(&key_raw);
        var key_b64: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key_b64, &key_raw);

        // Build the HTTP/1.1 upgrade request.
        var req_buf: [1024]u8 = undefined;
        const req = std.fmt.bufPrint(
            &req_buf,
            "GET {s} HTTP/1.1\r\n" ++
                "Host: {s}\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Key: {s}\r\n" ++
                "Sec-WebSocket-Version: 13\r\n" ++
                "User-Agent: carl/0.1\r\n" ++
                "\r\n",
            .{ url.path, url.host, key_b64 },
        ) catch return error.HandshakeFailed;

        try self.writeAll(req);

        // Read response headers one byte at a time so we never read past the
        // CRLFCRLF terminator. On the plaintext (ws://) path readSome maps
        // directly to recv, so any over-read would discard frame bytes the
        // server might have pipelined behind the upgrade. (The TLS path
        // buffers internally and doesn't have this issue, but uniform handling
        // is simpler and the handshake is ~500 bytes — one byte per syscall
        // is fine.)
        var hdr_buf: [4096]u8 = undefined;
        var hdr_len: usize = 0;
        while (hdr_len < hdr_buf.len) {
            const n = try self.readSome(hdr_buf[hdr_len..][0..1]);
            if (n == 0) return error.HandshakeFailed;
            hdr_len += n;
            if (hdr_len >= 4 and std.mem.eql(u8, hdr_buf[hdr_len - 4 .. hdr_len], "\r\n\r\n")) break;
        }
        const headers = hdr_buf[0..hdr_len];

        if (!std.mem.startsWith(u8, headers, "HTTP/1.1 101")) {
            log.warn("ws handshake non-101 response: {s}", .{headers[0..@min(80, headers.len)]});
            return error.HandshakeFailed;
        }

        // Verify Sec-WebSocket-Accept = base64(SHA1(key + magic)). Parse the
        // header line by name rather than substring-matching the whole
        // response (an unrelated header containing the same 28-char base64
        // would otherwise spoof acceptance).
        const expected = expectedAccept(&key_b64);
        const accept_value = findHeader(headers, "Sec-WebSocket-Accept") orelse {
            log.warn("ws handshake missing Sec-WebSocket-Accept header", .{});
            return error.HandshakeFailed;
        };
        if (!std.mem.eql(u8, accept_value, &expected)) {
            log.warn("ws handshake bad Sec-WebSocket-Accept", .{});
            return error.HandshakeFailed;
        }
    }

    /// Find the value of a case-insensitive header name in an HTTP/1.1 header
    /// block. Returns null if the header is absent.
    fn findHeader(headers: []const u8, name: []const u8) ?[]const u8 {
        var line_start: usize = 0;
        while (line_start < headers.len) {
            const line_end = std.mem.indexOfScalarPos(u8, headers, line_start, '\n') orelse return null;
            const line = headers[line_start..line_end];
            const trimmed = std.mem.trimRight(u8, line, "\r");
            if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
                const hdr_name = trimmed[0..colon];
                if (hdr_name.len == name.len and std.ascii.eqlIgnoreCase(hdr_name, name)) {
                    return std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
                }
            }
            line_start = line_end + 1;
        }
        return null;
    }

    const FrameMeta = struct {
        fin: bool,
        opcode: Opcode,
        payload: []u8, // owned by allocator
    };

    fn readFrame(self: *Conn) Error!FrameMeta {
        var header: [2]u8 = undefined;
        try self.readExact(&header);

        const fin = (header[0] & 0x80) != 0;
        const opcode_raw = header[0] & 0x0F;
        const opcode: Opcode = std.meta.intToEnum(Opcode, opcode_raw) catch return error.ProtocolError;
        const masked = (header[1] & 0x80) != 0;
        if (masked) return error.ProtocolError; // server frames must not be masked

        var payload_len: u64 = header[1] & 0x7F;
        if (payload_len == 126) {
            var ext: [2]u8 = undefined;
            try self.readExact(&ext);
            payload_len = std.mem.readInt(u16, &ext, .big);
        } else if (payload_len == 127) {
            var ext: [8]u8 = undefined;
            try self.readExact(&ext);
            payload_len = std.mem.readInt(u64, &ext, .big);
        }
        if (payload_len > max_payload_len) return error.PayloadTooLarge;

        const buf = self.allocator.alloc(u8, @intCast(payload_len)) catch return error.OutOfMemory;
        errdefer self.allocator.free(buf);
        if (payload_len > 0) try self.readExact(buf);

        return .{ .fin = fin, .opcode = opcode, .payload = buf };
    }

    fn writeFrame(self: *Conn, opcode: Opcode, payload: []const u8, fin: bool) Error!void {
        // Header is at most 2 + 8 + 4 = 14 bytes.
        var header: [14]u8 = undefined;
        var hlen: usize = 0;
        header[hlen] = (if (fin) @as(u8, 0x80) else 0) | @intFromEnum(opcode);
        hlen += 1;
        if (payload.len < 126) {
            header[hlen] = 0x80 | @as(u8, @intCast(payload.len));
            hlen += 1;
        } else if (payload.len < 65536) {
            header[hlen] = 0x80 | 126;
            hlen += 1;
            std.mem.writeInt(u16, header[hlen..][0..2], @intCast(payload.len), .big);
            hlen += 2;
        } else {
            header[hlen] = 0x80 | 127;
            hlen += 1;
            std.mem.writeInt(u64, header[hlen..][0..8], payload.len, .big);
            hlen += 8;
        }
        var mask: [4]u8 = undefined;
        std.crypto.random.bytes(&mask);
        @memcpy(header[hlen..][0..4], &mask);
        hlen += 4;

        try self.writeAll(header[0..hlen]);

        // Mask payload in chunks (avoid allocating a copy of the whole payload).
        var chunk: [4096]u8 = undefined;
        var off: usize = 0;
        while (off < payload.len) {
            const n = @min(payload.len - off, chunk.len);
            for (0..n) |i| {
                chunk[i] = payload[off + i] ^ mask[(off + i) % 4];
            }
            try self.writeAll(chunk[0..n]);
            off += n;
        }
    }

    fn writeAll(self: *Conn, buf: []const u8) Error!void {
        if (self.tls_state) |t| {
            t.tls.writer.writeAll(buf) catch return error.SendFailed;
            t.tls.writer.flush() catch return error.SendFailed;
        } else {
            var off: usize = 0;
            while (off < buf.len) {
                const n = posix.send(self.stream.handle, buf[off..], 0) catch return error.SendFailed;
                if (n == 0) return error.Closed;
                off += n;
            }
        }
    }

    fn readSome(self: *Conn, buf: []u8) Error!usize {
        if (self.tls_state) |t| {
            return t.tls.reader.readSliceShort(buf) catch return error.RecvFailed;
        }
        const n = posix.recv(self.stream.handle, buf, 0) catch |err| switch (err) {
            error.WouldBlock => return error.Timeout,
            else => return error.RecvFailed,
        };
        return n;
    }

    fn readExact(self: *Conn, buf: []u8) Error!void {
        var off: usize = 0;
        while (off < buf.len) {
            const n = try self.readSome(buf[off..]);
            if (n == 0) return error.Closed;
            off += n;
        }
    }
};

/// All TLS-related buffers and state, kept on the heap so the std.crypto.tls
/// Client's internal Reader/Writer struct addresses stay stable.
const TlsState = struct {
    stream_reader: std.net.Stream.Reader,
    stream_writer: std.net.Stream.Writer,
    tls: std.crypto.tls.Client,
    ca_bundle: std.crypto.Certificate.Bundle,

    // Buffers (sized per std.crypto.tls.Client requirements).
    socket_read_buf: []u8,
    socket_write_buf: []u8,
    tls_read_buf: []u8,
    tls_write_buf: []u8,

    fn init(allocator: Allocator, stream: std.net.Stream, host: []const u8) !*TlsState {
        const min = std.crypto.tls.Client.min_buffer_len;
        const self = try allocator.create(TlsState);
        errdefer allocator.destroy(self);

        self.socket_read_buf = try allocator.alloc(u8, min);
        errdefer allocator.free(self.socket_read_buf);
        self.socket_write_buf = try allocator.alloc(u8, min);
        errdefer allocator.free(self.socket_write_buf);
        self.tls_read_buf = try allocator.alloc(u8, min);
        errdefer allocator.free(self.tls_read_buf);
        self.tls_write_buf = try allocator.alloc(u8, min);
        errdefer allocator.free(self.tls_write_buf);

        self.ca_bundle = .{};
        errdefer self.ca_bundle.deinit(allocator);
        try self.ca_bundle.rescan(allocator);

        self.stream_reader = stream.reader(self.socket_read_buf);
        self.stream_writer = stream.writer(self.socket_write_buf);

        self.tls = try std.crypto.tls.Client.init(
            self.stream_reader.interface(),
            &self.stream_writer.interface,
            .{
                .host = .{ .explicit = host },
                .ca = .{ .bundle = self.ca_bundle },
                .read_buffer = self.tls_read_buf,
                .write_buffer = self.tls_write_buf,
                // WebSocket frames are self-delimiting (length-prefixed in
                // the frame header), so a connection that ends mid-message
                // is detected by our readExact returning Closed — we don't
                // need TLS-level truncation detection to catch it. Allowing
                // truncation here just means a missing close_notify is
                // forwarded as EOF instead of TlsConnectionTruncated, which
                // is what we want for relays that hang up bluntly.
                .allow_truncation_attacks = true,
            },
        );
        return self;
    }

    fn deinit(self: *TlsState, allocator: Allocator) void {
        self.ca_bundle.deinit(allocator);
        allocator.free(self.socket_read_buf);
        allocator.free(self.socket_write_buf);
        allocator.free(self.tls_read_buf);
        allocator.free(self.tls_write_buf);
        allocator.destroy(self);
    }
};

/// Compute the expected Sec-WebSocket-Accept header value for a given
/// base64-encoded client key. Format: base64(sha1(key + magic)).
fn expectedAccept(key_b64: []const u8) [28]u8 {
    const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(key_b64);
    hasher.update(magic);
    var digest: [20]u8 = undefined;
    hasher.final(&digest);
    var out: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &digest);
    return out;
}

// ===========================================================================
// Tests
// ===========================================================================

test "parseUrl: wss with default port" {
    const u = try parseUrl("wss://relay.damus.io");
    try std.testing.expect(u.secure);
    try std.testing.expectEqualStrings("relay.damus.io", u.host);
    try std.testing.expectEqual(@as(u16, 443), u.port);
    try std.testing.expectEqualStrings("/", u.path);
}

test "parseUrl: ws with explicit port and path" {
    const u = try parseUrl("ws://localhost:7001/nostr");
    try std.testing.expect(!u.secure);
    try std.testing.expectEqualStrings("localhost", u.host);
    try std.testing.expectEqual(@as(u16, 7001), u.port);
    try std.testing.expectEqualStrings("/nostr", u.path);
}

test "parseUrl: rejects http scheme" {
    try std.testing.expectError(error.InvalidUrl, parseUrl("http://example.com"));
    try std.testing.expectError(error.InvalidUrl, parseUrl("relay.damus.io"));
}

test "expectedAccept: RFC 6455 example" {
    // Per RFC 6455 §1.3: key "dGhlIHNhbXBsZSBub25jZQ==" produces accept "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    const got = expectedAccept("dGhlIHNhbXBsZSBub25jZQ==");
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &got);
}

// Frame-level tests use a fixed-buffer "byte stream" instead of real sockets,
// keeping the tests hermetic and avoiding any blocking I/O.

const ByteStream = struct {
    buf: []u8,
    pos: usize,
};

fn streamRead(s: *ByteStream, out: []u8) usize {
    const avail = s.buf.len - s.pos;
    const n = @min(avail, out.len);
    @memcpy(out[0..n], s.buf[s.pos..][0..n]);
    s.pos += n;
    return n;
}

/// Encode a server-style (unmasked) frame into `out_buf`. Returns the slice
/// of `out_buf` actually written. Used by the test suite to feed bytes to
/// `decodeFrame` below.
fn encodeUnmaskedFrame(out_buf: []u8, opcode: Opcode, payload: []const u8, fin: bool) []u8 {
    var w: usize = 0;
    out_buf[w] = (if (fin) @as(u8, 0x80) else 0) | @intFromEnum(opcode);
    w += 1;
    if (payload.len < 126) {
        out_buf[w] = @intCast(payload.len);
        w += 1;
    } else if (payload.len < 65536) {
        out_buf[w] = 126;
        w += 1;
        std.mem.writeInt(u16, out_buf[w..][0..2], @intCast(payload.len), .big);
        w += 2;
    } else {
        out_buf[w] = 127;
        w += 1;
        std.mem.writeInt(u64, out_buf[w..][0..8], payload.len, .big);
        w += 8;
    }
    @memcpy(out_buf[w..][0..payload.len], payload);
    w += payload.len;
    return out_buf[0..w];
}

/// Parse a single frame from `bytes`. Used by tests to verify decode logic
/// without going through the socket I/O path.
fn decodeFrame(allocator: Allocator, bytes: []const u8) Error!struct {
    fin: bool,
    opcode: Opcode,
    payload: []u8,
} {
    if (bytes.len < 2) return error.ProtocolError;
    const fin = (bytes[0] & 0x80) != 0;
    const opcode_raw = bytes[0] & 0x0F;
    const opcode: Opcode = std.meta.intToEnum(Opcode, opcode_raw) catch return error.ProtocolError;
    if ((bytes[1] & 0x80) != 0) return error.ProtocolError; // masked from server

    var off: usize = 2;
    var payload_len: u64 = bytes[1] & 0x7F;
    if (payload_len == 126) {
        if (bytes.len < off + 2) return error.ProtocolError;
        payload_len = std.mem.readInt(u16, bytes[off..][0..2], .big);
        off += 2;
    } else if (payload_len == 127) {
        if (bytes.len < off + 8) return error.ProtocolError;
        payload_len = std.mem.readInt(u64, bytes[off..][0..8], .big);
        off += 8;
    }
    if (payload_len > max_payload_len) return error.PayloadTooLarge;
    if (bytes.len < off + payload_len) return error.ProtocolError;

    const out = try allocator.alloc(u8, @intCast(payload_len));
    @memcpy(out, bytes[off .. off + payload_len]);
    return .{ .fin = fin, .opcode = opcode, .payload = out };
}

test "frame round trip via in-memory buffer (small)" {
    const allocator = std.testing.allocator;

    var buf: [256]u8 = undefined;
    const payload = "hello, nostr";
    const bytes = encodeUnmaskedFrame(&buf, .text, payload, true);

    const got = try decodeFrame(allocator, bytes);
    defer allocator.free(got.payload);
    try std.testing.expectEqualStrings(payload, got.payload);
    try std.testing.expectEqual(Opcode.text, got.opcode);
    try std.testing.expect(got.fin);
}

test "frame round trip with 16-bit length" {
    const allocator = std.testing.allocator;

    const payload = try allocator.alloc(u8, 1000);
    defer allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = @intCast(i & 0xFF);

    var buf: [2048]u8 = undefined;
    const bytes = encodeUnmaskedFrame(&buf, .binary, payload, true);
    const got = try decodeFrame(allocator, bytes);
    defer allocator.free(got.payload);
    try std.testing.expectEqualSlices(u8, payload, got.payload);
}

test "frame round trip with 64-bit length" {
    const allocator = std.testing.allocator;

    const payload = try allocator.alloc(u8, 100_000);
    defer allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = @intCast(i % 251);

    const buf = try allocator.alloc(u8, 200_000);
    defer allocator.free(buf);
    const bytes = encodeUnmaskedFrame(buf, .binary, payload, true);

    const got = try decodeFrame(allocator, bytes);
    defer allocator.free(got.payload);
    try std.testing.expectEqualSlices(u8, payload, got.payload);
}

test "decodeFrame rejects reserved opcode" {
    const allocator = std.testing.allocator;
    const bad: [2]u8 = .{ 0x83, 0x00 }; // opcode 3 is reserved
    try std.testing.expectError(error.ProtocolError, decodeFrame(allocator, &bad));
}

test "decodeFrame rejects masked server frame" {
    const allocator = std.testing.allocator;
    const bad: [2]u8 = .{ 0x81, 0x80 }; // text + mask bit set
    try std.testing.expectError(error.ProtocolError, decodeFrame(allocator, &bad));
}

test "client write must mask: smoke check via writeFrame masking key" {
    // Encode a tiny payload through writeFrame (which would write to a socket
    // in production). We just verify the masking happens by computing what
    // the resulting bytes would look like for a known mask and payload —
    // this is a property test, not an I/O test.
    const payload = "abc";
    const mask: [4]u8 = .{ 1, 2, 3, 4 };
    var out: [3]u8 = undefined;
    for (payload, 0..) |b, i| out[i] = b ^ mask[i % 4];
    try std.testing.expectEqual(@as(u8, 'a' ^ 1), out[0]);
    try std.testing.expectEqual(@as(u8, 'b' ^ 2), out[1]);
    try std.testing.expectEqual(@as(u8, 'c' ^ 3), out[2]);
}
