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
    /// Number of set bits within `num_pieces`, maintained incrementally.
    /// The session's poll loop asks `isComplete()` on every wake and reports
    /// `count()` on every completed piece; recomputing either from the bytes
    /// is O(num_pieces), which on a 10k-piece torrent burns real CPU for an
    /// answer that only changes when a bit changes. Every mutation path in
    /// this struct keeps this field in sync, so both are O(1).
    have_count: u32,

    pub fn init(allocator: Allocator, num_pieces: u32) error{OutOfMemory}!Bitfield {
        const byte_count = (num_pieces + 7) / 8;
        const bytes = allocator.alloc(u8, byte_count) catch return error.OutOfMemory;
        @memset(bytes, 0);
        return .{ .bytes = bytes, .num_pieces = num_pieces, .have_count = 0 };
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
        const mask = @as(u8, 1) << bit_idx;
        // Only move the cached count when the bit actually flips, so repeated
        // `have` messages for the same piece can't inflate it.
        if (self.bytes[byte_idx] & mask == 0) self.have_count += 1;
        self.bytes[byte_idx] |= mask;
    }

    pub fn clearPiece(self: *Bitfield, index: u32) void {
        if (index >= self.num_pieces) return;
        const byte_idx = index / 8;
        const bit_idx: u3 = @intCast(7 - (index % 8));
        const mask = @as(u8, 1) << bit_idx;
        if (self.bytes[byte_idx] & mask != 0) self.have_count -= 1;
        self.bytes[byte_idx] &= ~mask;
    }

    pub fn count(self: Bitfield) u32 {
        return self.have_count;
    }

    pub fn isComplete(self: Bitfield) bool {
        return self.have_count == self.num_pieces;
    }

    /// Recompute the set-bit count from the bytes. Only used when a bitfield
    /// is built from raw bytes (and by the tests, to prove the incremental
    /// count never drifts from the truth).
    fn recount(self: Bitfield) u32 {
        return popCountPrefix(self.bytes, self.num_pieces);
    }

    pub fn rawBytes(self: Bitfield) []const u8 {
        return self.bytes;
    }

    pub fn fromRaw(allocator: Allocator, raw: []const u8, num_pieces: u32) error{ OutOfMemory, InvalidLength }!Bitfield {
        const expected = (num_pieces + 7) / 8;
        if (raw.len != expected) return error.InvalidLength;
        const bytes = allocator.alloc(u8, expected) catch return error.OutOfMemory;
        @memcpy(bytes, raw);
        // The peer's spare bits (past `num_pieces`) are theirs to get wrong;
        // popCountPrefix ignores them, matching `hasPiece`, which refuses any
        // index at or past `num_pieces`.
        return .{ .bytes = bytes, .num_pieces = num_pieces, .have_count = popCountPrefix(bytes, num_pieces) };
    }
};

/// Count set bits among the first `num_bits` bits of `bytes`, in BEP 3 order
/// (bit 7 of byte 0 is bit 0). Whole 64-bit words go through `@popCount` --
/// one instruction per 64 pieces instead of one branch per piece -- and the
/// trailing partial byte is masked so bits past `num_bits` never count.
fn popCountPrefix(bytes: []const u8, num_bits: u32) u32 {
    const full_bytes = num_bits / 8;
    var n: u32 = 0;
    var i: usize = 0;
    while (i + 8 <= full_bytes) : (i += 8) {
        // Bit order within the word is irrelevant to a population count, so
        // the raw byte-array reinterpretation is fine (and alignment-safe).
        const word: u64 = @bitCast(bytes[i..][0..8].*);
        n += @popCount(word);
    }
    while (i < full_bytes) : (i += 1) n += @popCount(bytes[i]);

    const rem = num_bits % 8;
    if (rem != 0) {
        const shift: u3 = @intCast(8 - rem);
        n += @popCount(bytes[full_bytes] & (@as(u8, 0xFF) << shift));
    }
    return n;
}

