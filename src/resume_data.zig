//! Persisted verified-piece bitfield ("resume data"), so restarting a transfer
//! doesn't have to re-hash every byte already on disk.
//!
//! `Session.init` used to SHA-1 every existing piece before it could do
//! anything else: seconds for a 755 MB torrent, minutes for a multi-GB one,
//! all on the thread that added the transfer (which is what the desktop's 60s
//! keepalive was papering over). Resuming a mostly-complete torrent should be
//! instant, so the bitfield the scan produced is written next to the payload
//! and read back on the next start.
//!
//! The rule everywhere below: this record is a CACHE of a hash check, never the
//! truth. A wrongly-set bit means serving corrupt data to peers and calling a
//! broken download complete — far worse than the seconds a re-verify costs. So
//! every check is a reason to REJECT the record and fall back to the full
//! verify, and anything unexpected (unknown format, bad checksum, changed
//! size/mtime, different geometry, a failed spot check) resolves that way.
const std = @import("std");
const Allocator = std.mem.Allocator;
const piece_mod = @import("piece.zig");
const storage_mod = @import("storage.zig");

const log = std.log.scoped(.resume_data);

/// Records live in `<output_dir>/.carl-resume/<infohash-hex>.resume`, i.e. next
/// to the data they describe rather than in the daemon's config dir. The data
/// directory is what the record is *about*: seed dirs are user-chosen and the
/// CLI, the daemon, and `carl follow` all point at different ones, so keying
/// the location off the payload is the only placement where every frontend
/// finds the same record. Hidden and per-info-hash so several torrents can
/// share one directory without colliding or cluttering it.
pub const dir_name = ".carl-resume";

/// Layout version, carried in the magic. A record written by another version
/// fails the magic check and is re-verified instead of being misread.
const format_version: u8 = 1;
const magic = [8]u8{ 'C', 'A', 'R', 'L', 'R', 'S', 'M', format_version };

/// magic + info_hash + piece_length + total_length + num_pieces + num_files
/// + saved_at.
const header_len = 8 + 20 + 8 + 8 + 4 + 4 + 8;
/// Per payload file: size + mtime (nanoseconds).
const stamp_len = 8 + 16;
/// CRC-32 over everything preceding it.
const trailer_len = 4;

/// Refuse to allocate for anything absurd: 64 MiB of record describes ~500M
/// pieces, orders of magnitude past any real torrent.
const max_record_bytes: usize = 64 * 1024 * 1024;

/// How many of the pieces a record claims are re-hashed before it is believed.
/// Size and mtime can only prove that *something* changed; they cannot prove
/// nothing did (coarse filesystem timestamps, a same-size in-place rewrite, a
/// restore from backup that preserved mtime, silent corruption). Four pieces
/// is a few tens of milliseconds even at a 4 MiB piece size — nothing against
/// a multi-GB re-hash — and it catches every wholesale divergence, which is
/// what the failure mode actually looks like in practice.
const spot_checks: usize = 4;

/// Seconds between periodic saves while pieces are arriving. A crash can lose
/// at most this much verified progress (it costs a re-verify, never
/// correctness), and each save fsyncs the payload, so it must not be hot.
pub const save_interval_secs: i64 = 20;

/// Size + last-modification time of a payload file at save time. Reused from
/// storage so both sides of the comparison are literally the same type.
pub const FileStamp = storage_mod.FileStat;

/// The torrent geometry a record must match exactly to be usable. Anything
/// that changes the meaning of a bit lives here.
pub const Key = struct {
    info_hash: [20]u8,
    piece_length: u64,
    total_length: u64,
    num_pieces: u32,
    num_files: u32,

    pub fn eql(a: Key, b: Key) bool {
        return std.mem.eql(u8, &a.info_hash, &b.info_hash) and
            a.piece_length == b.piece_length and
            a.total_length == b.total_length and
            a.num_pieces == b.num_pieces and
            a.num_files == b.num_files;
    }
};

pub const DecodeError = error{ BadMagic, BadLength, BadChecksum };

