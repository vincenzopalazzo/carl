const std = @import("std");
const Allocator = std.mem.Allocator;
const bencode = @import("bencode.zig");
const Value = bencode.Value;

/// A single file described in a torrent.
pub const FileInfo = struct {
    /// File length in bytes.
    length: u64,
    /// Path components (e.g. ["dir", "file.txt"]).
    path: []const []const u8,
};

/// Parsed .torrent metainfo.
pub const Metainfo = struct {
    /// Primary tracker URL.
    announce: []const u8,
    /// Optional list of tracker tier lists.
    announce_list: ?[]const []const []const u8,
    /// Torrent name (suggested file/directory name).
    name: []const u8,
    /// Piece length in bytes.
    piece_length: u64,
    /// Concatenated SHA-1 hashes (20 bytes each).
    pieces: []const u8,
    /// Files in the torrent. Single-file torrents have exactly one entry.
    files: []const FileInfo,
    /// Optional comment.
    comment: ?[]const u8,
    /// Optional creation date (unix timestamp).
    creation_date: ?i64,
    /// Optional creator string.
    created_by: ?[]const u8,
    /// The raw bencoded info dictionary bytes, for computing info_hash.
    raw_info: []const u8,
    /// Optional web seed URLs (BEP 19).
    url_list: ?[]const []const u8,

    /// Free all memory owned by this struct.
    pub fn deinit(self: Metainfo, allocator: Allocator) void {
        allocator.free(self.announce);
        if (self.announce_list) |tiers| {
            for (tiers) |tier| {
                for (tier) |url| allocator.free(url);
                allocator.free(tier);
            }
            allocator.free(tiers);
        }
        allocator.free(self.name);
        allocator.free(self.pieces);
        for (self.files) |file| {
            for (file.path) |comp| allocator.free(comp);
            allocator.free(file.path);
        }
        allocator.free(self.files);
        if (self.comment) |c| allocator.free(c);
        if (self.created_by) |c| allocator.free(c);
        allocator.free(self.raw_info);
        if (self.url_list) |urls| {
            for (urls) |url| allocator.free(url);
            allocator.free(urls);
        }
    }
};

pub const MetainfoError = error{
    InvalidTorrent,
    MissingField,
    OutOfMemory,
};

