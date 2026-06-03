//! In-process Nostr relay mock for testing the client side of `relay.zig`.
//!
//! Binds a TCP listener on `127.0.0.1:0` (OS-assigned port), accepts a single
//! WebSocket connection, performs the server-side RFC 6455 handshake, and
//! exposes a scripted API: `sendEvent`, `sendEose`, `sendOk`, `sendNotice`,
//! `recvText`, `closeFrame`. The mock encodes frames *unmasked* (server-side
//! per RFC 6455 §5.1) so the real `ws.Conn` client reads them as intended.
//!
//! What this mock DOES NOT exercise:
//!   - TLS (`wss://`) — handshake is plaintext only. The TLS code path in
//!     `ws.TlsState` is covered by real-network smoke tests, not here.
//!   - Frame fragmentation — every message is a single text frame.
//!   - Server-initiated pings — relays in the wild occasionally ping; we
//!     don't here, so the client's pong response code is exercised only by
//!     unit tests on the encoder, not end-to-end.
//!   - Extended-payload-length (>64 KiB) frames — Nostr events typically fit
//!     in 7-bit length; we don't synthesize a huge event.
//!
//! Use:
//!   var mock = try MockRelay.start(allocator);
//!   defer mock.deinit();
//!   const url = try mock.urlAlloc(allocator); // "ws://127.0.0.1:PORT"
//!   defer allocator.free(url);
//!
//!   // In a background thread, run the mock script:
//!   const t = try std.Thread.spawn(.{}, runScript, .{ &mock });
//!   defer t.join();
//!
//!   // Client side: connect via real ws.Conn and exercise relay.zig logic.

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const ws = @import("ws.zig");

const log = std.log.scoped(.mock_relay);

pub const Error = error{
    ListenFailed,
    AcceptFailed,
    HandshakeFailed,
    SendFailed,
    RecvFailed,
    Closed,
    OutOfMemory,
};