/// A parsed record. Borrows the caller's buffer: the stamps and the bitfield
/// are read out of it in place, so nothing here allocates.
pub const Record = struct {
    key: Key,
    saved_at: i64,
    buf: []const u8,

    pub fn stamp(self: Record, index: u32) FileStamp {
        const off = header_len + @as(usize, index) * stamp_len;
        return .{
            .size = std.mem.readInt(u64, self.buf[off..][0..8], .little),
            .mtime_ns = std.mem.readInt(i128, self.buf[off + 8 ..][0..16], .little),
        };
    }

    pub fn bits(self: Record) []const u8 {
        const off = header_len + @as(usize, self.key.num_files) * stamp_len;
        return self.buf[off .. self.buf.len - trailer_len];
    }
};

/// Serialize a record. Caller owns the result.
pub fn encode(
    a: Allocator,
    key: Key,
    stamps: []const FileStamp,
    saved_at: i64,
    bits: []const u8,
) Allocator.Error![]u8 {
    const total = header_len + stamps.len * stamp_len + bits.len + trailer_len;
    const buf = try a.alloc(u8, total);
    errdefer a.free(buf);

    @memcpy(buf[0..8], &magic);
    @memcpy(buf[8..28], &key.info_hash);
    std.mem.writeInt(u64, buf[28..36], key.piece_length, .little);
    std.mem.writeInt(u64, buf[36..44], key.total_length, .little);
    std.mem.writeInt(u32, buf[44..48], key.num_pieces, .little);
    std.mem.writeInt(u32, buf[48..52], key.num_files, .little);
    std.mem.writeInt(i64, buf[52..60], saved_at, .little);

    var w: usize = header_len;
    for (stamps) |s| {
        std.mem.writeInt(u64, buf[w..][0..8], s.size, .little);
        std.mem.writeInt(i128, buf[w + 8 ..][0..16], s.mtime_ns, .little);
        w += stamp_len;
    }
    @memcpy(buf[w..][0..bits.len], bits);
    w += bits.len;

    std.mem.writeInt(u32, buf[w..][0..4], std.hash.Crc32.hash(buf[0..w]), .little);
    return buf;
}

/// Parse a record without trusting any of it. The length is recomputed from
/// the header and must match the buffer exactly, so a truncated (crash
/// mid-write, full disk) or over-long record is rejected before any field is
/// used; the CRC then rejects bit rot. Counts are widened to u64 first so a
/// corrupt `num_files` can't wrap the size arithmetic into a valid-looking one.
pub fn decode(buf: []const u8) DecodeError!Record {
    if (buf.len < header_len + trailer_len) return error.BadLength;
    if (!std.mem.eql(u8, buf[0..8], &magic)) return error.BadMagic;

    var key: Key = undefined;
    @memcpy(&key.info_hash, buf[8..28]);
    key.piece_length = std.mem.readInt(u64, buf[28..36], .little);
    key.total_length = std.mem.readInt(u64, buf[36..44], .little);
    key.num_pieces = std.mem.readInt(u32, buf[44..48], .little);
    key.num_files = std.mem.readInt(u32, buf[48..52], .little);
    const saved_at = std.mem.readInt(i64, buf[52..60], .little);

    const bits_len = (@as(u64, key.num_pieces) + 7) / 8;
    const expected = @as(u64, header_len) +
        @as(u64, key.num_files) * stamp_len + bits_len + trailer_len;
    if (expected != buf.len) return error.BadLength;

    const stored = std.mem.readInt(u32, buf[buf.len - trailer_len ..][0..4], .little);
    if (stored != std.hash.Crc32.hash(buf[0 .. buf.len - trailer_len])) return error.BadChecksum;

    return .{ .key = key, .saved_at = saved_at, .buf = buf };
}

/// Longest path we ever build: `<dir>/<40 hex>.resume` plus the `.tmp` suffix
/// the atomic save writes through.
const path_max = dir_name.len + 1 + 40 + ".resume".len + ".tmp".len;

/// Build the record's path inside the output dir. Formatted into a
/// caller-provided buffer rather than stored, so `Resume` stays a plain value
/// that survives being copied (`Session` is returned by value from its init).
fn recordPath(buf: *[path_max]u8, info_hash: [20]u8, tmp: bool) []const u8 {
    const hex = std.fmt.bytesToHex(info_hash, .lower);
    return std.fmt.bufPrint(buf, "{s}/{s}.resume{s}", .{
        dir_name,
        &hex,
        if (tmp) ".tmp" else "",
    }) catch unreachable; // path_max is sized for exactly this
}

