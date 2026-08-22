/// Piece and block state tracking for BitTorrent downloads.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Standard block size: 16KB (2^14 bytes).
pub const block_size: u32 = 16384;

/// Compact bitfield tracking which pieces are complete.
/// Bit ordering follows BEP 3: bit 7 of byte 0 is piece 0.
pub const Bitfield = struct {
    bytes: []u8,
    num_pieces: u32,

    pub fn init(allocator: Allocator, num_pieces: u32) error{OutOfMemory}!Bitfield {
        const byte_count = (num_pieces + 7) / 8;
        const bytes = allocator.alloc(u8, byte_count) catch return error.OutOfMemory;
        @memset(bytes, 0);
        return .{ .bytes = bytes, .num_pieces = num_pieces };
    }

    pub fn deinit(self: Bitfield, allocator: Allocator) void {
        allocator.free(self.bytes);
    }

    pub fn hasPiece(self: Bitfield, index: u32) bool {
        if (index >= self.num_pieces) return false;
        const byte_idx = index / 8;
        const bit_idx: u3 = @intCast(7 - (index % 8));
        return (self.bytes[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
    }

    pub fn setPiece(self: *Bitfield, index: u32) void {
        if (index >= self.num_pieces) return;
        const byte_idx = index / 8;
        const bit_idx: u3 = @intCast(7 - (index % 8));
        self.bytes[byte_idx] |= @as(u8, 1) << bit_idx;
    }

    pub fn clearPiece(self: *Bitfield, index: u32) void {
        if (index >= self.num_pieces) return;
        const byte_idx = index / 8;
        const bit_idx: u3 = @intCast(7 - (index % 8));
        self.bytes[byte_idx] &= ~(@as(u8, 1) << bit_idx);
    }

    pub fn count(self: Bitfield) u32 {
        var n: u32 = 0;
        for (0..self.num_pieces) |i| {
            if (self.hasPiece(@intCast(i))) n += 1;
        }
        return n;
    }

    pub fn isComplete(self: Bitfield) bool {
        return self.count() == self.num_pieces;
    }

    pub fn rawBytes(self: Bitfield) []const u8 {
        return self.bytes;
    }

    pub fn fromRaw(allocator: Allocator, raw: []const u8, num_pieces: u32) error{ OutOfMemory, InvalidLength }!Bitfield {
        const expected = (num_pieces + 7) / 8;
        if (raw.len != expected) return error.InvalidLength;
        const bytes = allocator.alloc(u8, expected) catch return error.OutOfMemory;
        @memcpy(bytes, raw);
        return .{ .bytes = bytes, .num_pieces = num_pieces };
    }
};

/// Tracks received blocks for a single in-progress piece.
pub const PieceProgress = struct {
    index: u32,
    piece_len: u32,
    num_blocks: u32,
    received: []u8,
    /// Blocks currently requested from some peer (in flight). Tracked
    /// separately from `received` so the scheduler never re-requests a block
    /// that is already on the wire — without this, every pipeline slot fills
    /// with duplicates of the first missing block. Bits are cleared when the
    /// owning request is released (choke, disconnect, timeout) so the block
    /// becomes schedulable again.
    requested: []u8,
    data: []u8,

    pub fn init(allocator: Allocator, index: u32, piece_len: u32) error{OutOfMemory}!PieceProgress {
        // Non-overflowing ceil-divide: `piece_len + block_size - 1` wraps a u32
        // for piece lengths near 2^32 (remote panic). piece_length is bounded at
        // torrent intake (metainfo/session), but keep the arithmetic safe here.
        const num_blocks = piece_len / block_size + @as(u32, @intFromBool(piece_len % block_size != 0));
        const recv_bytes = (num_blocks + 7) / 8;
        const received = allocator.alloc(u8, recv_bytes) catch return error.OutOfMemory;
        @memset(received, 0);
        const requested = allocator.alloc(u8, recv_bytes) catch {
            allocator.free(received);
            return error.OutOfMemory;
        };
        @memset(requested, 0);
        const data = allocator.alloc(u8, piece_len) catch {
            allocator.free(received);
            allocator.free(requested);
            return error.OutOfMemory;
        };
        @memset(data, 0);
        return .{
            .index = index,
            .piece_len = piece_len,
            .num_blocks = num_blocks,
            .received = received,
            .requested = requested,
            .data = data,
        };
    }

    pub fn deinit(self: PieceProgress, allocator: Allocator) void {
        allocator.free(self.received);
        allocator.free(self.requested);
        allocator.free(self.data);
    }

    /// Record a received block. Returns true if piece is now complete.
    pub fn addBlock(self: *PieceProgress, begin: u32, block: []const u8) bool {
        if (begin >= self.piece_len) return false;
        const block_len = std.math.cast(u32, block.len) orelse return false;
        // Non-wrapping bounds check: `begin + block_len` can overflow u32 for a
        // crafted `piece` reply against a large-piece torrent (remote panic /
        // OOB slice). begin < piece_len here, so piece_len - begin is safe.
        if (block_len > self.piece_len - begin) return false;
        const end = begin + block_len;

        @memcpy(self.data[begin..end], block);

        // Mark the block as received
        const block_idx = begin / block_size;
        const byte_idx = block_idx / 8;
        const bit_idx: u3 = @intCast(7 - (block_idx % 8));
        self.received[byte_idx] |= @as(u8, 1) << bit_idx;

        return self.isComplete();
    }

    pub fn hasBlock(self: PieceProgress, block_idx: u32) bool {
        if (block_idx >= self.num_blocks) return false;
        const byte_idx = block_idx / 8;
        const bit_idx: u3 = @intCast(7 - (block_idx % 8));
        return (self.received[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
    }

    pub fn isComplete(self: PieceProgress) bool {
        for (0..self.num_blocks) |i| {
            if (!self.hasBlock(@intCast(i))) return false;
        }
        return true;
    }

    /// Return the next un-received block index, or null.
    pub fn nextMissingBlock(self: PieceProgress) ?u32 {
        for (0..self.num_blocks) |i| {
            if (!self.hasBlock(@intCast(i))) return @intCast(i);
        }
        return null;
    }

    pub fn isRequested(self: PieceProgress, block_idx: u32) bool {
        if (block_idx >= self.num_blocks) return false;
        const byte_idx = block_idx / 8;
        const bit_idx: u3 = @intCast(7 - (block_idx % 8));
        return (self.requested[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
    }

    pub fn markRequested(self: *PieceProgress, block_idx: u32) void {
        if (block_idx >= self.num_blocks) return;
        const byte_idx = block_idx / 8;
        const bit_idx: u3 = @intCast(7 - (block_idx % 8));
        self.requested[byte_idx] |= @as(u8, 1) << bit_idx;
    }

    /// Release an in-flight mark (the owning request was choked away,
    /// timed out, or its peer disconnected) so the block is schedulable again.
    pub fn clearRequested(self: *PieceProgress, block_idx: u32) void {
        if (block_idx >= self.num_blocks) return;
        const byte_idx = block_idx / 8;
        const bit_idx: u3 = @intCast(7 - (block_idx % 8));
        self.requested[byte_idx] &= ~(@as(u8, 1) << bit_idx);
    }

    /// Return the next block that is neither received nor in flight, or null.
    /// This is what the scheduler uses; `nextMissingBlock` (received-only) is
    /// for completeness checks where in-flight state must not hide a block.
    pub fn nextUnrequestedBlock(self: PieceProgress) ?u32 {
        for (0..self.num_blocks) |i| {
            const idx: u32 = @intCast(i);
            if (!self.hasBlock(idx) and !self.isRequested(idx)) return idx;
        }
        return null;
    }

    /// Compute begin offset and length for a given block index.
    pub fn blockSpec(self: PieceProgress, block_idx: u32) struct { begin: u32, length: u32 } {
        const begin = block_idx * block_size;
        const remaining = self.piece_len - begin;
        const length = @min(remaining, block_size);
        return .{ .begin = begin, .length = length };
    }

    /// Reset all received and in-flight state (for retry after hash failure).
    pub fn reset(self: *PieceProgress) void {
        @memset(self.received, 0);
        @memset(self.requested, 0);
        @memset(self.data, 0);
    }
};

/// Verify a piece's data against its expected SHA-1 hash.
pub fn verifyPiece(data: []const u8, expected: *const [20]u8) bool {
    var out: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(data, &out, .{});
    return std.mem.eql(u8, &out, expected);
}

/// Extract the expected hash for piece `index` from the metainfo pieces blob.
pub fn pieceHash(pieces: []const u8, index: u32) ?*const [20]u8 {
    const offset = @as(usize, index) * 20;
    if (offset + 20 > pieces.len) return null;
    return @ptrCast(pieces[offset..][0..20]);
}

/// Compute the actual length of piece `index`.
pub fn pieceLength(index: u32, piece_len: u64, total_length: u64) u32 {
    const piece_start = @as(u64, index) * piece_len;
    if (piece_start >= total_length) return 0;
    const remaining = total_length - piece_start;
    return std.math.cast(u32, @min(remaining, piece_len)) orelse 0;
}

/// Compute total number of pieces.
pub fn numPieces(total_length: u64, piece_len: u64) u32 {
    if (piece_len == 0) return 0;
    return std.math.cast(u32, (total_length + piece_len - 1) / piece_len) orelse 0;
}

/// Compute total length from file list.
pub fn totalLength(files: []const @import("metainfo.zig").FileInfo) u64 {
    var total: u64 = 0;
    for (files) |f| total += f.length;
    return total;
}

// --- Tests ---

test "bitfield init all clear" {
    const allocator = std.testing.allocator;
    var bf = try Bitfield.init(allocator, 10);
    defer bf.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 0), bf.count());
    try std.testing.expect(!bf.hasPiece(0));
    try std.testing.expect(!bf.hasPiece(9));
}

test "bitfield set and has" {
    const allocator = std.testing.allocator;
    var bf = try Bitfield.init(allocator, 16);
    defer bf.deinit(allocator);
    bf.setPiece(0);
    bf.setPiece(7);
    bf.setPiece(15);
    try std.testing.expect(bf.hasPiece(0));
    try std.testing.expect(bf.hasPiece(7));
    try std.testing.expect(bf.hasPiece(15));
    try std.testing.expect(!bf.hasPiece(1));
    try std.testing.expectEqual(@as(u32, 3), bf.count());
}

test "bitfield clear" {
    const allocator = std.testing.allocator;
    var bf = try Bitfield.init(allocator, 8);
    defer bf.deinit(allocator);
    bf.setPiece(3);
    try std.testing.expect(bf.hasPiece(3));
    bf.clearPiece(3);
    try std.testing.expect(!bf.hasPiece(3));
}

test "bitfield complete" {
    const allocator = std.testing.allocator;
    var bf = try Bitfield.init(allocator, 3);
    defer bf.deinit(allocator);
    try std.testing.expect(!bf.isComplete());
    bf.setPiece(0);
    bf.setPiece(1);
    bf.setPiece(2);
    try std.testing.expect(bf.isComplete());
}

test "bitfield fromRaw roundtrip" {
    const allocator = std.testing.allocator;
    var bf = try Bitfield.init(allocator, 10);
    defer bf.deinit(allocator);
    bf.setPiece(0);
    bf.setPiece(5);
    bf.setPiece(9);

    const raw = bf.rawBytes();
    var bf2 = try Bitfield.fromRaw(allocator, raw, 10);
    defer bf2.deinit(allocator);
    try std.testing.expect(bf2.hasPiece(0));
    try std.testing.expect(bf2.hasPiece(5));
    try std.testing.expect(bf2.hasPiece(9));
    try std.testing.expect(!bf2.hasPiece(1));
}

test "piece progress block assembly" {
    const allocator = std.testing.allocator;
    // 32KB piece = 2 blocks of 16KB
    var pp = try PieceProgress.init(allocator, 0, 32768);
    defer pp.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 2), pp.num_blocks);
    try std.testing.expect(!pp.isComplete());

    const block1 = [_]u8{0xAA} ** 16384;
    _ = pp.addBlock(0, &block1);
    try std.testing.expect(pp.hasBlock(0));
    try std.testing.expect(!pp.hasBlock(1));
    try std.testing.expect(!pp.isComplete());

    const block2 = [_]u8{0xBB} ** 16384;
    const complete = pp.addBlock(16384, &block2);
    try std.testing.expect(complete);
    try std.testing.expect(pp.isComplete());

    // Verify data was assembled correctly
    try std.testing.expectEqual(@as(u8, 0xAA), pp.data[0]);
    try std.testing.expectEqual(@as(u8, 0xBB), pp.data[16384]);
}

test "addBlock rejects begin+len overflow without panicking" {
    const allocator = std.testing.allocator;
    // A small piece with a huge `begin`: begin < piece_len is false here, but
    // the guard must also survive begin values near u32 max where begin+len
    // would wrap. Use a piece_len just above begin so the overflow path is the
    // one exercised.
    var pp = try PieceProgress.init(allocator, 0, 32768);
    defer pp.deinit(allocator);
    const block = [_]u8{0xCC} ** 16;
    // begin beyond piece_len is rejected outright.
    try std.testing.expect(!pp.addBlock(0xFFFF_FFF0, &block));
    // begin within the piece but begin+len exceeding it is rejected (no wrap).
    try std.testing.expect(!pp.addBlock(32760, &block));
    try std.testing.expect(!pp.isComplete());
}

test "piece progress next missing block" {
    const allocator = std.testing.allocator;
    var pp = try PieceProgress.init(allocator, 0, 49152); // 3 blocks
    defer pp.deinit(allocator);

    try std.testing.expectEqual(@as(?u32, 0), pp.nextMissingBlock());
    _ = pp.addBlock(0, &([_]u8{0} ** 16384));
    try std.testing.expectEqual(@as(?u32, 1), pp.nextMissingBlock());
    _ = pp.addBlock(16384, &([_]u8{0} ** 16384));
    try std.testing.expectEqual(@as(?u32, 2), pp.nextMissingBlock());
    _ = pp.addBlock(32768, &([_]u8{0} ** 16384));
    try std.testing.expectEqual(@as(?u32, null), pp.nextMissingBlock());
}

test "piece progress requested tracking" {
    const allocator = std.testing.allocator;
    var pp = try PieceProgress.init(allocator, 0, 49152); // 3 blocks
    defer pp.deinit(allocator);

    // Scheduling marks blocks in flight: each pick advances, never repeats.
    try std.testing.expectEqual(@as(?u32, 0), pp.nextUnrequestedBlock());
    pp.markRequested(0);
    try std.testing.expectEqual(@as(?u32, 1), pp.nextUnrequestedBlock());
    pp.markRequested(1);
    pp.markRequested(2);
    try std.testing.expectEqual(@as(?u32, null), pp.nextUnrequestedBlock());

    // `nextMissingBlock` still sees in-flight blocks as missing.
    try std.testing.expectEqual(@as(?u32, 0), pp.nextMissingBlock());

    // Releasing an in-flight block (peer choked/disconnected/timed out)
    // makes it schedulable again.
    pp.clearRequested(1);
    try std.testing.expectEqual(@as(?u32, 1), pp.nextUnrequestedBlock());

    // A received block stays unschedulable even with no requested bit.
    pp.clearRequested(0);
    _ = pp.addBlock(0, &([_]u8{0} ** 16384));
    try std.testing.expectEqual(@as(?u32, 1), pp.nextUnrequestedBlock());

    // reset() clears in-flight state too.
    pp.reset();
    try std.testing.expectEqual(@as(?u32, 0), pp.nextUnrequestedBlock());
}

test "piece progress block spec" {
    const allocator = std.testing.allocator;
    // 20000 bytes = block 0 (16384) + block 1 (3616)
    var pp = try PieceProgress.init(allocator, 0, 20000);
    defer pp.deinit(allocator);

    const s0 = pp.blockSpec(0);
    try std.testing.expectEqual(@as(u32, 0), s0.begin);
    try std.testing.expectEqual(@as(u32, 16384), s0.length);

    const s1 = pp.blockSpec(1);
    try std.testing.expectEqual(@as(u32, 16384), s1.begin);
    try std.testing.expectEqual(@as(u32, 3616), s1.length);
}

test "verify piece SHA-1" {
    const data = "hello world";
    // SHA-1 of "hello world"
    var expected: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(data, &expected, .{});

    try std.testing.expect(verifyPiece(data, &expected));

    var wrong = expected;
    wrong[0] ^= 0xFF;
    try std.testing.expect(!verifyPiece(data, &wrong));
}

test "piece hash extraction" {
    const pieces = [_]u8{0xAA} ** 40; // 2 pieces worth of hashes
    const h0 = pieceHash(&pieces, 0).?;
    try std.testing.expectEqual(@as(u8, 0xAA), h0[0]);

    const h1 = pieceHash(&pieces, 1).?;
    try std.testing.expectEqual(@as(u8, 0xAA), h1[0]);

    try std.testing.expect(pieceHash(&pieces, 2) == null);
}

test "piece length last piece" {
    // 10 pieces of 256KB, total = 2500KB (last piece = 36KB)
    const pl = 262144; // 256KB
    const total = 2560000; // ~2500KB
    try std.testing.expectEqual(@as(u32, 262144), pieceLength(0, pl, total));
    try std.testing.expectEqual(@as(u32, 262144), pieceLength(8, pl, total));
    // Last piece: 2560000 - 9*262144 = 2560000 - 2359296 = 200704
    try std.testing.expectEqual(@as(u32, 200704), pieceLength(9, pl, total));
    try std.testing.expectEqual(@as(u32, 0), pieceLength(10, pl, total));
}

test "num pieces" {
    try std.testing.expectEqual(@as(u32, 10), numPieces(2560000, 262144));
    try std.testing.expectEqual(@as(u32, 1), numPieces(100, 262144));
    try std.testing.expectEqual(@as(u32, 0), numPieces(0, 262144));
}