/// Parse a .torrent file from raw bytes.
pub fn parse(allocator: Allocator, data: []const u8) MetainfoError!Metainfo {
    const root = bencode.decode(allocator, data) catch return error.InvalidTorrent;
    defer root.deinit(allocator);

    // announce is optional -- many modern torrents only have announce-list
    var announce: []const u8 = if (root.dictGet("announce")) |av|
        if (av.asString()) |s|
            allocator.dupe(u8, s) catch return error.OutOfMemory
        else
            allocator.dupe(u8, "") catch return error.OutOfMemory
    else
        allocator.dupe(u8, "") catch return error.OutOfMemory;
    errdefer allocator.free(announce);

    const announce_list = if (root.dictGet("announce-list")) |al_val| blk: {
        const tiers_list = al_val.asList() orelse break :blk null;
        var tiers: std.ArrayList([]const []const u8) = .empty;
        errdefer {
            for (tiers.items) |tier| {
                for (tier) |url| allocator.free(url);
                allocator.free(tier);
            }
            tiers.deinit(allocator);
        }
        for (tiers_list) |tier_val| {
            const tier_list = tier_val.asList() orelse continue;
            var urls: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (urls.items) |url| allocator.free(url);
                urls.deinit(allocator);
            }
            for (tier_list) |url_val| {
                const url_str = url_val.asString() orelse continue;
                const url = allocator.dupe(u8, url_str) catch return error.OutOfMemory;
                urls.append(allocator, url) catch {
                    allocator.free(url);
                    return error.OutOfMemory;
                };
            }
            const tier_slice = urls.toOwnedSlice(allocator) catch return error.OutOfMemory;
            tiers.append(allocator, tier_slice) catch {
                for (tier_slice) |url| allocator.free(url);
                allocator.free(tier_slice);
                return error.OutOfMemory;
            };
        }
        break :blk @as(?[]const []const []const u8, tiers.toOwnedSlice(allocator) catch return error.OutOfMemory);
    } else null;
    errdefer if (announce_list) |tiers| {
        for (tiers) |tier| {
            for (tier) |url| allocator.free(url);
            allocator.free(tier);
        }
        allocator.free(tiers);
    };

    // If announce is empty, use first tracker from announce-list
    if (announce.len == 0) {
        if (announce_list) |tiers| {
            if (tiers.len > 0 and tiers[0].len > 0) {
                allocator.free(announce);
                announce = allocator.dupe(u8, tiers[0][0]) catch return error.OutOfMemory;
            }
        }
    }

    const info_val = root.dictGet("info") orelse return error.MissingField;

    // Re-encode the info dict to get canonical bytes for info_hash.
    // This is correct because bencode has a single canonical encoding.
    const raw_info = bencode.encode(allocator, info_val) catch return error.OutOfMemory;
    errdefer allocator.free(raw_info);

    const name_val = info_val.dictGet("name") orelse return error.MissingField;
    const name_str = name_val.asString() orelse return error.InvalidTorrent;
    const name = allocator.dupe(u8, name_str) catch return error.OutOfMemory;
    errdefer allocator.free(name);

    const pl_val = info_val.dictGet("piece length") orelse return error.MissingField;
    const piece_length: u64 = std.math.cast(u64, pl_val.asInt() orelse return error.InvalidTorrent) orelse return error.InvalidTorrent;

    const pieces_val = info_val.dictGet("pieces") orelse return error.MissingField;
    const pieces_str = pieces_val.asString() orelse return error.InvalidTorrent;
    const pieces = allocator.dupe(u8, pieces_str) catch return error.OutOfMemory;
    errdefer allocator.free(pieces);

    const files = if (info_val.dictGet("files")) |files_val| blk: {
        const file_list = files_val.asList() orelse return error.InvalidTorrent;
        var files_arr: std.ArrayList(FileInfo) = .empty;
        errdefer {
            for (files_arr.items) |fi| {
                for (fi.path) |comp| allocator.free(comp);
                allocator.free(fi.path);
            }
            files_arr.deinit(allocator);
        }
        for (file_list) |file_val| {
            const fi = try parseFileEntry(allocator, file_val);
            files_arr.append(allocator, fi) catch {
                for (fi.path) |comp| allocator.free(comp);
                allocator.free(fi.path);
                return error.OutOfMemory;
            };
        }
        break :blk files_arr.toOwnedSlice(allocator) catch return error.OutOfMemory;
    } else blk: {
        const length_val = info_val.dictGet("length") orelse return error.MissingField;
        const length: u64 = std.math.cast(u64, length_val.asInt() orelse return error.InvalidTorrent) orelse return error.InvalidTorrent;

        const path_comp = allocator.dupe(u8, name_str) catch return error.OutOfMemory;
        const path = allocator.alloc([]const u8, 1) catch {
            allocator.free(path_comp);
            return error.OutOfMemory;
        };
        path[0] = path_comp;

        const file_slice = allocator.alloc(FileInfo, 1) catch {
            allocator.free(path_comp);
            allocator.free(path);
            return error.OutOfMemory;
        };
        file_slice[0] = .{ .length = length, .path = path };
        break :blk @as([]const FileInfo, file_slice);
    };
    errdefer {
        for (files) |fi| {
            for (fi.path) |comp| allocator.free(comp);
            allocator.free(fi.path);
        }
        allocator.free(files);
    }

    const comment = if (root.dictGet("comment")) |cv|
        if (cv.asString()) |s|
            allocator.dupe(u8, s) catch return error.OutOfMemory
        else
            null
    else
        null;
    errdefer if (comment) |c| allocator.free(c);

    const creation_date = if (root.dictGet("creation date")) |cv|
        cv.asInt()
    else
        null;

    const created_by = if (root.dictGet("created by")) |cv|
        if (cv.asString()) |s|
            allocator.dupe(u8, s) catch return error.OutOfMemory
        else
            null
    else
        null;

    // Parse url-list (BEP 19 web seeds)
    const url_list = if (root.dictGet("url-list")) |ul_val| blk: {
        if (ul_val.asList()) |urls_list| {
            var urls: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (urls.items) |u| allocator.free(u);
                urls.deinit(allocator);
            }
            for (urls_list) |url_val| {
                const url_str = url_val.asString() orelse continue;
                const url = allocator.dupe(u8, url_str) catch return error.OutOfMemory;
                urls.append(allocator, url) catch {
                    allocator.free(url);
                    return error.OutOfMemory;
                };
            }
            break :blk @as(?[]const []const u8, urls.toOwnedSlice(allocator) catch return error.OutOfMemory);
        } else if (ul_val.asString()) |single_url| {
            // Single URL string (not a list)
            const url = allocator.dupe(u8, single_url) catch return error.OutOfMemory;
            const urls = allocator.alloc([]const u8, 1) catch {
                allocator.free(url);
                return error.OutOfMemory;
            };
            urls[0] = url;
            break :blk @as(?[]const []const u8, urls);
        } else break :blk null;
    } else null;

    return .{
        .announce = announce,
        .announce_list = announce_list,
        .name = name,
        .piece_length = piece_length,
        .pieces = pieces,
        .files = files,
        .comment = comment,
        .creation_date = creation_date,
        .created_by = created_by,
        .raw_info = raw_info,
        .url_list = url_list,
    };
}

