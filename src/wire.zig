/// BitTorrent peer wire protocol (BEP 3).
///
/// The protocol operates over TCP. After a handshake, peers exchange
/// length-prefixed messages. Each message starts with a 4-byte big-endian
/// length, followed by a message ID byte, followed by the payload.
/// Keep-alive messages have length 0 and no ID or payload.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Protocol string used in the handshake.
pub const protocol_string = "BitTorrent protocol";

/// Size of the handshake: 1 (pstrlen) + 19 (pstr) + 8 (reserved) + 20 (info_hash) + 20 (peer_id)
pub const handshake_len: usize = 68;

/// A BitTorrent handshake.
pub const Handshake = struct {
    reserved: [8]u8,
    info_hash: [20]u8,
    peer_id: [20]u8,

    /// Serialize the handshake into a 68-byte buffer.
    pub fn serialize(self: Handshake) [handshake_len]u8 {
        var buf: [handshake_len]u8 = undefined;
        buf[0] = 19; // pstrlen
        @memcpy(buf[1..20], protocol_string);
        @memcpy(buf[20..28], &self.reserved);
        @memcpy(buf[28..48], &self.info_hash);
        @memcpy(buf[48..68], &self.peer_id);
        return buf;
    }

    /// Parse a handshake from a 68-byte buffer.
    pub fn parse(buf: *const [handshake_len]u8) ParseError!Handshake {
        if (buf[0] != 19) return error.InvalidProtocol;
        if (!std.mem.eql(u8, buf[1..20], protocol_string)) return error.InvalidProtocol;

        return .{
            .reserved = buf[20..28].*,
            .info_hash = buf[28..48].*,
            .peer_id = buf[48..68].*,
        };
    }
};

/// Message ID byte values per BEP 3.
pub const MessageId = enum(u8) {
    choke = 0,
    unchoke = 1,
    interested = 2,
    not_interested = 3,
    have = 4,
    bitfield = 5,
    request = 6,
    piece = 7,
    cancel = 8,

    pub fn fromByte(b: u8) ParseError!MessageId {
        return std.meta.intToEnum(MessageId, b) catch return error.UnknownMessageId;
    }
};

/// A parsed peer wire message.
pub const Message = union(enum) {
    keep_alive,
    choke,
    unchoke,
    interested,
    not_interested,
    have: u32,
    bitfield: []const u8,
    request: BlockRequest,
    piece: PieceData,
    cancel: BlockRequest,

    pub const BlockRequest = struct {
        index: u32,
        begin: u32,
        length: u32,
    };

    pub const PieceData = struct {
        index: u32,
        begin: u32,
        block: []const u8,
    };

    /// Free heap-allocated data owned by this message. Only call this on
    /// messages returned by `parseMessage`, which allocates bitfield and
    /// piece block data. Do NOT call on caller-constructed messages passed
    /// to `serializeMessage` -- those borrow their data.
    pub fn deinit(self: Message, allocator: Allocator) void {
        switch (self) {
            .bitfield => |data| allocator.free(data),
            .piece => |pd| allocator.free(pd.block),
            else => {},
        }
    }
};

/// Maximum wire message length (2MB). Generous upper bound -- typical
/// piece blocks are 16KB. Prevents memory exhaustion from malicious peers.
pub const max_message_len: u32 = 1 << 21;

pub const ParseError = error{
    InvalidProtocol,
    InvalidLength,
    UnknownMessageId,
    MessageTooLarge,
    OutOfMemory,
};