/// One mock relay session. Owns a TCP listener and (after the client connects)
/// one accepted stream. Single-connection — designed for one test at a time.
pub const MockRelay = struct {
    allocator: Allocator,
    server: std.net.Server,
    port: u16,
    /// Set after `accept()` is called. Null until then.
    stream: ?std.net.Stream = null,

    /// Bind to `127.0.0.1:0` and start listening. Caller gets `port`.
    pub fn start(allocator: Allocator) Error!MockRelay {
        const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
        var server = addr.listen(.{ .reuse_address = true }) catch return error.ListenFailed;
        errdefer server.deinit();

        const port = server.listen_address.in.getPort();
        return .{
            .allocator = allocator,
            .server = server,
            .port = port,
        };
    }

    pub fn deinit(self: *MockRelay) void {
        if (self.stream) |s| s.close();
        self.server.deinit();
    }

    /// Return a `ws://127.0.0.1:PORT` URL the client can connect to.
    pub fn urlAlloc(self: *const MockRelay, allocator: Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "ws://127.0.0.1:{d}", .{self.port});
    }

    /// Block until the client connects, then perform the WS server handshake.
    /// On success, `self.stream` is set.
    pub fn accept(self: *MockRelay) Error!void {
        const accepted = self.server.accept() catch return error.AcceptFailed;
        self.stream = accepted.stream;
        try self.performHandshake();
    }

    // -----------------------------------------------------------------------
    // Scripted send API. All frames are FIN=1 text/close/etc, unmasked.
    // -----------------------------------------------------------------------

    /// Send a relay-to-client `["EVENT", sub_id, event_obj]` message. `event_json`
    /// must be a complete serialized Nostr event (the `{"id":...,"pubkey":...}`).
    pub fn sendEvent(self: *MockRelay, sub_id: []const u8, event_json: []const u8) Error!void {
        const msg = std.fmt.allocPrint(self.allocator, "[\"EVENT\",\"{s}\",{s}]", .{ sub_id, event_json }) catch return error.OutOfMemory;
        defer self.allocator.free(msg);
        try self.sendFrame(.text, msg);
    }

    pub fn sendEose(self: *MockRelay, sub_id: []const u8) Error!void {
        const msg = std.fmt.allocPrint(self.allocator, "[\"EOSE\",\"{s}\"]", .{sub_id}) catch return error.OutOfMemory;
        defer self.allocator.free(msg);
        try self.sendFrame(.text, msg);
    }

    pub fn sendOk(self: *MockRelay, event_id_hex: []const u8, accepted: bool, message: []const u8) Error!void {
        const flag: []const u8 = if (accepted) "true" else "false";
        const msg = std.fmt.allocPrint(self.allocator, "[\"OK\",\"{s}\",{s},\"{s}\"]", .{ event_id_hex, flag, message }) catch return error.OutOfMemory;
        defer self.allocator.free(msg);
        try self.sendFrame(.text, msg);
    }

    pub fn sendNotice(self: *MockRelay, message: []const u8) Error!void {
        const msg = std.fmt.allocPrint(self.allocator, "[\"NOTICE\",\"{s}\"]", .{message}) catch return error.OutOfMemory;
        defer self.allocator.free(msg);
        try self.sendFrame(.text, msg);
    }

    pub fn sendClosed(self: *MockRelay, sub_id: []const u8, message: []const u8) Error!void {
        const msg = std.fmt.allocPrint(self.allocator, "[\"CLOSED\",\"{s}\",\"{s}\"]", .{ sub_id, message }) catch return error.OutOfMemory;
        defer self.allocator.free(msg);
        try self.sendFrame(.text, msg);
    }

    /// Send a WebSocket close frame (code 1000) and then close the TCP stream.
    pub fn closeFrame(self: *MockRelay) Error!void {
        const close_payload: [2]u8 = .{ 0x03, 0xE8 };
        try self.sendFrame(.close, &close_payload);
        if (self.stream) |s| {
            s.close();
            self.stream = null;
        }
    }

    /// Force-close the TCP stream without a close frame. Used to simulate a
    /// relay that hangs up bluntly (which `subscribeWithReconnect` should
    /// recover from).
    pub fn forceClose(self: *MockRelay) void {
        if (self.stream) |s| {
            s.close();
            self.stream = null;
        }
    }

    /// Receive one text-frame message from the client (REQ, EVENT, CLOSE).
    /// Caller owns the returned slice.
    pub fn recvText(self: *MockRelay) Error![]u8 {
        const frame = try self.recvFrame();
        return frame.payload;
    }

    // -----------------------------------------------------------------------
    // Internals: handshake + frame I/O
    // -----------------------------------------------------------------------

    fn performHandshake(self: *MockRelay) Error!void {
        const stream = self.stream orelse return error.HandshakeFailed;

        // Read request headers until CRLFCRLF, one byte at a time so we don't
        // over-read into the first frame.
        var hdr_buf: [4096]u8 = undefined;
        var hdr_len: usize = 0;
        while (hdr_len < hdr_buf.len) {
            const n = posix.recv(stream.handle, hdr_buf[hdr_len..][0..1], 0) catch return error.RecvFailed;
            if (n == 0) return error.HandshakeFailed;
            hdr_len += n;
            if (hdr_len >= 4 and std.mem.eql(u8, hdr_buf[hdr_len - 4 .. hdr_len], "\r\n\r\n")) break;
        }
        const headers = hdr_buf[0..hdr_len];

        // Find the Sec-WebSocket-Key header (case-insensitive name match).
        const key = findHeader(headers, "Sec-WebSocket-Key") orelse {
            log.warn("mock relay: client sent no Sec-WebSocket-Key", .{});
            return error.HandshakeFailed;
        };

        // Build the server's 101 response using the shared helper.
        const accept_b64 = ws.expectedAccept(key);
        var resp_buf: [256]u8 = undefined;
        const resp = std.fmt.bufPrint(
            &resp_buf,
            "HTTP/1.1 101 Switching Protocols\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Accept: {s}\r\n" ++
                "\r\n",
            .{accept_b64},
        ) catch return error.HandshakeFailed;

        try self.writeAll(resp);
    }

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

    fn sendFrame(self: *MockRelay, opcode: ws.Opcode, payload: []const u8) Error!void {
        var header: [10]u8 = undefined;
        var hlen: usize = 0;
        // FIN=1, opcode in low nibble. @intFromEnum on a u4 gives u4, so we
        // widen to u8 before OR-ing with the FIN bit (0x80).
        header[hlen] = 0x80 | @as(u8, @intFromEnum(opcode));
        hlen += 1;
        // No MASK bit; server frames are unmasked.
        if (payload.len < 126) {
            header[hlen] = @intCast(payload.len);
            hlen += 1;
        } else if (payload.len < 65536) {
            header[hlen] = 126;
            hlen += 1;
            std.mem.writeInt(u16, header[hlen..][0..2], @intCast(payload.len), .big);
            hlen += 2;
        } else {
            header[hlen] = 127;
            hlen += 1;
            std.mem.writeInt(u64, header[hlen..][0..8], payload.len, .big);
            hlen += 8;
        }
        try self.writeAll(header[0..hlen]);
        if (payload.len > 0) try self.writeAll(payload);
    }

    const FrameMeta = struct {
        fin: bool,
        opcode: ws.Opcode,
        payload: []u8, // owned by allocator
    };

    fn recvFrame(self: *MockRelay) Error!FrameMeta {
        var header: [2]u8 = undefined;
        try self.readExact(&header);

        const fin = (header[0] & 0x80) != 0;
        const opcode_raw = header[0] & 0x0F;
        const opcode: ws.Opcode = std.meta.intToEnum(ws.Opcode, opcode_raw) catch return error.RecvFailed;
        const masked = (header[1] & 0x80) != 0;
        // Per RFC 6455 §5.1, frames from the client MUST be masked.
        if (!masked) return error.RecvFailed;

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

        var mask: [4]u8 = undefined;
        try self.readExact(&mask);

        const buf = self.allocator.alloc(u8, @intCast(payload_len)) catch return error.OutOfMemory;
        errdefer self.allocator.free(buf);
        if (payload_len > 0) try self.readExact(buf);
        for (buf, 0..) |*b, i| b.* ^= mask[i % 4];

        return .{ .fin = fin, .opcode = opcode, .payload = buf };
    }

    fn writeAll(self: *MockRelay, buf: []const u8) Error!void {
        const stream = self.stream orelse return error.Closed;
        var off: usize = 0;
        while (off < buf.len) {
            const n = posix.send(stream.handle, buf[off..], 0) catch return error.SendFailed;
            if (n == 0) return error.Closed;
            off += n;
        }
    }

    fn readExact(self: *MockRelay, buf: []u8) Error!void {
        const stream = self.stream orelse return error.Closed;
        var off: usize = 0;
        while (off < buf.len) {
            const n = posix.recv(stream.handle, buf[off..], 0) catch return error.RecvFailed;
            if (n == 0) return error.Closed;
            off += n;
        }
    }
};