fn parseFileEntry(allocator: Allocator, value: Value) MetainfoError!FileInfo {
    const length_val = value.dictGet("length") orelse return error.MissingField;
    const length: u64 = std.math.cast(u64, length_val.asInt() orelse return error.InvalidTorrent) orelse return error.InvalidTorrent;

    const path_val = value.dictGet("path") orelse return error.MissingField;
    const path_list = path_val.asList() orelse return error.InvalidTorrent;

    var path: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (path.items) |comp| allocator.free(comp);
        path.deinit(allocator);
    }

    for (path_list) |comp_val| {
        const comp_str = comp_val.asString() orelse return error.InvalidTorrent;
        const comp = allocator.dupe(u8, comp_str) catch return error.OutOfMemory;
        path.append(allocator, comp) catch {
            allocator.free(comp);
            return error.OutOfMemory;
        };
    }

    return .{
        .length = length,
        .path = path.toOwnedSlice(allocator) catch return error.OutOfMemory,
    };
}

/// Compute the SHA-1 info_hash from the raw info dictionary bytes.
pub fn infoHash(raw_info: []const u8) [20]u8 {
    var out: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(raw_info, &out, .{});
    return out;
}

/// Default piece size for created torrents (256 KiB).
pub const default_piece_length: u32 = 256 * 1024;

