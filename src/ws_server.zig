//! Server-side WebSocket (RFC 6455) for the daemon.
//!
//! `ws.zig` is a client (it masks outbound frames and rejects masked inbound
//! frames), so the daemon needs the mirror image: compute the server handshake
//! accept key, decode masked client frames, and emit unmasked server frames.
//! Only the subset the GUI channel needs is implemented — text/close/ping/pong,
//! single (unfragmented) frames up to a bounded size.
//!
//! The pure helpers (`acceptKey`, `encodeFrame`, `decodeFrame`) are unit-tested
//! against the RFC 6455 examples; the stream helpers wrap them with blocking
//! `posix.recv`/`posix.send` on `stream.handle`, matching `ws.zig`.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

/// Per RFC 6455 §1.3 — appended to the client key before hashing.
const ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Reject payloads larger than this when reading client frames. The GUI only
/// sends tiny control messages, so anything large is malformed or hostile.
pub const max_payload: usize = 1 << 20; // 1 MiB

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,
};

pub const Error = error{
    Closed,
    SendFailed,
    RecvFailed,
    /// Client frame was not masked (RFC 6455 requires client→server masking).
    NotMasked,
    PayloadTooLarge,
    Incomplete,
} || Allocator.Error;

/// A decoded WebSocket frame. `payload` is owned by the caller.
pub const Frame = struct {
    opcode: Opcode,
    fin: bool,
    payload: []u8,

    pub fn deinit(self: Frame, allocator: Allocator) void {
        allocator.free(self.payload);
    }
};

/// Compute the `Sec-WebSocket-Accept` value for a client key:
/// base64(sha1(key ++ GUID)). The result is always 28 bytes.
pub fn acceptKey(client_key: []const u8, out: *[28]u8) void {
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(client_key);
    hasher.update(ws_guid);
    var digest: [20]u8 = undefined;
    hasher.final(&digest);
    _ = std.base64.standard.Encoder.encode(out, &digest);
}

/// Encode an unmasked server frame for `payload`. Caller owns the result.
/// Server frames are never masked (RFC 6455 §5.1).
pub fn encodeFrame(allocator: Allocator, opcode: Opcode, payload: []const u8) Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const b0: u8 = 0x80 | @as(u8, @intFromEnum(opcode)); // FIN=1
    try buf.append(allocator, b0);

    if (payload.len < 126) {
        try buf.append(allocator, @intCast(payload.len));
    } else if (payload.len <= 0xFFFF) {
        try buf.append(allocator, 126);
        var len_be: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_be, @intCast(payload.len), .big);
        try buf.appendSlice(allocator, &len_be);
    } else {
        try buf.append(allocator, 127);
        var len_be: [8]u8 = undefined;
        std.mem.writeInt(u64, &len_be, payload.len, .big);
        try buf.appendSlice(allocator, &len_be);
    }

    try buf.appendSlice(allocator, payload);
    return buf.toOwnedSlice(allocator);
}

/// Result of decoding one frame from a buffer: the frame plus how many bytes
/// were consumed (so a caller streaming bytes can advance).
pub const Decoded = struct {
    frame: Frame,
    consumed: usize,
};

/// Decode a single (masked) client frame from `data`. Returns `Incomplete` if
/// `data` does not yet contain the whole frame. The payload is unmasked into a
/// freshly allocated buffer owned by the caller.
pub fn decodeFrame(allocator: Allocator, data: []const u8) Error!Decoded {
    if (data.len < 2) return error.Incomplete;
    const b0 = data[0];
    const b1 = data[1];
    const fin = (b0 & 0x80) != 0;
    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(b0 & 0x0F)));
    const masked = (b1 & 0x80) != 0;
    if (!masked) return error.NotMasked;

    var off: usize = 2;
    var payload_len: u64 = b1 & 0x7F;
    if (payload_len == 126) {
        if (data.len < off + 2) return error.Incomplete;
        payload_len = std.mem.readInt(u16, data[off..][0..2], .big);
        off += 2;
    } else if (payload_len == 127) {
        if (data.len < off + 8) return error.Incomplete;
        payload_len = std.mem.readInt(u64, data[off..][0..8], .big);
        off += 8;
    }
    if (payload_len > max_payload) return error.PayloadTooLarge;

    if (data.len < off + 4) return error.Incomplete;
    const mask = data[off..][0..4].*;
    off += 4;

    const plen: usize = @intCast(payload_len);
    if (data.len < off + plen) return error.Incomplete;

    const payload = try allocator.alloc(u8, plen);
    errdefer allocator.free(payload);
    for (data[off .. off + plen], 0..) |c, i| {
        payload[i] = c ^ mask[i % 4];
    }

    return .{
        .frame = .{ .opcode = opcode, .fin = fin, .payload = payload },
        .consumed = off + plen,
    };
}

// ---------------------------------------------------------------------------
// Stream helpers (blocking posix I/O on stream.handle, mirroring ws.zig)
// ---------------------------------------------------------------------------

fn sendAll(stream: std.net.Stream, buf: []const u8) Error!void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = posix.send(stream.handle, buf[off..], 0) catch return error.SendFailed;
        if (n == 0) return error.Closed;
        off += n;
    }
}

fn recvExact(stream: std.net.Stream, buf: []u8) Error!void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = posix.recv(stream.handle, buf[off..], 0) catch return error.RecvFailed;
        if (n == 0) return error.Closed;
        off += n;
    }
}

