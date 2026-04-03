/// BEP 10 Extension Protocol + BEP 9 Metadata Exchange.
///
/// BEP 10: Adds message ID 20 for extension messages. After the standard
/// handshake, peers exchange bencoded extension handshakes to negotiate
/// supported extensions and their local message IDs.
///
/// BEP 9: ut_metadata extension for downloading torrent metadata from
/// peers, enabling magnet link support.
const std = @import("std");
const Allocator = std.mem.Allocator;
const bencode = @import("bencode.zig");

const log = std.log.scoped(.extension);

/// Reserved byte bit for BEP 10 support: byte 5, bit 4.
pub const extension_bit_byte: usize = 5;
pub const extension_bit_mask: u8 = 0x10;

/// Wire message ID for extension protocol.
pub const extension_msg_id: u8 = 20;

/// Extension handshake ID (always 0 within message ID 20).
pub const handshake_ext_id: u8 = 0;

/// Metadata piece size per BEP 9.
pub const metadata_piece_size: usize = 16384;

/// Parsed extension handshake from a peer.
pub const ExtensionHandshake = struct {
    ut_metadata_id: ?u8,
    metadata_size: ?u32,
    client_name: ?[]const u8,
    listen_port: ?u16,

    pub fn deinit(self: ExtensionHandshake, allocator: Allocator) void {
        if (self.client_name) |n| allocator.free(n);
    }
};

/// ut_metadata message types per BEP 9.
pub const MetadataMsgType = enum(u8) {
    request = 0,
    data = 1,
    reject = 2,
};

/// A parsed ut_metadata message.
pub const MetadataMsg = struct {
    msg_type: MetadataMsgType,
    piece: u32,
    total_size: ?u32, // only present in data messages
    data: ?[]const u8, // only present in data messages

    pub fn deinit(self: MetadataMsg, allocator: Allocator) void {
        if (self.data) |d| allocator.free(d);
    }
};

/// Check if a peer's reserved bytes indicate BEP 10 support.
pub fn supportsExtensions(reserved: [8]u8) bool {
    return (reserved[extension_bit_byte] & extension_bit_mask) != 0;
}

/// Set the BEP 10 support bit in reserved bytes.
pub fn setExtensionBit(reserved: *[8]u8) void {
    reserved[extension_bit_byte] |= extension_bit_mask;
}

/// Build our extension handshake payload (bencoded).
/// Returns the full message bytes: [ext_id=0][bencoded_dict].
pub fn buildExtensionHandshake(
    allocator: Allocator,
    metadata_size: ?u32,
    listen_port: u16,
) error{OutOfMemory}![]u8 {
    // Build the "m" dict mapping extension names to our IDs
    var m_entries: [1]bencode.Value.DictEntry = undefined;
    m_entries[0] = .{ .key = "ut_metadata", .value = .{ .integer = 1 } };
    const m_dict = bencode.Value{ .dict = &m_entries };

    // Build top-level dict
    // Keys must be sorted: "m", "metadata_size", "p", "v"
    var entries_buf: [4]bencode.Value.DictEntry = undefined;
    var entry_count: usize = 0;

    entries_buf[entry_count] = .{ .key = "m", .value = m_dict };
    entry_count += 1;

    if (metadata_size) |ms| {
        entries_buf[entry_count] = .{ .key = "metadata_size", .value = .{ .integer = @intCast(ms) } };
        entry_count += 1;
    }

    entries_buf[entry_count] = .{ .key = "p", .value = .{ .integer = listen_port } };
    entry_count += 1;

    entries_buf[entry_count] = .{ .key = "v", .value = .{ .string = "Carl/0.1" } };
    entry_count += 1;

    const top_dict = bencode.Value{ .dict = entries_buf[0..entry_count] };
    const encoded = bencode.encode(allocator, top_dict) catch return error.OutOfMemory;
    errdefer allocator.free(encoded);

    // Prepend extension ID 0
    const msg = allocator.alloc(u8, 1 + encoded.len) catch {
        allocator.free(encoded);
        return error.OutOfMemory;
    };
    msg[0] = handshake_ext_id;
    @memcpy(msg[1..], encoded);
    allocator.free(encoded);

    return msg;
}