/// Create a single-file torrent (metainfo) from a file on disk: hash it into
/// `piece_length` pieces, build the canonical info dict, and return a
/// fully-owned `Metainfo` (free with `deinit`). No trackers — discovery is via
/// Nostr / DHT. A `.tar`/`.zip`/`.pdf` is just a single file, so this covers the
/// "seed an archive" case directly. Streams the file so large inputs don't load
/// into memory at once.
pub fn createSingleFile(allocator: Allocator, path: []const u8, piece_length: u32) MetainfoError!Metainfo {
    var file = std.fs.cwd().openFile(path, .{}) catch return error.InvalidTorrent;
    defer file.close();

    const base = std.fs.path.basename(path);
    if (base.len == 0) return error.InvalidTorrent;
    const name = allocator.dupe(u8, base) catch return error.OutOfMemory;
    errdefer allocator.free(name);

    var pieces_buf: std.ArrayList(u8) = .empty;
    errdefer pieces_buf.deinit(allocator);
    const chunk = allocator.alloc(u8, piece_length) catch return error.OutOfMemory;
    defer allocator.free(chunk);

    var total: u64 = 0;
    while (true) {
        const n = file.readAll(chunk) catch return error.InvalidTorrent;
        if (n == 0) break;
        var digest: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(chunk[0..n], &digest, .{});
        pieces_buf.appendSlice(allocator, &digest) catch return error.OutOfMemory;
        total += n;
        if (n < piece_length) break; // final (partial) piece
    }
    const pieces = pieces_buf.toOwnedSlice(allocator) catch return error.OutOfMemory;
    errdefer allocator.free(pieces);

    // Canonical info dict — keys MUST be in sorted byte order for a stable
    // info-hash: "length" < "name" < "piece length" < "pieces".
    const info_val = bencode.Value{ .dict = &[_]bencode.Value.DictEntry{
        .{ .key = "length", .value = .{ .integer = @intCast(total) } },
        .{ .key = "name", .value = .{ .string = name } },
        .{ .key = "piece length", .value = .{ .integer = @intCast(piece_length) } },
        .{ .key = "pieces", .value = .{ .string = pieces } },
    } };
    const raw_info = bencode.encode(allocator, info_val) catch return error.OutOfMemory;
    errdefer allocator.free(raw_info);

    const path_comp = allocator.alloc([]const u8, 1) catch return error.OutOfMemory;
    errdefer allocator.free(path_comp);
    path_comp[0] = allocator.dupe(u8, name) catch return error.OutOfMemory;
    errdefer allocator.free(path_comp[0]);
    const files = allocator.alloc(FileInfo, 1) catch return error.OutOfMemory;
    errdefer allocator.free(files);
    files[0] = .{ .length = total, .path = path_comp };

    const announce = allocator.dupe(u8, "") catch return error.OutOfMemory;
    errdefer allocator.free(announce);

    return Metainfo{
        .announce = announce,
        .announce_list = null,
        .name = name,
        .piece_length = piece_length,
        .pieces = pieces,
        .files = files,
        .comment = null,
        .creation_date = null,
        .created_by = null,
        .raw_info = raw_info,
        .url_list = null,
    };
}

/// Options for building a .torrent. Trackers are optional — carl discovers
/// peers via Nostr/DHT — but when present the first becomes `announce` and each
/// gets its own `announce-list` tier (BEP 12).
pub const CreateOptions = struct {
    piece_length: u32 = default_piece_length,
    /// Tracker announce URLs. Empty = a trackerless torrent (Nostr/DHT only).
    trackers: []const []const u8 = &.{},
    comment: ?[]const u8 = null,
    created_by: ?[]const u8 = "carl",
    /// Unix timestamp for the `creation date` field; null omits it. Pass
    /// `std.time.timestamp()` from a caller that wants it stamped.
    creation_date: ?i64 = null,
};

/// Result of `buildTorrent`: the bencoded .torrent bytes (owned by the caller —
/// free with the same allocator) plus a summary of what was hashed.
pub const CreateResult = struct {
    data: []u8,
    info_hash: [20]u8,
    total_length: u64,
    file_count: usize,
};

const FileWork = struct {
    /// Path relative to the torrent root directory.
    rel: []const u8,
};

fn lessByRel(_: void, a: FileWork, b: FileWork) bool {
    return std.mem.lessThan(u8, a.rel, b.rel);
}

fn hashPiece(aa: Allocator, pieces: *std.ArrayList(u8), data: []const u8) MetainfoError!void {
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(data, &digest, .{});
    pieces.appendSlice(aa, &digest) catch return error.OutOfMemory;
}

/// Split a relative path on the OS separator into a bencode list of string
/// components, e.g. "sub/dir/f.txt" → ["sub","dir","f.txt"]. Arena-allocated.
fn pathComponents(aa: Allocator, rel: []const u8) MetainfoError![]bencode.Value {
    var comps: std.ArrayList(bencode.Value) = .empty;
    var it = std.mem.splitScalar(u8, rel, std.fs.path.sep);
    while (it.next()) |c| {
        if (c.len == 0) continue;
        const dup = aa.dupe(u8, c) catch return error.OutOfMemory;
        comps.append(aa, .{ .string = dup }) catch return error.OutOfMemory;
    }
    return comps.toOwnedSlice(aa) catch return error.OutOfMemory;
}