/// The session's handle on its record: which torrent it describes, and whether
/// the in-memory bitfield has moved since the last save.
pub const Resume = struct {
    info_hash: [20]u8,
    /// Set when a piece was gained or lost since the last successful save.
    /// Nothing is written while this is false: the record on disk still
    /// describes the payload exactly, and rewriting it would only cost an
    /// fsync.
    dirty: bool = false,
    /// Wall-clock second of the last successful save; gates `maybeSave`.
    last_save_s: i64 = 0,

    pub fn markDirty(self: *Resume) void {
        self.dirty = true;
    }

    /// Restore the verified bitfield without hashing anything, or return null —
    /// which always means "re-verify from the bytes on disk". Null covers a
    /// missing, unreadable, stale, corrupt, or spot-check-failing record; the
    /// caller cannot tell them apart and must not care.
    ///
    /// Caller owns the returned bitfield.
    pub fn load(
        self: *Resume,
        a: Allocator,
        store: *storage_mod.Storage,
        key: Key,
        pieces: []const u8,
    ) ?piece_mod.Bitfield {
        // A magnet whose metadata hasn't landed has no geometry to match yet.
        if (key.num_pieces == 0 or key.num_files == 0) return null;

        var pb: [path_max]u8 = undefined;
        const path = recordPath(&pb, self.info_hash, false);

        const raw = store.dir.readFileAlloc(a, path, max_record_bytes) catch return null;
        defer a.free(raw);

        const rec = decode(raw) catch |err| {
            log.debug("resume: unusable record ({t}); verifying from disk", .{err});
            return null;
        };

        // Same torrent, same piece geometry, same file count — otherwise a bit
        // in the record doesn't refer to the piece we'd apply it to.
        if (!rec.key.eql(key)) {
            log.debug("resume: record geometry differs; verifying from disk", .{});
            return null;
        }

        // Every payload file must be exactly as it was when the record was
        // written. The stat goes through the handle we will actually read
        // pieces from (`fstat`, not a path lookup), so a file swapped out
        // between the check and the reads can't slip past it.
        for (0..key.num_files) |i| {
            const idx: u32 = @intCast(i);
            const cur = store.statFile(idx) catch return null;
            const rec_stamp = rec.stamp(idx);
            if (cur.size != rec_stamp.size or cur.mtime_ns != rec_stamp.mtime_ns) {
                log.debug("resume: file {d} changed since save; verifying from disk", .{idx});
                return null;
            }
            // ...and it must still be the size the torrent says. A record
            // written against a half-allocated file is not a resume point.
            if (cur.size != store.file_map.file_lengths[i]) return null;
        }

        // Spare bits past `num_pieces` are ours, unlike a peer's bitfield: if
        // any is set the record wasn't written by us as we write it, so it is
        // not a record we understand.
        if (!spareBitsClear(rec.bits(), key.num_pieces)) {
            log.debug("resume: record has junk past the last piece; verifying from disk", .{});
            return null;
        }

        var bf = piece_mod.Bitfield.fromRaw(a, rec.bits(), key.num_pieces) catch return null;
        if (!self.spotCheck(a, store, bf, key, pieces)) {
            bf.deinit(a);
            return null;
        }

        // The record still describes the payload exactly; nothing to write
        // until a piece moves.
        self.dirty = false;
        self.last_save_s = std.time.timestamp();
        return bf;
    }

    /// Re-hash a few of the pieces the record claims. The two ends are always
    /// picked (truncation and partial rewrites show up there first) plus random
    /// interior ones, so nothing about the file layout can systematically dodge
    /// the check. Any miss discards the WHOLE record: one wrong bit means the
    /// record's provenance is unknown, and a partially-trusted bitfield is the
    /// exact thing this module must never produce.
    fn spotCheck(
        self: *Resume,
        a: Allocator,
        store: *storage_mod.Storage,
        bf: piece_mod.Bitfield,
        key: Key,
        pieces: []const u8,
    ) bool {
        _ = self;
        const have = bf.count();
        if (have == 0) return true; // nothing claimed, nothing to disprove

        var picks: [spot_checks]u32 = undefined;
        var n: usize = 0;
        picks[n] = nthSetPiece(bf, 0) orelse return false;
        n += 1;
        if (have > 1) {
            picks[n] = nthSetPiece(bf, have - 1) orelse return false;
            n += 1;
        }
        while (n < picks.len and have > 2) : (n += 1) {
            const ord = std.crypto.random.intRangeLessThan(u32, 0, have);
            picks[n] = nthSetPiece(bf, ord) orelse return false;
        }

        for (picks[0..n]) |idx| {
            const plen = piece_mod.pieceLength(idx, key.piece_length, key.total_length);
            if (plen == 0) return false;
            const data = store.readPiece(a, idx, plen) catch return false;
            defer a.free(data);
            const hash = piece_mod.pieceHash(pieces, idx) orelse return false;
            if (!piece_mod.verifyPiece(data, hash)) {
                log.warn(
                    "resume: piece {d} does not match its hash; re-verifying the whole payload",
                    .{idx},
                );
                return false;
            }
        }
        return true;
    }

    /// Write the current bitfield out, atomically. Best-effort by design: a
    /// failed save costs a re-verify on the next start, never correctness, so
    /// no error is propagated to the session.
    pub fn save(
        self: *Resume,
        a: Allocator,
        store: *storage_mod.Storage,
        key: Key,
        bf: piece_mod.Bitfield,
    ) void {
        // Never write a record we can't stand behind: a magnet still fetching
        // metadata has no geometry, and a 0-piece record here would clobber a
        // real one left by a previous run of the same torrent.
        if (key.num_pieces == 0 or key.num_files == 0) return;
        if (bf.num_pieces != key.num_pieces) return;
        if (store.files_closed) return;

        // Get the payload durable BEFORE the record that vouches for it.
        // Without this ordering a power cut can leave a record claiming pieces
        // whose bytes never left the page cache — the trusted-but-wrong state
        // everything else here exists to prevent.
        store.syncAll();

        const stamps = a.alloc(FileStamp, key.num_files) catch return;
        defer a.free(stamps);
        for (stamps, 0..) |*s, i| s.* = store.statFile(@intCast(i)) catch return;

        const blob = encode(a, key, stamps, std.time.timestamp(), bf.rawBytes()) catch return;
        defer a.free(blob);

        store.dir.makePath(dir_name) catch {};

        var tb: [path_max]u8 = undefined;
        const tmp = recordPath(&tb, self.info_hash, true);
        {
            const f = store.dir.createFile(tmp, .{}) catch return;
            defer f.close();
            f.writeAll(blob) catch {
                store.dir.deleteFile(tmp) catch {};
                return;
            };
            // Flush before the rename: the rename is what publishes the record,
            // and a record published ahead of its own bytes is exactly the
            // corrupt-but-trusted file this is meant to rule out.
            f.sync() catch {};
        }

        var db: [path_max]u8 = undefined;
        const dst = recordPath(&db, self.info_hash, false);
        store.dir.rename(tmp, dst) catch {
            store.dir.deleteFile(tmp) catch {};
            return;
        };

        self.dirty = false;
        self.last_save_s = std.time.timestamp();
    }

    /// Periodic save while pieces are arriving: only when something changed and
    /// at most every `save_interval_secs`.
    pub fn maybeSave(
        self: *Resume,
        a: Allocator,
        store: *storage_mod.Storage,
        key: Key,
        bf: piece_mod.Bitfield,
        now: i64,
    ) void {
        if (!self.dirty) return;
        if (now - self.last_save_s < save_interval_secs) return;
        self.save(a, store, key, bf);
    }
};

