//! Pubky Nexus REST client for discovering Carl torrent index files.

const std = @import("std");
const Allocator = std.mem.Allocator;
const pubky_torrent = @import("pubky_torrent.zig");
const pubky_ffi = @import("pubky_ffi.zig");

const log = std.log.scoped(.nexus);

pub const Error = error{
    HttpFailed,
    InvalidJson,
    InvalidUri,
    OutOfMemory,
};

/// A torrent hit from Nexus or direct homeserver fetch.
pub const Hit = struct {
    entry: pubky_torrent.TorrentEntry,
    url: []const u8,

    pub fn deinit(self: Hit, allocator: Allocator) void {
        self.entry.deinit(allocator);
        allocator.free(self.url);
    }
};

/// Search Nexus for Carl torrent JSON. Tries several v0 endpoints; returns empty on failure.
pub fn searchTorrents(
    allocator: Allocator,
    nexus_base: []const u8,
    query: []const u8,
    limit: u32,
) Error![]Hit {
    var out: std.ArrayList(Hit) = .empty;
    errdefer {
        for (out.items) |h| h.deinit(allocator);
        out.deinit(allocator);
    }

    const url_primary = std.fmt.allocPrint(allocator, "{s}/v0/files/search?search_term={s}&limit={d}", .{ nexus_base, query, limit }) catch return error.OutOfMemory;
    defer allocator.free(url_primary);

    for (&[_][]const u8{url_primary}) |url| {
        const body = fetchGet(allocator, url) catch continue;
        defer allocator.free(body);

        const added = try parseSearchResponse(allocator, body, query, limit, &out);
        if (added > 0) return out.toOwnedSlice(allocator);
    }

    log.warn("nexus search returned no carl torrents for '{s}'", .{query});
    return out.toOwnedSlice(allocator);
}

/// Fetch announce JSON URLs for a given infohash via Nexus file search.
pub fn searchAnnouncesForInfohash(
    allocator: Allocator,
    nexus_base: []const u8,
    info_hash: [20]u8,
    limit: u32,
) Error![][]const u8 {
    var ih_hex: [40]u8 = undefined;
    @import("secp.zig").toHex(&info_hash, &ih_hex);

    const url = try std.fmt.allocPrint(allocator, "{s}/v0/files/search?search_term={s}&limit={d}", .{ nexus_base, &ih_hex, limit });
    defer allocator.free(url);

    const body = fetchGet(allocator, url) catch return error.HttpFailed;
    defer allocator.free(body);

    var urls: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (urls.items) |u| allocator.free(u);
        urls.deinit(allocator);
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidJson;
    defer parsed.deinit();

    try collectAnnounceUrls(allocator, parsed.value, &ih_hex, &urls);
    return urls.toOwnedSlice(allocator);
}

fn parseSearchResponse(
    allocator: Allocator,
    body: []const u8,
    query: []const u8,
    limit: u32,
    out: *std.ArrayList(Hit),
) Error!u32 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidJson;
    defer parsed.deinit();

    var added: u32 = 0;
    const items = extractItems(parsed.value);
    for (items) |item| {
        if (added >= limit) break;
        const url = extractUrl(item) orelse continue;
        if (std.mem.indexOf(u8, url, "/pub/carl.app/torrents/") == null) continue;
        const content = pubky_ffi.get(allocator, url) catch continue;
        defer allocator.free(content);
        const entry = pubky_torrent.parseJson(allocator, content, "") catch continue;
        if (!textMatches(entry.title, query) and !textMatches(entry.description, query)) {
            entry.deinit(allocator);
            continue;
        }
        const url_dup = try allocator.dupe(u8, url);
        try out.append(allocator, .{ .entry = entry, .url = url_dup });
        added += 1;
    }
    return added;
}

fn extractItems(root: std.json.Value) []const std.json.Value {
    return switch (root) {
        .array => |a| a.items,
        .object => |o| blk: {
            if (o.get("files")) |f| {
                if (f == .array) break :blk f.array.items;
            }
            if (o.get("data")) |d| {
                if (d == .array) break :blk d.array.items;
                if (d == .object) {
                    if (d.object.get("files")) |ff| {
                        if (ff == .array) break :blk ff.array.items;
                    }
                }
            }
            if (o.get("results")) |r| {
                if (r == .array) break :blk r.array.items;
            }
            break :blk &[_]std.json.Value{};
        },
        else => &[_]std.json.Value{},
    };
}

fn extractUrl(item: std.json.Value) ?[]const u8 {
    if (item != .object) return null;
    const o = item.object;
    if (o.get("url")) |u| return switch (u) {
        .string => |s| s,
        else => null,
    };
    if (o.get("file_url")) |u| return switch (u) {
        .string => |s| s,
        else => null,
    };
    return null;
}

fn collectAnnounceUrls(allocator: Allocator, root: std.json.Value, ih_hex: []const u8, out: *std.ArrayList([]const u8)) Error!void {
    for (extractItems(root)) |item| {
        const url = extractUrl(item) orelse continue;
        if (std.mem.indexOf(u8, url, "/pub/carl.app/announces/") == null) continue;
        if (std.mem.indexOf(u8, url, ih_hex) == null) continue;
        const dup = try allocator.dupe(u8, url);
        try out.append(allocator, dup);
    }
}

fn fetchGet(allocator: Allocator, url: []const u8) ![]const u8 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    var adapt_buf: [4096]u8 = undefined;
    const deprecated_writer = body.writer(allocator);
    var adapter = deprecated_writer.adaptToNewApi(&adapt_buf);

    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &adapter.new_interface,
    }) catch return error.HttpFailed;

    const buffered = adapter.new_interface.buffered();
    if (buffered.len > 0) {
        try body.appendSlice(allocator, buffered);
    }

    if (result.status != .ok) return error.HttpFailed;
    return body.toOwnedSlice(allocator);
}

fn textMatches(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    const max_off = haystack.len - needle.len + 1;
    var off: usize = 0;
    while (off < max_off) : (off += 1) {
        var match = true;
        for (needle, 0..) |n, i| {
            const h = std.ascii.toLower(haystack[off + i]);
            const l = std.ascii.toLower(n);
            if (h != l) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

test "textMatches" {
    try std.testing.expect(textMatches("Ubuntu ISO", "ubuntu"));
    try std.testing.expect(!textMatches("debian", "ubuntu"));
}