/// Build a complete .torrent from a file OR a directory and return its bencoded
/// bytes. Directories become multi-file torrents whose pieces are hashed as one
/// continuous stream across file boundaries (BEP 3), with files sorted by path
/// for a deterministic, reproducible info-hash. Trackers/comment/created-by live
/// in the top-level dict, so they never affect the info-hash. Streams every file
/// so large inputs don't load into memory at once. Caller owns `result.data`.
pub fn buildTorrent(allocator: Allocator, path: []const u8, opts: CreateOptions) MetainfoError!CreateResult {
    const piece_length: u32 = if (opts.piece_length == 0) default_piece_length else opts.piece_length;

    // Everything intermediate (Value tree, piece buffer, per-file dicts) lives in
    // an arena; only the returned `data` is allocated with `allocator`.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const base = std.fs.path.basename(path);
    if (base.len == 0) return error.InvalidTorrent;
    const name = aa.dupe(u8, base) catch return error.OutOfMemory;

    const st = std.fs.cwd().statFile(path) catch return error.InvalidTorrent;

    var pieces: std.ArrayList(u8) = .empty;
    var total: u64 = 0;
    var file_count: usize = 0;

    const chunk = aa.alloc(u8, piece_length) catch return error.OutOfMemory;
    var filled: usize = 0; // bytes pending in `chunk` toward the current piece

    // Info-dict entries are built in sorted key order so the output re-parses
    // (bencode requires sorted dict keys) and matches other clients' info-hash.
    var info_entries: std.ArrayList(bencode.Value.DictEntry) = .empty;

    if (st.kind == .directory) {
        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return error.InvalidTorrent;
        defer dir.close();

        // Collect every regular file (relative to the dir), then sort for a
        // deterministic piece layout.
        var works: std.ArrayList(FileWork) = .empty;
        var walker = dir.walk(aa) catch return error.OutOfMemory;
        while (walker.next() catch return error.InvalidTorrent) |entry| {
            if (entry.kind != .file) continue;
            const rel = aa.dupe(u8, entry.path) catch return error.OutOfMemory;
            works.append(aa, .{ .rel = rel }) catch return error.OutOfMemory;
        }
        if (works.items.len == 0) return error.InvalidTorrent; // empty directory
        std.mem.sort(FileWork, works.items, {}, lessByRel);

        // Hash all files as one continuous stream — pieces span file boundaries —
        // while building the `files` list (each a {length, path} dict).
        var files_list: std.ArrayList(bencode.Value) = .empty;
        for (works.items) |w| {
            var f = dir.openFile(w.rel, .{}) catch return error.InvalidTorrent;
            defer f.close();
            var flen: u64 = 0;
            while (true) {
                const n = f.readAll(chunk[filled..]) catch return error.InvalidTorrent;
                if (n == 0) break;
                filled += n;
                total += n;
                flen += n;
                if (filled == piece_length) {
                    try hashPiece(aa, &pieces, chunk);
                    filled = 0;
                }
            }
            file_count += 1;
            const comps = try pathComponents(aa, w.rel);
            // File dict keys sorted: "length" < "path".
            const fd = aa.alloc(bencode.Value.DictEntry, 2) catch return error.OutOfMemory;
            fd[0] = .{ .key = "length", .value = .{ .integer = @intCast(flen) } };
            fd[1] = .{ .key = "path", .value = .{ .list = comps } };
            files_list.append(aa, .{ .dict = fd }) catch return error.OutOfMemory;
        }
        if (filled > 0) try hashPiece(aa, &pieces, chunk[0..filled]); // final partial piece

        const files_slice = files_list.toOwnedSlice(aa) catch return error.OutOfMemory;
        // Info keys sorted: "files" < "name" < "piece length" < "pieces".
        info_entries.append(aa, .{ .key = "files", .value = .{ .list = files_slice } }) catch return error.OutOfMemory;
        info_entries.append(aa, .{ .key = "name", .value = .{ .string = name } }) catch return error.OutOfMemory;
        info_entries.append(aa, .{ .key = "piece length", .value = .{ .integer = @intCast(piece_length) } }) catch return error.OutOfMemory;
        info_entries.append(aa, .{ .key = "pieces", .value = .{ .string = pieces.items } }) catch return error.OutOfMemory;
    } else {
        var f = std.fs.cwd().openFile(path, .{}) catch return error.InvalidTorrent;
        defer f.close();
        while (true) {
            const n = f.readAll(chunk[filled..]) catch return error.InvalidTorrent;
            if (n == 0) break;
            filled += n;
            total += n;
            if (filled == piece_length) {
                try hashPiece(aa, &pieces, chunk);
                filled = 0;
            }
        }
        if (filled > 0) try hashPiece(aa, &pieces, chunk[0..filled]);
        file_count = 1;
        // Info keys sorted: "length" < "name" < "piece length" < "pieces".
        info_entries.append(aa, .{ .key = "length", .value = .{ .integer = @intCast(total) } }) catch return error.OutOfMemory;
        info_entries.append(aa, .{ .key = "name", .value = .{ .string = name } }) catch return error.OutOfMemory;
        info_entries.append(aa, .{ .key = "piece length", .value = .{ .integer = @intCast(piece_length) } }) catch return error.OutOfMemory;
        info_entries.append(aa, .{ .key = "pieces", .value = .{ .string = pieces.items } }) catch return error.OutOfMemory;
    }

    const info_val = bencode.Value{ .dict = info_entries.items };

    // info-hash = SHA-1 of the canonical info-dict bytes.
    const raw_info = bencode.encode(aa, info_val) catch return error.OutOfMemory;
    var info_hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(raw_info, &info_hash, .{});

    // Top-level dict, keys appended in sorted order, optional fields skipped when
    // absent: "announce" < "announce-list" < "comment" < "created by" <
    // "creation date" < "info".
    var top: std.ArrayList(bencode.Value.DictEntry) = .empty;
    if (opts.trackers.len > 0) {
        top.append(aa, .{ .key = "announce", .value = .{ .string = opts.trackers[0] } }) catch return error.OutOfMemory;
        const tiers = aa.alloc(bencode.Value, opts.trackers.len) catch return error.OutOfMemory;
        for (opts.trackers, 0..) |t, i| {
            const tier = aa.alloc(bencode.Value, 1) catch return error.OutOfMemory;
            tier[0] = .{ .string = t };
            tiers[i] = .{ .list = tier };
        }
        top.append(aa, .{ .key = "announce-list", .value = .{ .list = tiers } }) catch return error.OutOfMemory;
    }
    if (opts.comment) |c| top.append(aa, .{ .key = "comment", .value = .{ .string = c } }) catch return error.OutOfMemory;
    if (opts.created_by) |cb| top.append(aa, .{ .key = "created by", .value = .{ .string = cb } }) catch return error.OutOfMemory;
    if (opts.creation_date) |cd| top.append(aa, .{ .key = "creation date", .value = .{ .integer = cd } }) catch return error.OutOfMemory;
    top.append(aa, .{ .key = "info", .value = info_val }) catch return error.OutOfMemory;

    const data = bencode.encode(allocator, .{ .dict = top.items }) catch return error.OutOfMemory;
    return .{ .data = data, .info_hash = info_hash, .total_length = total, .file_count = file_count };
}