/// Index of the `ord`-th set piece (0-based), or null if there aren't that
/// many. O(num_pieces) and only ever run `spot_checks` times at startup.
fn nthSetPiece(bf: piece_mod.Bitfield, ord: u32) ?u32 {
    var seen: u32 = 0;
    var i: u32 = 0;
    while (i < bf.num_pieces) : (i += 1) {
        if (!bf.hasPiece(i)) continue;
        if (seen == ord) return i;
        seen += 1;
    }
    return null;
}

/// True when the bits past `num_pieces` in the trailing byte are all zero.
fn spareBitsClear(bits: []const u8, num_pieces: u32) bool {
    const rem = num_pieces % 8;
    if (rem == 0) return true;
    const last = bits[bits.len - 1];
    const shift: u3 = @intCast(8 - rem);
    return (last & ~(@as(u8, 0xFF) << shift)) == 0;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;
const metainfo = @import("metainfo.zig");

const test_piece_len: u64 = 16384;
const test_pieces: u32 = 4;
const test_total: u64 = test_piece_len * test_pieces;

/// A payload of `test_pieces` distinct pieces plus the matching hash blob, so
/// the tests exercise the real verify path rather than a stubbed one.
const Fixture = struct {
    data: [test_total]u8,
    hashes: [test_pieces * 20]u8,

    fn make() Fixture {
        var f: Fixture = undefined;
        for (&f.data, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);
        var p: u32 = 0;
        while (p < test_pieces) : (p += 1) {
            const start = p * test_piece_len;
            std.crypto.hash.Sha1.hash(
                f.data[start .. start + test_piece_len],
                f.hashes[p * 20 ..][0..20],
                .{},
            );
        }
        return f;
    }

    fn meta(self: *const Fixture, files: []const metainfo.FileInfo) metainfo.Metainfo {
        return .{
            .announce = "",
            .announce_list = null,
            .name = "test",
            .piece_length = test_piece_len,
            .pieces = &self.hashes,
            .files = files,
            .comment = null,
            .creation_date = null,
            .created_by = null,
            .raw_info = &.{},
            .url_list = null,
        };
    }
};

const test_info_hash: [20]u8 = .{0xAB} ** 20;

fn testKey(num_files: u32) Key {
    return .{
        .info_hash = test_info_hash,
        .piece_length = test_piece_len,
        .total_length = test_total,
        .num_pieces = test_pieces,
        .num_files = num_files,
    };
}

/// Lay the fixture payload down in `dir_path` and hand back an open store.
fn openStore(a: Allocator, fx: *const Fixture, dir_path: []const u8, files: []const metainfo.FileInfo) !storage_mod.Storage {
    var store = try storage_mod.Storage.init(a, fx.meta(files), dir_path, true);
    errdefer store.deinit();
    var p: u32 = 0;
    while (p < test_pieces) : (p += 1) {
        try store.writePiece(p, fx.data[p * test_piece_len ..][0..test_piece_len]);
    }
    return store;
}

const single_file = [_]metainfo.FileInfo{
    .{ .length = test_total, .path = &.{"payload.bin"} },
};

test "resume: round-trips a saved bitfield and skips the re-hash" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = tmp.dir.realpathAlloc(a, ".") catch return;
    defer a.free(path);

    const fx = Fixture.make();
    var store = try openStore(a, &fx, path, &single_file);
    defer store.deinit();

    var bf = try piece_mod.Bitfield.init(a, test_pieces);
    defer bf.deinit(a);
    bf.setPiece(0);
    bf.setPiece(2);
    bf.setPiece(3);

    var r: Resume = .{ .info_hash = test_info_hash };
    r.save(a, &store, testKey(1), bf);

    var r2: Resume = .{ .info_hash = test_info_hash };
    var loaded = r2.load(a, &store, testKey(1), &fx.hashes) orelse return error.RecordRejected;
    defer loaded.deinit(a);

    try testing.expectEqual(@as(u32, 3), loaded.count());
    try testing.expect(loaded.hasPiece(0));
    try testing.expect(!loaded.hasPiece(1));
    try testing.expect(loaded.hasPiece(2));
    try testing.expect(loaded.hasPiece(3));
}