/// Serialize a message into its wire format (4-byte length prefix + id + payload).
/// Caller owns the returned slice.
pub fn serializeMessage(allocator: Allocator, msg: Message) error{OutOfMemory}![]u8 {
    switch (msg) {
        .keep_alive => {
            const buf = allocator.alloc(u8, 4) catch return error.OutOfMemory;
            @memcpy(buf[0..4], &[4]u8{ 0, 0, 0, 0 });
            return buf;
        },
        .choke => return serializeSimple(allocator, .choke),
        .unchoke => return serializeSimple(allocator, .unchoke),
        .interested => return serializeSimple(allocator, .interested),
        .not_interested => return serializeSimple(allocator, .not_interested),
        .have => |index| {
            const buf = allocator.alloc(u8, 9) catch return error.OutOfMemory;
            std.mem.writeInt(u32, buf[0..4], 5, .big); // length = 1 + 4
            buf[4] = @intFromEnum(MessageId.have);
            std.mem.writeInt(u32, buf[5..9], index, .big);
            return buf;
        },
        .bitfield => |data| {
            const total: u32 = std.math.cast(u32, 1 + data.len) orelse return error.OutOfMemory;
            const buf = allocator.alloc(u8, 4 + 1 + data.len) catch return error.OutOfMemory;
            std.mem.writeInt(u32, buf[0..4], total, .big);
            buf[4] = @intFromEnum(MessageId.bitfield);
            @memcpy(buf[5..][0..data.len], data);
            return buf;
        },
        .request => |br| return serializeBlockRequest(allocator, .request, br),
        .cancel => |br| return serializeBlockRequest(allocator, .cancel, br),
        .piece => |pd| {
            const payload_len: u32 = std.math.cast(u32, 1 + 4 + 4 + pd.block.len) orelse return error.OutOfMemory;
            const buf = allocator.alloc(u8, 4 + 1 + 4 + 4 + pd.block.len) catch return error.OutOfMemory;
            std.mem.writeInt(u32, buf[0..4], payload_len, .big);
            buf[4] = @intFromEnum(MessageId.piece);
            std.mem.writeInt(u32, buf[5..9], pd.index, .big);
            std.mem.writeInt(u32, buf[9..13], pd.begin, .big);
            @memcpy(buf[13..][0..pd.block.len], pd.block);
            return buf;
        },
    }
}

/// Parse a single message from a byte buffer. Returns the parsed message
/// and the number of bytes consumed. If the buffer doesn't contain a
/// complete message, returns null.
pub fn parseMessage(allocator: Allocator, buf: []const u8) ParseError!?struct { msg: Message, consumed: usize } {
    if (buf.len < 4) return null; // need at least length prefix

    const length = std.mem.readInt(u32, buf[0..4], .big);

    // Keep-alive
    if (length == 0) return .{ .msg = .keep_alive, .consumed = 4 };

    // Reject oversized messages before buffering
    if (length > max_message_len) return error.MessageTooLarge;

    const total = 4 + @as(usize, length);
    if (buf.len < total) return null; // incomplete message

    const id = MessageId.fromByte(buf[4]) catch return error.UnknownMessageId;
    const payload = buf[5..total];

    const msg: Message = switch (id) {
        .choke => blk: {
            if (payload.len != 0) return error.InvalidLength;
            break :blk .choke;
        },
        .unchoke => blk: {
            if (payload.len != 0) return error.InvalidLength;
            break :blk .unchoke;
        },
        .interested => blk: {
            if (payload.len != 0) return error.InvalidLength;
            break :blk .interested;
        },
        .not_interested => blk: {
            if (payload.len != 0) return error.InvalidLength;
            break :blk .not_interested;
        },
        .have => blk: {
            if (payload.len != 4) return error.InvalidLength;
            break :blk .{ .have = std.mem.readInt(u32, payload[0..4], .big) };
        },
        .bitfield => blk: {
            const data = allocator.alloc(u8, payload.len) catch return error.OutOfMemory;
            @memcpy(data, payload);
            break :blk .{ .bitfield = data };
        },
        .request => blk: {
            if (payload.len != 12) return error.InvalidLength;
            break :blk .{ .request = parseBlockRequest(payload) };
        },
        .piece => blk: {
            if (payload.len < 8) return error.InvalidLength;
            const block_data = allocator.alloc(u8, payload.len - 8) catch return error.OutOfMemory;
            @memcpy(block_data, payload[8..]);
            break :blk .{ .piece = .{
                .index = std.mem.readInt(u32, payload[0..4], .big),
                .begin = std.mem.readInt(u32, payload[4..8], .big),
                .block = block_data,
            } };
        },
        .cancel => blk: {
            if (payload.len != 12) return error.InvalidLength;
            break :blk .{ .cancel = parseBlockRequest(payload) };
        },
    };

    return .{ .msg = msg, .consumed = total };
}

// --- Internal helpers ---

fn serializeSimple(allocator: Allocator, id: MessageId) error{OutOfMemory}![]u8 {
    const buf = allocator.alloc(u8, 5) catch return error.OutOfMemory;
    std.mem.writeInt(u32, buf[0..4], 1, .big); // length = 1
    buf[4] = @intFromEnum(id);
    return buf;
}