/// Parse a peer's extension handshake from the payload after msg ID 20.
pub fn parseExtensionHandshake(
    allocator: Allocator,
    payload: []const u8,
) error{ InvalidMessage, OutOfMemory }!ExtensionHandshake {
    if (payload.len < 1) return error.InvalidMessage;
    if (payload[0] != handshake_ext_id) return error.InvalidMessage;

    const dict_bytes = payload[1..];
    const root = bencode.decode(allocator, dict_bytes) catch return error.InvalidMessage;
    defer root.deinit(allocator);

    var result = ExtensionHandshake{
        .ut_metadata_id = null,
        .metadata_size = null,
        .client_name = null,
        .listen_port = null,
    };

    // Parse "m" dict for extension IDs
    if (root.dictGet("m")) |m_val| {
        if (m_val.dictGet("ut_metadata")) |id_val| {
            if (id_val.asInt()) |id| {
                result.ut_metadata_id = std.math.cast(u8, id);
            }
        }
    }

    if (root.dictGet("metadata_size")) |ms_val| {
        if (ms_val.asInt()) |ms| {
            result.metadata_size = std.math.cast(u32, ms);
        }
    }

    if (root.dictGet("v")) |v_val| {
        if (v_val.asString()) |s| {
            result.client_name = allocator.dupe(u8, s) catch return error.OutOfMemory;
        }
    }

    if (root.dictGet("p")) |p_val| {
        if (p_val.asInt()) |p| {
            result.listen_port = std.math.cast(u16, p);
        }
    }

    return result;
}

/// Build a ut_metadata request message.
/// Returns the payload after msg ID 20: [ext_id][bencoded_request].
pub fn buildMetadataRequest(
    allocator: Allocator,
    peer_ut_metadata_id: u8,
    piece_index: u32,
) error{OutOfMemory}![]u8 {
    var entries: [2]bencode.Value.DictEntry = undefined;
    entries[0] = .{ .key = "msg_type", .value = .{ .integer = @intFromEnum(MetadataMsgType.request) } };
    entries[1] = .{ .key = "piece", .value = .{ .integer = piece_index } };

    const dict = bencode.Value{ .dict = &entries };
    const encoded = bencode.encode(allocator, dict) catch return error.OutOfMemory;
    errdefer allocator.free(encoded);

    const msg = allocator.alloc(u8, 1 + encoded.len) catch {
        allocator.free(encoded);
        return error.OutOfMemory;
    };
    msg[0] = peer_ut_metadata_id;
    @memcpy(msg[1..], encoded);
    allocator.free(encoded);

    return msg;
}

/// Parse a ut_metadata message from the payload after msg ID 20.
/// The payload format is: [ext_id][bencoded_dict][optional_raw_data].
pub fn parseMetadataMessage(
    allocator: Allocator,
    payload: []const u8,
) error{ InvalidMessage, OutOfMemory }!MetadataMsg {
    if (payload.len < 2) return error.InvalidMessage;

    // Skip extension ID byte, parse bencoded dict
    const dict_start = payload[1..];

    // Find end of bencoded dict by parsing it
    var pos: usize = 0;
    const dict_val = decodeAt(allocator, dict_start, &pos) catch return error.InvalidMessage;
    defer dict_val.deinit(allocator);

    const msg_type_val = dict_val.dictGet("msg_type") orelse return error.InvalidMessage;
    const msg_type_int = std.math.cast(u8, msg_type_val.asInt() orelse return error.InvalidMessage) orelse return error.InvalidMessage;
    const msg_type: MetadataMsgType = std.meta.intToEnum(MetadataMsgType, msg_type_int) catch return error.InvalidMessage;

    const piece_val = dict_val.dictGet("piece") orelse return error.InvalidMessage;
    const piece = std.math.cast(u32, piece_val.asInt() orelse return error.InvalidMessage) orelse return error.InvalidMessage;

    var total_size: ?u32 = null;
    var data: ?[]const u8 = null;

    if (msg_type == .data) {
        if (dict_val.dictGet("total_size")) |ts_val| {
            total_size = std.math.cast(u32, ts_val.asInt() orelse return error.InvalidMessage);
        }
        // Raw data follows the bencoded dict
        if (pos < dict_start.len) {
            const raw_data = dict_start[pos..];
            const duped = allocator.dupe(u8, raw_data) catch return error.OutOfMemory;
            data = duped;
        }
    }

    return .{
        .msg_type = msg_type,
        .piece = piece,
        .total_size = total_size,
        .data = data,
    };
}