test "resume: a file whose size changed is rejected" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = tmp.dir.realpathAlloc(a, ".") catch return;
    defer a.free(path);

    const fx = Fixture.make();
    var store = try openStore(a, &fx, path, &single_file);
    defer store.deinit();

    var bf = try piece_mod.Bitfield.init(a, test_pieces);
    defer bf.deinit(a);
    bf.setPiece(0);

    var r: Resume = .{ .info_hash = test_info_hash };
    r.save(a, &store, testKey(1), bf);

    // Someone truncated (or grew) the payload behind our back.
    try store.handles[0].setEndPos(test_total - 1);
    try testing.expect(r.load(a, &store, testKey(1), &fx.hashes) == null);
}

test "resume: a file touched after the save is rejected" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = tmp.dir.realpathAlloc(a, ".") catch return;
    defer a.free(path);

    const fx = Fixture.make();
    var store = try openStore(a, &fx, path, &single_file);
    defer store.deinit();

    var bf = try piece_mod.Bitfield.init(a, test_pieces);
    defer bf.deinit(a);
    bf.setPiece(1);

    var r: Resume = .{ .info_hash = test_info_hash };
    r.save(a, &store, testKey(1), bf);
    var fresh = r.load(a, &store, testKey(1), &fx.hashes) orelse return error.RecordRejected;
    fresh.deinit(a);

    // Same bytes, same size — only the mtime moves. That alone must sink the
    // record: we can't tell a harmless rewrite from a hostile one.
    const before = try store.statFile(0);
    try store.handles[0].updateTimes(before.mtime_ns + std.time.ns_per_s, before.mtime_ns + std.time.ns_per_s);
    try testing.expect(r.load(a, &store, testKey(1), &fx.hashes) == null);
}