fn serializeBlockRequest(allocator: Allocator, id: MessageId, br: Message.BlockRequest) error{OutOfMemory}![]u8 {
    const buf = allocator.alloc(u8, 17) catch return error.OutOfMemory;
    std.mem.writeInt(u32, buf[0..4], 13, .big); // length = 1 + 4 + 4 + 4
    buf[4] = @intFromEnum(id);
    std.mem.writeInt(u32, buf[5..9], br.index, .big);
    std.mem.writeInt(u32, buf[9..13], br.begin, .big);
    std.mem.writeInt(u32, buf[13..17], br.length, .big);
    return buf;
}

fn parseBlockRequest(payload: []const u8) Message.BlockRequest {
    return .{
        .index = std.mem.readInt(u32, payload[0..4], .big),
        .begin = std.mem.readInt(u32, payload[4..8], .big),
        .length = std.mem.readInt(u32, payload[8..12], .big),
    };
}

// --- Tests ---

test "handshake roundtrip" {
    const hs = Handshake{
        .reserved = [_]u8{0} ** 8,
        .info_hash = [_]u8{0xAB} ** 20,
        .peer_id = [_]u8{0xCD} ** 20,
    };

    const buf = hs.serialize();
    try std.testing.expectEqual(@as(u8, 19), buf[0]);
    try std.testing.expectEqualStrings(protocol_string, buf[1..20]);

    const parsed = try Handshake.parse(&buf);
    try std.testing.expectEqual(hs.reserved, parsed.reserved);
    try std.testing.expectEqual(hs.info_hash, parsed.info_hash);
    try std.testing.expectEqual(hs.peer_id, parsed.peer_id);
}

test "handshake reject invalid protocol" {
    var buf = (Handshake{
        .reserved = [_]u8{0} ** 8,
        .info_hash = [_]u8{0} ** 20,
        .peer_id = [_]u8{0} ** 20,
    }).serialize();
    buf[0] = 20; // wrong pstrlen
    try std.testing.expectError(error.InvalidProtocol, Handshake.parse(&buf));
}

test "keep-alive roundtrip" {
    const allocator = std.testing.allocator;

    const wire = try serializeMessage(allocator, .keep_alive);
    defer allocator.free(wire);

    try std.testing.expectEqual(@as(usize, 4), wire.len);
    try std.testing.expectEqualSlices(u8, &[4]u8{ 0, 0, 0, 0 }, wire);

    const result = (try parseMessage(allocator, wire)).?;
    defer result.msg.deinit(allocator);
    try std.testing.expectEqual(Message.keep_alive, result.msg);
    try std.testing.expectEqual(@as(usize, 4), result.consumed);
}

test "choke roundtrip" {
    const allocator = std.testing.allocator;

    const wire = try serializeMessage(allocator, .choke);
    defer allocator.free(wire);

    try std.testing.expectEqual(@as(usize, 5), wire.len);

    const result = (try parseMessage(allocator, wire)).?;
    defer result.msg.deinit(allocator);
    try std.testing.expectEqual(Message.choke, result.msg);
}

test "unchoke roundtrip" {
    const allocator = std.testing.allocator;

    const wire = try serializeMessage(allocator, .unchoke);
    defer allocator.free(wire);

    const result = (try parseMessage(allocator, wire)).?;
    defer result.msg.deinit(allocator);
    try std.testing.expectEqual(Message.unchoke, result.msg);
}

test "interested roundtrip" {
    const allocator = std.testing.allocator;

    const wire = try serializeMessage(allocator, .interested);
    defer allocator.free(wire);

    const result = (try parseMessage(allocator, wire)).?;
    defer result.msg.deinit(allocator);
    try std.testing.expectEqual(Message.interested, result.msg);
}

test "not_interested roundtrip" {
    const allocator = std.testing.allocator;

    const wire = try serializeMessage(allocator, .not_interested);
    defer allocator.free(wire);

    const result = (try parseMessage(allocator, wire)).?;
    defer result.msg.deinit(allocator);
    try std.testing.expectEqual(Message.not_interested, result.msg);
}

test "have roundtrip" {
    const allocator = std.testing.allocator;

    const wire = try serializeMessage(allocator, .{ .have = 42 });
    defer allocator.free(wire);

    try std.testing.expectEqual(@as(usize, 9), wire.len);

    const result = (try parseMessage(allocator, wire)).?;
    defer result.msg.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 42), result.msg.have);
}

test "bitfield roundtrip" {
    const allocator = std.testing.allocator;

    const bf = [_]u8{ 0xFF, 0x0F, 0x00 };
    const wire = try serializeMessage(allocator, .{ .bitfield = &bf });
    defer allocator.free(wire);

    const result = (try parseMessage(allocator, wire)).?;
    defer result.msg.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &bf, result.msg.bitfield);
}