// ===========================================================================
// Tests
// ===========================================================================
// The handshake + frame round-trip is exercised through a real `ws.Conn`
// client against the mock here. This is the only place where both sides of
// the WS protocol meet in-process.

test "mock relay handshake and text frame round trip via ws.Conn client" {
    const allocator = std.testing.allocator;

    var mock = try MockRelay.start(allocator);
    defer mock.deinit();

    const url = try mock.urlAlloc(allocator);
    defer allocator.free(url);

    // Server side runs in a thread: accept + handshake, then send "hello" and
    // wait for the client's REQ-style frame.
    const Server = struct {
        fn run(m: *MockRelay) void {
            m.accept() catch return;
            m.sendNotice("hello") catch return;
            const msg = m.recvText() catch return;
            m.allocator.free(msg);
            m.closeFrame() catch return;
        }
    };
    var handle = try std.Thread.spawn(.{}, Server.run, .{&mock});
    defer handle.join();

    var conn = try ws.Conn.connect(allocator, url);
    defer conn.deinit();

    // Client reads "hello" as a NOTICE wrapped in JSON.
    const got = try conn.readMessage();
    defer allocator.free(got.payload);
    try std.testing.expectEqualStrings("[\"NOTICE\",\"hello\"]", got.payload);

    // Client sends a REQ-style frame back; the server reads it.
    try conn.writeText("[\"REQ\",\"sub1\",{\"kinds\":[1]}]");
}

test "mock relay rejects unmasked client frame" {
    // The frame decoder in MockRelay should treat an unmasked incoming frame
    // as a protocol violation (server side requires masked client frames per
    // RFC 6455 §5.1). The real ws.Conn client always masks, so this is
    // primarily a defense against a buggy peer.
    const allocator = std.testing.allocator;

    var mock = try MockRelay.start(allocator);
    defer mock.deinit();

    const url = try mock.urlAlloc(allocator);
    defer allocator.free(url);

    // Spawn the mock server thread.
    const Server = struct {
        result: ?anyerror = null,
        fn run(m: *MockRelay, out: *@This()) void {
            m.accept() catch |err| {
                out.result = err;
                return;
            };
            const msg = m.recvText() catch |err| {
                out.result = err;
                return;
            };
            m.allocator.free(msg);
        }
    };
    var state: Server = .{};
    var handle = try std.Thread.spawn(.{}, Server.run, .{ &mock, &state });

    // Client side: connect and send an unmasked frame directly via the
    // socket, bypassing ws.Conn. The mock should reject it.
    const conn_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, mock.port);
    const stream = try std.net.tcpConnectToAddress(conn_addr);
    defer stream.close();

    // Minimal handshake from the client to set up the WS layer.
    const req =
        "GET / HTTP/1.1\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n";
    _ = try posix.send(stream.handle, req, 0);

    // Drain the server's 101 response.
    var resp_buf: [256]u8 = undefined;
    _ = try posix.recv(stream.handle, &resp_buf, 0);

    // Send an unmasked text frame: FIN=1, opcode=text, len=2, payload="hi"
    const bad: [4]u8 = .{ 0x81, 0x02, 'h', 'i' };
    _ = try posix.send(stream.handle, &bad, 0);

    handle.join();
    try std.testing.expectEqual(@as(?anyerror, error.RecvFailed), state.result);
}