test "resume: different geometry or info hash is rejected" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = tmp.dir.realpathAlloc(a, ".") catch return;
    defer a.free(path);

    const fx = Fixture.make();
    var store = try openStore(a, &fx, path, &single_file);
    defer store.deinit();

    var bf = try piece_mod.Bitfield.init(a, test_pieces);
    defer bf.deinit(a);
    bf.setPiece(0);

    var r: Resume = .{ .info_hash = test_info_hash };
    r.save(a, &store, testKey(1), bf);

    // Same file, but the caller now believes in a different piece length,
    // piece count, total length, or file count: every bit would mean something
    // else, so none of them may be used.
    var k = testKey(1);
    k.piece_length = test_piece_len * 2;
    try testing.expect(r.load(a, &store, k, &fx.hashes) == null);

    k = testKey(1);
    k.num_pieces = test_pieces - 1;
    try testing.expect(r.load(a, &store, k, &fx.hashes) == null);

    k = testKey(1);
    k.total_length = test_total - 1;
    try testing.expect(r.load(a, &store, k, &fx.hashes) == null);

    k = testKey(2);
    try testing.expect(r.load(a, &store, k, &fx.hashes) == null);

    // And a record for a different torrent that happens to sit in the same
    // directory is not ours to read (it isn't even at our path, but the key
    // check is the belt to that suspenders).
    k = testKey(1);
    k.info_hash = .{0xCD} ** 20;
    try testing.expect(r.load(a, &store, k, &fx.hashes) == null);
}

test "resume: truncated or corrupt records are rejected" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = tmp.dir.realpathAlloc(a, ".") catch return;
    defer a.free(path);

    const fx = Fixture.make();
    var store = try openStore(a, &fx, path, &single_file);
    defer store.deinit();

    var bf = try piece_mod.Bitfield.init(a, test_pieces);
    defer bf.deinit(a);
    bf.setPiece(0);
    bf.setPiece(1);

    var r: Resume = .{ .info_hash = test_info_hash };
    r.save(a, &store, testKey(1), bf);

    var pb: [path_max]u8 = undefined;
    const rec_path = recordPath(&pb, test_info_hash, false);
    const good = try store.dir.readFileAlloc(a, rec_path, max_record_bytes);
    defer a.free(good);

    // Truncated (a crash mid-write, a full disk).
    try store.dir.writeFile(.{ .sub_path = rec_path, .data = good[0 .. good.len - 3] });
    try testing.expect(r.load(a, &store, testKey(1), &fx.hashes) == null);

    // Trailing junk.
    const longer = try a.alloc(u8, good.len + 4);
    defer a.free(longer);
    @memcpy(longer[0..good.len], good);
    @memset(longer[good.len..], 0);
    try store.dir.writeFile(.{ .sub_path = rec_path, .data = longer });
    try testing.expect(r.load(a, &store, testKey(1), &fx.hashes) == null);

    // A single flipped bit anywhere (bit rot, a partial overwrite).
    const flipped = try a.dupe(u8, good);
    defer a.free(flipped);
    flipped[header_len + 2] ^= 0x40;
    try store.dir.writeFile(.{ .sub_path = rec_path, .data = flipped });
    try testing.expect(r.load(a, &store, testKey(1), &fx.hashes) == null);

    // A record from another format version.
    const aliened = try a.dupe(u8, good);
    defer a.free(aliened);
    aliened[7] = format_version + 1;
    try store.dir.writeFile(.{ .sub_path = rec_path, .data = aliened });
    try testing.expect(r.load(a, &store, testKey(1), &fx.hashes) == null);

    // The untouched original still loads, so the rejections above are about
    // the damage and not about the fixture.
    try store.dir.writeFile(.{ .sub_path = rec_path, .data = good });
    var ok = r.load(a, &store, testKey(1), &fx.hashes) orelse return error.RecordRejected;
    ok.deinit(a);
}