// --- Tests ---

test "createSingleFile: hashes a file into a valid metainfo" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // 10 bytes with piece_length 4 → 3 pieces (4 + 4 + 2).
    try tmp.dir.writeFile(.{ .sub_path = "data.bin", .data = "0123456789" });
    const path = try tmp.dir.realpathAlloc(allocator, "data.bin");
    defer allocator.free(path);

    const mi = try createSingleFile(allocator, path, 4);
    defer mi.deinit(allocator);

    try std.testing.expectEqualStrings("data.bin", mi.name);
    try std.testing.expectEqual(@as(u64, 10), mi.files[0].length);
    try std.testing.expectEqual(@as(usize, 60), mi.pieces.len); // 3 × 20
    try std.testing.expectEqual(@as(u64, 4), mi.piece_length);

    // raw_info must re-decode to a dict carrying the expected fields, and the
    // info-hash is the SHA-1 of those bytes (deterministic).
    const decoded = try bencode.decode(allocator, mi.raw_info);
    defer decoded.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 10), decoded.dictGet("length").?.asInt().?);
    try std.testing.expectEqualStrings("data.bin", decoded.dictGet("name").?.asString().?);
    const ih = infoHash(mi.raw_info);
    try std.testing.expectEqual(@as(usize, 20), ih.len);
}