/// Send a text frame over `stream`.
pub fn sendText(allocator: Allocator, stream: std.net.Stream, payload: []const u8) Error!void {
    const framed = try encodeFrame(allocator, .text, payload);
    defer allocator.free(framed);
    try sendAll(stream, framed);
}

/// Send a close frame (no status code). Best-effort.
pub fn sendClose(allocator: Allocator, stream: std.net.Stream) void {
    const framed = encodeFrame(allocator, .close, "") catch return;
    defer allocator.free(framed);
    sendAll(stream, framed) catch {};
}

/// Send a pong with the given payload (echoing a ping's body, per RFC 6455).
pub fn sendPong(allocator: Allocator, stream: std.net.Stream, payload: []const u8) Error!void {
    const framed = try encodeFrame(allocator, .pong, payload);
    defer allocator.free(framed);
    try sendAll(stream, framed);
}

/// Read one full client frame from `stream`, unmasking the payload. Reads the
/// 2-byte header, any extended length, the 4-byte mask, then the payload.
pub fn readFrame(allocator: Allocator, stream: std.net.Stream) Error!Frame {
    var hdr: [2]u8 = undefined;
    try recvExact(stream, &hdr);
    const fin = (hdr[0] & 0x80) != 0;
    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(hdr[0] & 0x0F)));
    const masked = (hdr[1] & 0x80) != 0;
    if (!masked) return error.NotMasked;

    var payload_len: u64 = hdr[1] & 0x7F;
    if (payload_len == 126) {
        var ext: [2]u8 = undefined;
        try recvExact(stream, &ext);
        payload_len = std.mem.readInt(u16, &ext, .big);
    } else if (payload_len == 127) {
        var ext: [8]u8 = undefined;
        try recvExact(stream, &ext);
        payload_len = std.mem.readInt(u64, &ext, .big);
    }
    if (payload_len > max_payload) return error.PayloadTooLarge;

    var mask: [4]u8 = undefined;
    try recvExact(stream, &mask);

    const plen: usize = @intCast(payload_len);
    const payload = try allocator.alloc(u8, plen);
    errdefer allocator.free(payload);
    if (plen > 0) {
        try recvExact(stream, payload);
        for (payload, 0..) |*c, i| c.* ^= mask[i % 4];
    }
    return .{ .opcode = opcode, .fin = fin, .payload = payload };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "acceptKey: RFC 6455 example" {
    // RFC 6455 §1.3: key "dGhlIHNhbXBsZSBub25jZQ==" → accept
    // "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    var out: [28]u8 = undefined;
    acceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &out);
}

test "encodeFrame: small text frame, FIN set, unmasked" {
    const allocator = testing.allocator;
    const f = try encodeFrame(allocator, .text, "hi");
    defer allocator.free(f);
    // 0x81 = FIN + text; 0x02 = len 2 (mask bit clear); then payload.
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x02, 'h', 'i' }, f);
}

test "encodeFrame: 16-bit extended length" {
    const allocator = testing.allocator;
    const payload = try allocator.alloc(u8, 300);
    defer allocator.free(payload);
    @memset(payload, 'a');
    const f = try encodeFrame(allocator, .text, payload);
    defer allocator.free(f);
    try testing.expectEqual(@as(u8, 0x81), f[0]);
    try testing.expectEqual(@as(u8, 126), f[1]);
    try testing.expectEqual(@as(u16, 300), std.mem.readInt(u16, f[2..4], .big));
    try testing.expectEqual(@as(usize, 4 + 300), f.len);
}

test "decodeFrame: unmasks a client text frame" {
    const allocator = testing.allocator;
    // FIN+text, masked, len 5, mask 0x37fa213d, masked "Hello" per RFC 6455 §5.7
    const data = [_]u8{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 };
    const d = try decodeFrame(allocator, &data);
    defer d.frame.deinit(allocator);
    try testing.expectEqual(Opcode.text, d.frame.opcode);
    try testing.expect(d.frame.fin);
    try testing.expectEqualStrings("Hello", d.frame.payload);
    try testing.expectEqual(@as(usize, data.len), d.consumed);
}

test "decodeFrame: rejects unmasked client frame" {
    const allocator = testing.allocator;
    const data = [_]u8{ 0x81, 0x02, 'h', 'i' }; // mask bit clear
    try testing.expectError(error.NotMasked, decodeFrame(allocator, &data));
}

test "decodeFrame: Incomplete when header truncated" {
    const allocator = testing.allocator;
    try testing.expectError(error.Incomplete, decodeFrame(allocator, &[_]u8{0x81}));
    // header says masked len 5 but payload missing
    const partial = [_]u8{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f };
    try testing.expectError(error.Incomplete, decodeFrame(allocator, &partial));
}

test "encode then decode round-trips a masked echo" {
    const allocator = testing.allocator;
    // Build a server frame, then hand-mask it as if it were a client frame and
    // decode it back, exercising the unmask path for a close opcode.
    const server = try encodeFrame(allocator, .text, "ping me");
    defer allocator.free(server);
    // Re-frame as masked: header byte stays, set mask bit, append mask + xor.
    var masked: std.ArrayList(u8) = .empty;
    defer masked.deinit(allocator);
    try masked.append(allocator, server[0]);
    try masked.append(allocator, 0x80 | @as(u8, @intCast("ping me".len)));
    const mask = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    try masked.appendSlice(allocator, &mask);
    for ("ping me", 0..) |c, i| try masked.append(allocator, c ^ mask[i % 4]);

    const d = try decodeFrame(allocator, masked.items);
    defer d.frame.deinit(allocator);
    try testing.expectEqualStrings("ping me", d.frame.payload);
}