test "resume: a missing record is simply absent" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = tmp.dir.realpathAlloc(a, ".") catch return;
    defer a.free(path);

    const fx = Fixture.make();
    var store = try openStore(a, &fx, path, &single_file);
    defer store.deinit();

    var r: Resume = .{ .info_hash = test_info_hash };
    try testing.expect(r.load(a, &store, testKey(1), &fx.hashes) == null);
}

test "resume: content that changed under an unchanged stamp fails the spot check" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = tmp.dir.realpathAlloc(a, ".") catch return;
    defer a.free(path);

    const fx = Fixture.make();
    var store = try openStore(a, &fx, path, &single_file);
    defer store.deinit();

    var bf = try piece_mod.Bitfield.init(a, test_pieces);
    defer bf.deinit(a);
    var p: u32 = 0;
    while (p < test_pieces) : (p += 1) bf.setPiece(p);

    var r: Resume = .{ .info_hash = test_info_hash };
    r.save(a, &store, testKey(1), bf);
    const stamp = try store.statFile(0);

    // The adversarial case size+mtime cannot catch on its own: the payload is
    // rewritten in place at the same length and the timestamp is put back
    // (a restore from backup, a coarse-granularity filesystem, a same-second
    // overwrite). The spot check is the only thing standing between this and
    // serving garbage to peers.
    const junk = [_]u8{0x00} ** test_piece_len;
    try store.writePiece(0, &junk);
    try store.writePiece(test_pieces - 1, &junk);
    try store.handles[0].updateTimes(stamp.mtime_ns, stamp.mtime_ns);
    try testing.expectEqual(stamp.mtime_ns, (try store.statFile(0)).mtime_ns);

    try testing.expect(r.load(a, &store, testKey(1), &fx.hashes) == null);
}

test "resume: a cleared piece is not resurrected by the next load" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = tmp.dir.realpathAlloc(a, ".") catch return;
    defer a.free(path);

    const fx = Fixture.make();
    var store = try openStore(a, &fx, path, &single_file);
    defer store.deinit();

    var bf = try piece_mod.Bitfield.init(a, test_pieces);
    defer bf.deinit(a);
    var p: u32 = 0;
    while (p < test_pieces) : (p += 1) bf.setPiece(p);

    var r: Resume = .{ .info_hash = test_info_hash };
    r.save(a, &store, testKey(1), bf);

    // A piece that later failed verification (unreadable on disk, bad hash)
    // is dropped and the record rewritten; the old bit must not come back.
    bf.clearPiece(2);
    r.markDirty();
    r.save(a, &store, testKey(1), bf);

    var loaded = r.load(a, &store, testKey(1), &fx.hashes) orelse return error.RecordRejected;
    defer loaded.deinit(a);
    try testing.expect(!loaded.hasPiece(2));
    try testing.expectEqual(@as(u32, test_pieces - 1), loaded.count());
}

test "resume: multi-file torrents stamp every file" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = tmp.dir.realpathAlloc(a, ".") catch return;
    defer a.free(path);

    // Two files, split mid-piece, so a change in either one invalidates
    // pieces that straddle the boundary.
    const files = [_]metainfo.FileInfo{
        .{ .length = test_piece_len + 100, .path = &.{"a.bin"} },
        .{ .length = test_total - test_piece_len - 100, .path = &.{ "sub", "b.bin" } },
    };

    const fx = Fixture.make();
    var store = try openStore(a, &fx, path, &files);
    defer store.deinit();

    var bf = try piece_mod.Bitfield.init(a, test_pieces);
    defer bf.deinit(a);
    var p: u32 = 0;
    while (p < test_pieces) : (p += 1) bf.setPiece(p);

    var r: Resume = .{ .info_hash = test_info_hash };
    r.save(a, &store, testKey(2), bf);

    var loaded = r.load(a, &store, testKey(2), &fx.hashes) orelse return error.RecordRejected;
    loaded.deinit(a);

    // Touching the SECOND file must invalidate the record too — a per-torrent
    // stamp of only the first file would miss most of the payload.
    const st = try store.statFile(1);
    try store.handles[1].updateTimes(st.mtime_ns + std.time.ns_per_s, st.mtime_ns + std.time.ns_per_s);
    try testing.expect(r.load(a, &store, testKey(2), &fx.hashes) == null);
}