/// Index of the first bit that is set in neither `primary` nor `in_flight`,
/// limited to `num_bits`, or null when every bit is covered. Scanning 64 bits
/// at a time with `@clz` keeps the scheduler's per-block "what's next" lookup
/// off the one-branch-per-block path; `in_flight` is null for callers that
/// only care about what has actually arrived.
fn firstMissingBit(primary: []const u8, in_flight: ?[]const u8, num_bits: u32) ?u32 {
    const all_ones = ~@as(u64, 0);
    const full_words = num_bits / 64;

    var w: usize = 0;
    while (w < full_words) : (w += 1) {
        const off = w * 8;
        // Big-endian read so the word's most significant bit is the lowest
        // block index -- that is what makes `@clz` the missing bit's index.
        var word = std.mem.readInt(u64, primary[off..][0..8], .big);
        if (in_flight) |f| word |= std.mem.readInt(u64, f[off..][0..8], .big);
        if (word != all_ones) return @intCast(w * 64 + @clz(~word));
    }

    var base: u32 = @intCast(full_words * 64);
    var byte_idx: usize = full_words * 8;
    while (base < num_bits) : ({
        base += 8;
        byte_idx += 1;
    }) {
        var b = primary[byte_idx];
        if (in_flight) |f| b |= f[byte_idx];
        if (b != 0xFF) {
            const idx = base + @clz(~b);
            // Only reachable in the trailing partial byte: its spare bits read
            // as missing, but there is no such block.
            if (idx >= num_bits) return null;
            return idx;
        }
    }
    return null;
}

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
        const num_blocks = (piece_len + block_size - 1) / block_size;
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
        const end = begin + block_len;
        if (end > self.piece_len) return false;

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
        return firstMissingBit(self.received, null, self.num_blocks) == null;
    }

    /// Return the next un-received block index, or null.
    pub fn nextMissingBlock(self: PieceProgress) ?u32 {
        return firstMissingBit(self.received, null, self.num_blocks);
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
        return firstMissingBit(self.received, self.requested, self.num_blocks);
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

test "bitfield count ignores spare bits in the trailing byte" {
    const allocator = std.testing.allocator;
    // 12 pieces occupy 1.5 bytes: a peer that sets the 4 spare bits (or just
    // sends 0xFF padding) must not read as 16 pieces, and must not read as
    // complete before we actually have all 12.
    const raw = [_]u8{ 0xFF, 0xFF };
    var bf = try Bitfield.fromRaw(allocator, &raw, 12);
    defer bf.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 12), bf.count());
    try std.testing.expectEqual(bf.recount(), bf.count());
    try std.testing.expect(bf.isComplete());
    try std.testing.expect(!bf.hasPiece(12));

    // The same shape from the other direction: a partial trailing byte where
    // only some live bits are set.
    const partial = [_]u8{ 0b1010_0000, 0b1100_1111 };
    var bf2 = try Bitfield.fromRaw(allocator, &partial, 12);
    defer bf2.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 4), bf2.count()); // 2 + 2, spare bits dropped
    try std.testing.expectEqual(bf2.recount(), bf2.count());
    try std.testing.expect(!bf2.isComplete());
}

test "bitfield cached count survives every mutation path" {
    const allocator = std.testing.allocator;
    // Not a multiple of 8, and larger than one 64-bit word, so the word-at-a-
    // time popcount and the masked tail are both exercised.
    const num_pieces: u32 = 3020;
    var bf = try Bitfield.init(allocator, num_pieces);
    defer bf.deinit(allocator);
    try std.testing.expectEqual(bf.recount(), bf.count());

    // set: including a repeat (a duplicate `have`) and an out-of-range index,
    // neither of which may move the count.
    var i: u32 = 0;
    while (i < num_pieces) : (i += 3) bf.setPiece(i);
    bf.setPiece(0);
    bf.setPiece(num_pieces);
    bf.setPiece(num_pieces + 1000);
    try std.testing.expectEqual(bf.recount(), bf.count());

    // clear: same deal in reverse.
    i = 0;
    while (i < num_pieces) : (i += 7) bf.clearPiece(i);
    bf.clearPiece(7);
    bf.clearPiece(num_pieces);
    try std.testing.expectEqual(bf.recount(), bf.count());

    // fromRaw: a bitfield rebuilt from the wire agrees with the original.
    var bf2 = try Bitfield.fromRaw(allocator, bf.rawBytes(), num_pieces);
    defer bf2.deinit(allocator);
    try std.testing.expectEqual(bf.count(), bf2.count());
    try std.testing.expectEqual(bf2.recount(), bf2.count());

    // ...and filling it completely lands exactly on num_pieces.
    i = 0;
    while (i < num_pieces) : (i += 1) bf2.setPiece(i);
    try std.testing.expectEqual(num_pieces, bf2.count());
    try std.testing.expectEqual(bf2.recount(), bf2.count());
    try std.testing.expect(bf2.isComplete());

    // A single clear anywhere makes it incomplete again.
    bf2.clearPiece(num_pieces - 1);
    try std.testing.expect(!bf2.isComplete());
    try std.testing.expectEqual(num_pieces - 1, bf2.count());
}