/// Internal: decode a bencode value at a position, advancing pos.
/// This is needed to find where the dict ends so we can extract trailing data.
fn decodeAt(allocator: Allocator, input: []const u8, pos: *usize) !bencode.Value {
    // Reuse bencode's internal decode logic by decoding the full input
    // and tracking how many bytes the dict consumed.
    // Simple approach: try decoding at input[pos..], which gives us the value.
    // We need to find the end position -- scan for matching 'e'.
    if (pos.* >= input.len) return error.UnexpectedEnd;

    // For a dict starting with 'd', find the matching 'e'
    if (input[pos.*] == 'd') {
        const start = pos.*;
        var depth: usize = 0;
        var i = pos.*;
        while (i < input.len) {
            switch (input[i]) {
                'd', 'l' => {
                    depth += 1;
                    i += 1;
                },
                'e' => {
                    depth -= 1;
                    i += 1;
                    if (depth == 0) break;
                },
                'i' => {
                    i += 1;
                    while (i < input.len and input[i] != 'e') : (i += 1) {}
                    if (i >= input.len) return error.InvalidMessage;
                    i += 1; // skip 'e'
                },
                '0'...'9' => {
                    const len_start = i;
                    while (i < input.len and input[i] >= '0' and input[i] <= '9') : (i += 1) {}
                    if (i >= input.len or input[i] != ':') return error.UnexpectedByte;
                    const slen = std.fmt.parseUnsigned(usize, input[len_start..i], 10) catch return error.InvalidStringLength;
                    i += 1 + slen;
                },
                else => return error.UnexpectedByte,
            }
        }
        pos.* = i;
        // Now decode the dict portion
        const dict_bytes = input[start..i];
        return bencode.decode(allocator, dict_bytes) catch return error.InvalidMessage;
    }

    return error.InvalidMessage;
}

/// Serialize a full extension message for the wire (length-prefixed).
/// Returns: [4-byte length][msg_id=20][payload].
pub fn serializeExtensionMessage(
    allocator: Allocator,
    ext_payload: []const u8,
) error{OutOfMemory}![]u8 {
    const total_len = 1 + ext_payload.len; // msg_id + payload
    const wire_len: u32 = std.math.cast(u32, total_len) orelse return error.OutOfMemory;

    const buf = allocator.alloc(u8, 4 + total_len) catch return error.OutOfMemory;
    std.mem.writeInt(u32, buf[0..4], wire_len, .big);
    buf[4] = extension_msg_id;
    @memcpy(buf[5..][0..ext_payload.len], ext_payload);

    return buf;
}

/// Tracks metadata download state for magnet links (BEP 9).
pub const MetadataDownload = struct {
    allocator: Allocator,
    info_hash: [20]u8,
    metadata_size: ?u32,
    num_pieces: u32,
    pieces: []?[]u8,
    received_count: u32,

    pub fn init(allocator: Allocator, info_hash: [20]u8) MetadataDownload {
        return .{
            .allocator = allocator,
            .info_hash = info_hash,
            .metadata_size = null,
            .num_pieces = 0,
            .pieces = &.{},
            .received_count = 0,
        };
    }

    /// Set the total metadata size (learned from peer's extension handshake).
    pub fn setSize(self: *MetadataDownload, size: u32) error{OutOfMemory}!void {
        if (self.metadata_size != null) return; // already set
        self.metadata_size = size;
        const mps: u32 = @intCast(metadata_piece_size);
        self.num_pieces = (size + mps - 1) / mps;
        const pieces = self.allocator.alloc(?[]u8, self.num_pieces) catch return error.OutOfMemory;
        @memset(pieces, null);
        self.pieces = pieces;
    }

    /// Record a received metadata piece. Returns true if all pieces received.
    pub fn addPiece(self: *MetadataDownload, piece_idx: u32, data: []const u8) error{OutOfMemory}!bool {
        if (piece_idx >= self.num_pieces) return false;
        if (self.pieces[piece_idx] != null) return false; // duplicate

        const duped = self.allocator.dupe(u8, data) catch return error.OutOfMemory;
        self.pieces[piece_idx] = duped;
        self.received_count += 1;

        return self.received_count == self.num_pieces;
    }

    /// Assemble all pieces and verify against info_hash.
    /// Returns the raw metadata bytes if valid, null if hash mismatch.
    pub fn assemble(self: *MetadataDownload) error{OutOfMemory}!?[]u8 {
        const size = self.metadata_size orelse return null;
        const buf = self.allocator.alloc(u8, size) catch return error.OutOfMemory;
        errdefer self.allocator.free(buf);

        var offset: usize = 0;
        for (self.pieces) |piece_opt| {
            const piece = piece_opt orelse return null;
            const end = @min(offset + piece.len, size);
            @memcpy(buf[offset..end], piece[0 .. end - offset]);
            offset = end;
        }

        // Verify SHA-1 against info_hash
        var hash: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(buf, &hash, .{});
        if (!std.mem.eql(u8, &hash, &self.info_hash)) {
            self.allocator.free(buf);
            return null;
        }

        return buf;
    }

    /// Get the next piece index we haven't received yet.
    pub fn nextMissing(self: MetadataDownload) ?u32 {
        for (self.pieces, 0..) |p, i| {
            if (p == null) return @intCast(i);
        }
        return null;
    }

    pub fn isComplete(self: MetadataDownload) bool {
        return self.metadata_size != null and self.received_count == self.num_pieces;
    }

    pub fn deinit(self: *MetadataDownload) void {
        for (self.pieces) |piece_opt| {
            if (piece_opt) |piece| self.allocator.free(piece);
        }
        if (self.pieces.len > 0) self.allocator.free(self.pieces);
    }
};

