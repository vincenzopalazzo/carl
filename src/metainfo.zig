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

    const announce_val = root.dictGet("announce") orelse return error.MissingField;
    const announce_str = announce_val.asString() orelse return error.InvalidTorrent;
    const announce = allocator.dupe(u8, announce_str) catch return error.OutOfMemory;
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

// --- Tests ---

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

test "missing announce rejects" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MissingField, parse(allocator, "d4:infod6:lengthi1e4:name4:test12:piece lengthi1e6:pieces0:ee"));
}