test "resume: junk in the bits past the last piece is rejected" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = tmp.dir.realpathAlloc(a, ".") catch return;
    defer a.free(path);

    // 3 pieces means 5 spare bits in the single bitfield byte.
    const three = 3;
    const files = [_]metainfo.FileInfo{
        .{ .length = test_piece_len * three, .path = &.{"payload.bin"} },
    };
    const fx = Fixture.make();
    var store = try storage_mod.Storage.init(a, fx.meta(&files), path, true);
    defer store.deinit();
    var p: u32 = 0;
    while (p < three) : (p += 1) {
        try store.writePiece(p, fx.data[p * test_piece_len ..][0..test_piece_len]);
    }

    const key: Key = .{
        .info_hash = test_info_hash,
        .piece_length = test_piece_len,
        .total_length = test_piece_len * three,
        .num_pieces = three,
        .num_files = 1,
    };

    const stamps = [_]FileStamp{try store.statFile(0)};
    const bits = [_]u8{0b1110_0001}; // pieces 0-2 set, plus a bit that can't exist
    const blob = try encode(a, key, &stamps, std.time.timestamp(), &bits);
    defer a.free(blob);
    try store.dir.makePath(dir_name);
    var pb: [path_max]u8 = undefined;
    try store.dir.writeFile(.{ .sub_path = recordPath(&pb, test_info_hash, false), .data = blob });

    var r: Resume = .{ .info_hash = test_info_hash };
    try testing.expect(r.load(a, &store, key, &fx.hashes) == null);
}

test "resume: encode/decode round-trip preserves every field" {
    const a = testing.allocator;
    const key = testKey(2);
    const stamps = [_]FileStamp{
        .{ .size = 1234, .mtime_ns = -42 }, // pre-epoch mtimes exist; keep the sign
        .{ .size = std.math.maxInt(u64), .mtime_ns = std.math.maxInt(i64) },
    };
    const bits = [_]u8{0b1010_0000};
    const blob = try encode(a, key, &stamps, 1_700_000_000, &bits);
    defer a.free(blob);

    const rec = try decode(blob);
    try testing.expect(rec.key.eql(key));
    try testing.expectEqual(@as(i64, 1_700_000_000), rec.saved_at);
    try testing.expectEqual(stamps[0].size, rec.stamp(0).size);
    try testing.expectEqual(stamps[0].mtime_ns, rec.stamp(0).mtime_ns);
    try testing.expectEqual(stamps[1].size, rec.stamp(1).size);
    try testing.expectEqual(stamps[1].mtime_ns, rec.stamp(1).mtime_ns);
    try testing.expectEqualSlices(u8, &bits, rec.bits());
}

test "decode: a wildly wrong file count can't wrap the length check" {
    const a = testing.allocator;
    const stamps = [_]FileStamp{.{ .size = 1, .mtime_ns = 1 }};
    const bits = [_]u8{0};
    const blob = try encode(a, testKey(1), &stamps, 0, &bits);
    defer a.free(blob);

    // num_files = 2^32-1: the implied size is far past the buffer, and the
    // arithmetic must notice rather than overflow into a plausible number.
    std.mem.writeInt(u32, blob[48..52], std.math.maxInt(u32), .little);
    std.mem.writeInt(u32, blob[blob.len - 4 ..][0..4], std.hash.Crc32.hash(blob[0 .. blob.len - 4]), .little);
    try testing.expectError(error.BadLength, decode(blob));
}

test "nthSetPiece and spareBitsClear" {
    const a = testing.allocator;
    var bf = try piece_mod.Bitfield.init(a, 20);
    defer bf.deinit(a);
    bf.setPiece(3);
    bf.setPiece(11);
    bf.setPiece(19);
    try testing.expectEqual(@as(?u32, 3), nthSetPiece(bf, 0));
    try testing.expectEqual(@as(?u32, 11), nthSetPiece(bf, 1));
    try testing.expectEqual(@as(?u32, 19), nthSetPiece(bf, 2));
    try testing.expectEqual(@as(?u32, null), nthSetPiece(bf, 3));

    try testing.expect(spareBitsClear(&[_]u8{ 0xFF, 0xFF }, 16)); // no spare bits
    try testing.expect(spareBitsClear(&[_]u8{ 0xFF, 0b1110_0000 }, 11));
    try testing.expect(!spareBitsClear(&[_]u8{ 0xFF, 0b1110_0001 }, 11));
}