// --- Tests ---

test "extension bit set and check" {
    var reserved = [_]u8{0} ** 8;
    try std.testing.expect(!supportsExtensions(reserved));
    setExtensionBit(&reserved);
    try std.testing.expect(supportsExtensions(reserved));
    try std.testing.expectEqual(@as(u8, 0x10), reserved[5]);
}

test "build and parse extension handshake" {
    const allocator = std.testing.allocator;

    const payload = try buildExtensionHandshake(allocator, 12345, 6881);
    defer allocator.free(payload);

    try std.testing.expectEqual(@as(u8, 0), payload[0]); // ext_id = 0

    var hs = try parseExtensionHandshake(allocator, payload);
    defer hs.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), hs.ut_metadata_id.?);
    try std.testing.expectEqual(@as(u32, 12345), hs.metadata_size.?);
    try std.testing.expectEqual(@as(u16, 6881), hs.listen_port.?);
    try std.testing.expectEqualStrings("Carl/0.1", hs.client_name.?);
}

test "build metadata request" {
    const allocator = std.testing.allocator;

    const payload = try buildMetadataRequest(allocator, 2, 0);
    defer allocator.free(payload);

    try std.testing.expectEqual(@as(u8, 2), payload[0]); // peer's ut_metadata id
}

test "metadata download assembly and verification" {
    const allocator = std.testing.allocator;

    // Create some fake metadata
    const metadata = "d4:name4:test12:piece lengthi16384e6:pieces20:AAAAAAAAAAAAAAAAAAAAe";
    var hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(metadata, &hash, .{});

    var dl = MetadataDownload.init(allocator, hash);
    defer dl.deinit();

    try dl.setSize(@intCast(metadata.len));
    try std.testing.expectEqual(@as(u32, 1), dl.num_pieces); // small enough for 1 piece

    const complete = try dl.addPiece(0, metadata);
    try std.testing.expect(complete);

    const assembled = try dl.assemble();
    try std.testing.expect(assembled != null);
    defer allocator.free(assembled.?);
    try std.testing.expectEqualStrings(metadata, assembled.?);
}

test "metadata download rejects wrong hash" {
    const allocator = std.testing.allocator;

    const wrong_hash = [_]u8{0xFF} ** 20;
    var dl = MetadataDownload.init(allocator, wrong_hash);
    defer dl.deinit();

    try dl.setSize(10);
    _ = try dl.addPiece(0, "0123456789");

    const assembled = try dl.assemble();
    try std.testing.expect(assembled == null); // hash mismatch
}

test "serialize extension message" {
    const allocator = std.testing.allocator;

    const payload = [_]u8{ 0, 'd', 'e' }; // ext_id=0, empty dict
    const wire_msg = try serializeExtensionMessage(allocator, &payload);
    defer allocator.free(wire_msg);

    // 4 bytes length + 1 byte msg_id + 3 bytes payload
    try std.testing.expectEqual(@as(usize, 8), wire_msg.len);
    // Length = 4 (1 for msg_id + 3 for payload)
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, wire_msg[0..4], .big));
    try std.testing.expectEqual(@as(u8, 20), wire_msg[4]); // msg_id
}
