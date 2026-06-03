//! Carl torrent index JSON on Pubky homeservers (`/pub/carl.app/torrents/{infohash}.json`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const secp = @import("secp.zig");
const metainfo_mod = @import("metainfo.zig");

pub const Error = error{
    InvalidJson,
    MissingInfoHash,
    InvalidInfoHash,
    OutOfMemory,
};

pub const TorrentEntry = struct {
    info_hash: [20]u8,
    title: []const u8,
    files: []File,
    trackers: []const []const u8,
    description: []const u8,
    pubky_z32: []const u8,
    created_at: i64,

    pub const File = struct {
        path: []const u8,
        size: u64,
    };

    pub fn deinit(self: TorrentEntry, allocator: Allocator) void {
        allocator.free(self.title);
        for (self.files) |f| allocator.free(f.path);
        allocator.free(self.files);
        for (self.trackers) |t| allocator.free(t);
        allocator.free(self.trackers);
        allocator.free(self.description);
        allocator.free(self.pubky_z32);
    }
};

pub fn torrentPath(info_hash: [20]u8, buf: *[80]u8) []const u8 {
    var ih_hex: [40]u8 = undefined;
    secp.toHex(&info_hash, &ih_hex);
    return std.fmt.bufPrint(buf, "/pub/carl.app/torrents/{s}.json", .{&ih_hex}) catch unreachable;
}

pub fn buildJson(
    allocator: Allocator,
    meta: metainfo_mod.Metainfo,
    info_hash: [20]u8,
    description: []const u8,
    pubky_z32: []const u8,
) ![]u8 {
    var ih_hex: [40]u8 = undefined;
    secp.toHex(&info_hash, &ih_hex);

    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);
    const w = list.writer(allocator);

    try w.print("{{\"info_hash\":\"{s}\",\"title\":\"", .{&ih_hex});
    try jsonEscapeAppend(w, meta.name);
    try w.writeAll("\",\"description\":\"");
    try jsonEscapeAppend(w, description);
    try w.print("\",\"client\":\"carl/0.1\",\"created_at\":{d},\"pubky\":\"", .{std.time.timestamp()});
    try jsonEscapeAppend(w, pubky_z32);
    try w.writeAll("\",\"files\":[");
    for (meta.files, 0..) |f, i| {
        if (i > 0) try w.writeAll(",");
        const joined = try joinPath(allocator, f.path);
        defer allocator.free(joined);
        try w.writeAll("{\"path\":\"");
        try jsonEscapeAppend(w, joined);
        try w.print("\",\"size\":{d}}}", .{f.length});
    }
    try w.writeAll("],\"trackers\":[");
    var first_tracker = true;
    if (meta.announce.len > 0) {
        try w.writeAll("\"");
        try jsonEscapeAppend(w, meta.announce);
        try w.writeAll("\"");
        first_tracker = false;
    }
    if (meta.announce_list) |tiers| {
        for (tiers) |tier| {
            for (tier) |url| {
                if (meta.announce.len > 0 and std.mem.eql(u8, url, meta.announce)) continue;
                if (!first_tracker) try w.writeAll(",");
                try w.writeAll("\"");
                try jsonEscapeAppend(w, url);
                try w.writeAll("\"");
                first_tracker = false;
            }
        }
    }
    try w.writeAll("]}");
    return list.toOwnedSlice(allocator);
}

pub fn parseJson(allocator: Allocator, text: []const u8, pubky_z32: []const u8) Error!TorrentEntry {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    const obj = parsed.value.object;

    const ih_str = getString(&obj, "info_hash") orelse return error.MissingInfoHash;
    if (ih_str.len != 40) return error.InvalidInfoHash;
    var info_hash: [20]u8 = undefined;
    secp.fromHex(ih_str, &info_hash) catch return error.InvalidInfoHash;

    const title = try dupString(allocator, getString(&obj, "title") orelse "");
    errdefer allocator.free(title);
    const description = try dupString(allocator, getString(&obj, "content") orelse getString(&obj, "description") orelse "");
    errdefer allocator.free(description);

    var files: std.ArrayList(TorrentEntry.File) = .empty;
    errdefer {
        for (files.items) |f| allocator.free(f.path);
        files.deinit(allocator);
    }
    if (obj.get("files")) |files_val| {
        if (files_val == .array) {
            for (files_val.array.items) |item| {
                if (item != .object) continue;
                const path = getString(&item.object, "path") orelse continue;
                const size = getU64(&item.object, "size") orelse continue;
                const path_dup = try allocator.dupe(u8, path);
                try files.append(allocator, .{ .path = path_dup, .size = size });
            }
        }
    }

    var trackers: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (trackers.items) |t| allocator.free(t);
        trackers.deinit(allocator);
    }
    if (obj.get("trackers")) |tr_val| {
        if (tr_val == .array) {
            for (tr_val.array.items) |item| {
                if (item != .string) continue;
                const dup = try allocator.dupe(u8, item.string);
                try trackers.append(allocator, dup);
            }
        }
    }

    const z32_src = getString(&obj, "pubky") orelse pubky_z32;
    const z32_dup = try allocator.dupe(u8, z32_src);

    return .{
        .info_hash = info_hash,
        .title = title,
        .files = try files.toOwnedSlice(allocator),
        .trackers = try trackers.toOwnedSlice(allocator),
        .description = description,
        .pubky_z32 = z32_dup,
        .created_at = getI64(&obj, "created_at") orelse 0,
    };
}

fn getString(obj: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn getU64(obj: *const std.json.ObjectMap, key: []const u8) ?u64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn getI64(obj: *const std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}

fn dupString(allocator: Allocator, s: []const u8) Error![]const u8 {
    return try allocator.dupe(u8, s);
}

fn joinPath(allocator: Allocator, parts: []const []const u8) ![]const u8 {
    if (parts.len == 0) return try allocator.dupe(u8, "");
    if (parts.len == 1) return try allocator.dupe(u8, parts[0]);
    var total: usize = 0;
    for (parts, 0..) |p, i| {
        total += p.len;
        if (i + 1 < parts.len) total += 1;
    }
    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);
    var off: usize = 0;
    for (parts, 0..) |p, i| {
        @memcpy(out[off..][0..p.len], p);
        off += p.len;
        if (i + 1 < parts.len) {
            out[off] = '/';
            off += 1;
        }
    }
    return out;
}

fn jsonEscapeAppend(writer: anytype, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(c),
    };
}

test "torrentPath format" {
    var ih: [20]u8 = undefined;
    @memset(&ih, 0xab);
    var buf: [80]u8 = undefined;
    const p = torrentPath(ih, &buf);
    try std.testing.expect(std.mem.startsWith(u8, p, "/pub/carl.app/torrents/"));
}