test "bitfield count at every length around a byte boundary" {
    const allocator = std.testing.allocator;
    // Lengths 0..17 cover empty, sub-byte, exact-byte and multi-byte cases.
    for (0..18) |n| {
        const num_pieces: u32 = @intCast(n);
        var bf = try Bitfield.init(allocator, num_pieces);
        defer bf.deinit(allocator);
        try std.testing.expectEqual(@as(u32, 0), bf.count());
        try std.testing.expectEqual(num_pieces == 0, bf.isComplete());

        var i: u32 = 0;
        while (i < num_pieces) : (i += 1) {
            bf.setPiece(i);
            try std.testing.expectEqual(i + 1, bf.count());
            try std.testing.expectEqual(bf.recount(), bf.count());
        }
        try std.testing.expect(bf.isComplete());
    }
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

test "piece progress scans agree with a per-block reference" {
    const allocator = std.testing.allocator;
    // 100 blocks: more than one 64-bit word, and not a multiple of 8, so the
    // word scan and the masked tail byte both get hit.
    const num_blocks: u32 = 100;
    var pp = try PieceProgress.init(allocator, 0, num_blocks * block_size);
    defer pp.deinit(allocator);
    try std.testing.expectEqual(num_blocks, pp.num_blocks);

    const ref = struct {
        fn firstMissing(p: PieceProgress) ?u32 {
            for (0..p.num_blocks) |i| {
                if (!p.hasBlock(@intCast(i))) return @intCast(i);
            }
            return null;
        }
        fn firstUnrequested(p: PieceProgress) ?u32 {
            for (0..p.num_blocks) |i| {
                const idx: u32 = @intCast(i);
                if (!p.hasBlock(idx) and !p.isRequested(idx)) return idx;
            }
            return null;
        }
    };

    // Walk a mixed state: some blocks received, some only in flight, in an
    // order that leaves holes in the middle of words and in the tail byte.
    var seed: u32 = 12345;
    var step: u32 = 0;
    while (step < num_blocks * 2) : (step += 1) {
        seed = seed *% 1664525 +% 1013904223;
        const idx = seed % num_blocks;
        if (seed & 1 == 0) {
            pp.markRequested(idx);
        } else {
            pp.markRequested(idx);
            _ = pp.addBlock(idx * block_size, &([_]u8{0} ** block_size));
        }
        try std.testing.expectEqual(ref.firstMissing(pp), pp.nextMissingBlock());
        try std.testing.expectEqual(ref.firstUnrequested(pp), pp.nextUnrequestedBlock());
        try std.testing.expectEqual(ref.firstMissing(pp) == null, pp.isComplete());
    }

    // Finish it off: only the very last block missing, then none.
    var i: u32 = 0;
    while (i < num_blocks - 1) : (i += 1) _ = pp.addBlock(i * block_size, &([_]u8{0} ** block_size));
    try std.testing.expectEqual(@as(?u32, num_blocks - 1), pp.nextMissingBlock());
    try std.testing.expect(!pp.isComplete());
    _ = pp.addBlock((num_blocks - 1) * block_size, &([_]u8{0} ** block_size));
    try std.testing.expectEqual(@as(?u32, null), pp.nextMissingBlock());
    try std.testing.expect(pp.isComplete());
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