test "buildTorrent: single file re-parses with trackers + matching info-hash" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "data.bin", .data = "0123456789" });
    const path = try tmp.dir.realpathAlloc(allocator, "data.bin");
    defer allocator.free(path);

    const trackers = [_][]const u8{ "http://t.example/announce", "udp://t2.example:6969" };
    const res = try buildTorrent(allocator, path, .{
        .piece_length = 4,
        .trackers = &trackers,
        .comment = "hello",
        .created_by = "carl",
        .creation_date = 1000,
    });
    defer allocator.free(res.data);

    try std.testing.expectEqual(@as(u64, 10), res.total_length);
    try std.testing.expectEqual(@as(usize, 1), res.file_count);

    // The bytes must re-parse (parse rejects unsorted dict keys, so this also
    // proves canonical key ordering throughout).
    const mi = try parse(allocator, res.data);
    defer mi.deinit(allocator);
    try std.testing.expectEqualStrings("data.bin", mi.name);
    try std.testing.expectEqualStrings("http://t.example/announce", mi.announce);
    try std.testing.expectEqual(@as(usize, 1), mi.files.len);
    try std.testing.expectEqual(@as(u64, 10), mi.files[0].length);
    try std.testing.expectEqual(@as(usize, 60), mi.pieces.len); // 3 pieces × 20
    try std.testing.expectEqualStrings("hello", mi.comment.?);
    try std.testing.expectEqual(@as(i64, 1000), mi.creation_date.?);
    try std.testing.expectEqualStrings("carl", mi.created_by.?);

    // info-hash reported by buildTorrent matches the parsed info dict's hash.
    const ih = infoHash(mi.raw_info);
    try std.testing.expectEqualSlices(u8, &res.info_hash, &ih);
}

test "buildTorrent: directory hashes pieces continuously across files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("d/sub");
    try tmp.dir.writeFile(.{ .sub_path = "d/a.txt", .data = "AAAA" }); // 4 bytes
    try tmp.dir.writeFile(.{ .sub_path = "d/sub/b.txt", .data = "BBBBBB" }); // 6 bytes
    const path = try tmp.dir.realpathAlloc(allocator, "d");
    defer allocator.free(path);

    // 10 bytes total, piece_length 4 → 3 pieces; the 2nd piece spans a.txt→b.txt.
    const res = try buildTorrent(allocator, path, .{ .piece_length = 4, .created_by = null });
    defer allocator.free(res.data);

    try std.testing.expectEqual(@as(u64, 10), res.total_length);
    try std.testing.expectEqual(@as(usize, 2), res.file_count);

    const mi = try parse(allocator, res.data);
    defer mi.deinit(allocator);
    try std.testing.expectEqualStrings("d", mi.name);
    try std.testing.expectEqual(@as(usize, 60), mi.pieces.len); // 3 pieces × 20
    try std.testing.expectEqual(@as(usize, 2), mi.files.len);
    // Files sorted by path: "a.txt" before "sub/b.txt".
    try std.testing.expectEqual(@as(usize, 1), mi.files[0].path.len);
    try std.testing.expectEqualStrings("a.txt", mi.files[0].path[0]);
    try std.testing.expectEqual(@as(u64, 4), mi.files[0].length);
    try std.testing.expectEqual(@as(usize, 2), mi.files[1].path.len);
    try std.testing.expectEqualStrings("sub", mi.files[1].path[0]);
    try std.testing.expectEqualStrings("b.txt", mi.files[1].path[1]);
    try std.testing.expectEqual(@as(u64, 6), mi.files[1].length);
    try std.testing.expect(mi.created_by == null);
}