test "request roundtrip" {
    const allocator = std.testing.allocator;

    const br = Message.BlockRequest{ .index = 1, .begin = 16384, .length = 16384 };
    const wire = try serializeMessage(allocator, .{ .request = br });
    defer allocator.free(wire);

    try std.testing.expectEqual(@as(usize, 17), wire.len);

    const result = (try parseMessage(allocator, wire)).?;
    defer result.msg.deinit(allocator);
    try std.testing.expectEqual(br, result.msg.request);
}

test "piece roundtrip" {
    const allocator = std.testing.allocator;

    const block = [_]u8{ 1, 2, 3, 4, 5 };
    const wire = try serializeMessage(allocator, .{ .piece = .{
        .index = 7,
        .begin = 0,
        .block = &block,
    } });
    defer allocator.free(wire);

    const result = (try parseMessage(allocator, wire)).?;
    defer result.msg.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 7), result.msg.piece.index);
    try std.testing.expectEqual(@as(u32, 0), result.msg.piece.begin);
    try std.testing.expectEqualSlices(u8, &block, result.msg.piece.block);
}

test "cancel roundtrip" {
    const allocator = std.testing.allocator;

    const br = Message.BlockRequest{ .index = 3, .begin = 0, .length = 32768 };
    const wire = try serializeMessage(allocator, .{ .cancel = br });
    defer allocator.free(wire);

    const result = (try parseMessage(allocator, wire)).?;
    defer result.msg.deinit(allocator);
    try std.testing.expectEqual(br, result.msg.cancel);
}

test "incomplete buffer returns null" {
    const allocator = std.testing.allocator;

    // Only 3 bytes -- not even a full length prefix
    try std.testing.expect(try parseMessage(allocator, &[_]u8{ 0, 0, 0 }) == null);

    // Length says 5 bytes but only 2 available after prefix
    try std.testing.expect(try parseMessage(allocator, &[_]u8{ 0, 0, 0, 5, 0, 0 }) == null);
}

test "unknown message ID" {
    const allocator = std.testing.allocator;

    // Length 1, id 99
    const buf = [_]u8{ 0, 0, 0, 1, 99 };
    try std.testing.expectError(error.UnknownMessageId, parseMessage(allocator, &buf));
}

test "have with wrong payload length" {
    const allocator = std.testing.allocator;

    // have should have 4-byte payload but we send 3
    const buf = [_]u8{ 0, 0, 0, 4, @intFromEnum(MessageId.have), 0, 0, 0 };
    try std.testing.expectError(error.InvalidLength, parseMessage(allocator, &buf));
}

test "request with wrong payload length" {
    const allocator = std.testing.allocator;

    // request should have 12-byte payload but we send 8
    var buf: [13]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 9, .big);
    buf[4] = @intFromEnum(MessageId.request);
    @memset(buf[5..13], 0);
    try std.testing.expectError(error.InvalidLength, parseMessage(allocator, &buf));
}

test "parse multiple messages from stream" {
    const allocator = std.testing.allocator;

    // Concatenate: keep_alive + choke + have(10)
    const ka = try serializeMessage(allocator, .keep_alive);
    defer allocator.free(ka);
    const choke = try serializeMessage(allocator, .choke);
    defer allocator.free(choke);
    const have = try serializeMessage(allocator, .{ .have = 10 });
    defer allocator.free(have);

    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(allocator);
    try stream.appendSlice(allocator, ka);
    try stream.appendSlice(allocator, choke);
    try stream.appendSlice(allocator, have);

    var pos: usize = 0;

    // Message 1: keep_alive
    const r1 = (try parseMessage(allocator, stream.items[pos..])).?;
    defer r1.msg.deinit(allocator);
    try std.testing.expectEqual(Message.keep_alive, r1.msg);
    pos += r1.consumed;

    // Message 2: choke
    const r2 = (try parseMessage(allocator, stream.items[pos..])).?;
    defer r2.msg.deinit(allocator);
    try std.testing.expectEqual(Message.choke, r2.msg);
    pos += r2.consumed;

    // Message 3: have(10)
    const r3 = (try parseMessage(allocator, stream.items[pos..])).?;
    defer r3.msg.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 10), r3.msg.have);
    pos += r3.consumed;

    try std.testing.expectEqual(stream.items.len, pos);
}