test "buildTorrent: trackerless single file omits announce" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "x.bin", .data = "abcd" });
    const path = try tmp.dir.realpathAlloc(allocator, "x.bin");
    defer allocator.free(path);

    const res = try buildTorrent(allocator, path, .{ .piece_length = 4 });
    defer allocator.free(res.data);
    const mi = try parse(allocator, res.data);
    defer mi.deinit(allocator);
    try std.testing.expectEqualStrings("", mi.announce); // no tracker
    try std.testing.expect(mi.announce_list == null);
}

test "buildTorrent: empty directory rejects" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("empty");
    const path = try tmp.dir.realpathAlloc(allocator, "empty");
    defer allocator.free(path);
    try std.testing.expectError(error.InvalidTorrent, buildTorrent(allocator, path, .{}));
}

test "parse single-file torrent" {
    const allocator = std.testing.allocator;

    const torrent =
        "d8:announce35:http://tracker.example.com/announce" ++
        "4:infod6:lengthi1024e4:name8:test.txt12:piece lengthi262144e6:pieces20:AAAAAAAAAAAAAAAAAAAAee";

    const mi = try parse(allocator, torrent);
    defer mi.deinit(allocator);

    try std.testing.expectEqualStrings("http://tracker.example.com/announce", mi.announce);
    try std.testing.expectEqualStrings("test.txt", mi.name);
    try std.testing.expectEqual(@as(u64, 262144), mi.piece_length);
    try std.testing.expectEqual(@as(usize, 20), mi.pieces.len);
    try std.testing.expectEqual(@as(usize, 1), mi.files.len);
    try std.testing.expectEqual(@as(u64, 1024), mi.files[0].length);
    try std.testing.expectEqualStrings("test.txt", mi.files[0].path[0]);
    try std.testing.expect(mi.comment == null);
}

test "parse multi-file torrent" {
    const allocator = std.testing.allocator;

    const torrent =
        "d8:announce35:http://tracker.example.com/announce" ++
        "4:infod5:filesld6:lengthi100e4:pathl3:dir8:file.txteed6:lengthi200e4:pathl9:other.txteee" ++
        "4:name7:my_data12:piece lengthi262144e6:pieces20:BBBBBBBBBBBBBBBBBBBBee";

    const mi = try parse(allocator, torrent);
    defer mi.deinit(allocator);

    try std.testing.expectEqualStrings("my_data", mi.name);
    try std.testing.expectEqual(@as(usize, 2), mi.files.len);
    try std.testing.expectEqual(@as(u64, 100), mi.files[0].length);
    try std.testing.expectEqual(@as(usize, 2), mi.files[0].path.len);
    try std.testing.expectEqualStrings("dir", mi.files[0].path[0]);
    try std.testing.expectEqualStrings("file.txt", mi.files[0].path[1]);
    try std.testing.expectEqual(@as(u64, 200), mi.files[1].length);
    try std.testing.expectEqualStrings("other.txt", mi.files[1].path[0]);
}

test "info_hash computation" {
    const allocator = std.testing.allocator;

    const torrent =
        "d8:announce35:http://tracker.example.com/announce" ++
        "4:infod6:lengthi1024e4:name8:test.txt12:piece lengthi262144e6:pieces20:AAAAAAAAAAAAAAAAAAAAee";

    const mi = try parse(allocator, torrent);
    defer mi.deinit(allocator);

    const hash = infoHash(mi.raw_info);
    try std.testing.expectEqual(@as(usize, 20), hash.len);
    const hash2 = infoHash(mi.raw_info);
    try std.testing.expectEqualSlices(u8, &hash, &hash2);
}

test "torrent without announce succeeds with empty announce" {
    const allocator = std.testing.allocator;
    // Modern torrents may lack "announce" -- should parse successfully
    const mi = try parse(allocator, "d4:infod6:lengthi1e4:name4:test12:piece lengthi1e6:pieces0:ee");
    defer mi.deinit(allocator);
    try std.testing.expectEqualStrings("", mi.announce);
}

test "missing info rejects" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MissingField, parse(allocator, "d8:announce3:fooe"));
}
