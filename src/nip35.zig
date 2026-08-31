//! NIP-35: Torrents.
//!
//! Kind 2003 — torrent index. Tags carry the infohash (`x`), title, file list,
//! and tracker URLs. Carl's seeders publish these so other carls (or any
//! NIP-35 client) can discover torrents by name/infohash on Nostr relays.
//!
//! Spec: https://github.com/nostr-protocol/nips/blob/master/35.md

const std = @import("std");
const Allocator = std.mem.Allocator;
const nostr = @import("nostr.zig");
const metainfo_mod = @import("metainfo.zig");
const secp = @import("secp.zig");

const log = std.log.scoped(.nip35);

pub const kind_torrent: u32 = 2003;

pub const Error = error{
    InvalidEvent,
    MissingInfoHash,
    InvalidInfoHash,
    OutOfMemory,
};

/// A parsed kind-2003 event. Owns its strings.
pub const TorrentEntry = struct {
    info_hash: [20]u8,
    title: []const u8,
    files: []File,
    trackers: []const []const u8,
    description: []const u8,
    pubkey: [32]u8,
    created_at: i64,
    event_id: [32]u8,

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
    }
};

/// Build a signed kind-2003 event from a parsed metainfo + computed infohash.
/// The event is signed under `sk` and returned with all fields populated.
pub fn buildFromMetainfo(
    io: std.Io,
    allocator: Allocator,
    sk: secp.SecretKey,
    pk: secp.PublicKey,
    meta: metainfo_mod.Metainfo,
    info_hash: [20]u8,
    description: []const u8,
) !nostr.Event {
    var tag_list: std.ArrayList(nostr.Tag) = .empty;
    errdefer freeTagList(allocator, &tag_list);

    // x: infohash hex (NIP-35 uses "x" specifically for V1 btih).
    var infohash_hex: [40]u8 = undefined;
    secp.toHex(&info_hash, &infohash_hex);
    try appendTag(allocator, &tag_list, &[_][]const u8{ "x", &infohash_hex });

    // title
    try appendTag(allocator, &tag_list, &[_][]const u8{ "title", meta.name });

    // file entries
    for (meta.files) |f| {
        const joined = try joinPath(allocator, f.path);
        defer allocator.free(joined);
        var size_buf: [24]u8 = undefined;
        const size_str = std.fmt.bufPrint(&size_buf, "{d}", .{f.length}) catch unreachable;
        try appendTag(allocator, &tag_list, &[_][]const u8{ "file", joined, size_str });
    }

    // tracker URLs from announce / announce-list
    if (meta.announce.len > 0) {
        try appendTag(allocator, &tag_list, &[_][]const u8{ "tracker", meta.announce });
    }
    if (meta.announce_list) |tiers| {
        for (tiers) |tier| {
            for (tier) |url| {
                if (std.mem.eql(u8, url, meta.announce)) continue;
                try appendTag(allocator, &tag_list, &[_][]const u8{ "tracker", url });
            }
        }
    }

    const tags_owned = tag_list.toOwnedSlice(allocator) catch return error.OutOfMemory;
    errdefer {
        for (tags_owned) |t| t.deinit(allocator);
        allocator.free(tags_owned);
    }

    const content_dup = try allocator.dupe(u8, description);
    errdefer allocator.free(content_dup);

    var ev: nostr.Event = .{
        .id = undefined,
        .pubkey = pk,
        .created_at = std.Io.Clock.real.now(io).toSeconds(),
        .kind = kind_torrent,
        .tags = tags_owned,
        .content = content_dup,
        .sig = undefined,
    };
    // Propagate `nostr.sign`'s real error rather than collapsing every cause
    // into OutOfMemory — BadSignature, InvalidJson, etc. are meaningful for
    // the caller and they were getting hidden by the catch.
    try nostr.sign(&ev, sk, allocator);
    return ev;
}

/// Parse a kind-2003 event into a TorrentEntry. The event is assumed to have
/// already been signature-verified by the caller.
pub fn parseEvent(allocator: Allocator, event: nostr.Event) Error!TorrentEntry {
    if (event.kind != kind_torrent) return error.InvalidEvent;

    // x: required.
    const x = event.firstTagValue("x") orelse return error.MissingInfoHash;
    if (x.len != 40) return error.InvalidInfoHash;
    var info_hash: [20]u8 = undefined;
    secp.fromHex(x, &info_hash) catch return error.InvalidInfoHash;

    const title_src = event.firstTagValue("title") orelse "";

    // Files + trackers: collect all matching tags.
    var files: std.ArrayList(TorrentEntry.File) = .empty;
    errdefer {
        for (files.items) |f| allocator.free(f.path);
        files.deinit(allocator);
    }
    var trackers: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (trackers.items) |t| allocator.free(t);
        trackers.deinit(allocator);
    }

    for (event.tags) |t| {
        if (t.items.len == 0) continue;
        if (std.mem.eql(u8, t.items[0], "file") and t.items.len >= 3) {
            const size = std.fmt.parseUnsigned(u64, t.items[2], 10) catch continue;
            const path_dup = allocator.dupe(u8, t.items[1]) catch return error.OutOfMemory;
            files.append(allocator, .{ .path = path_dup, .size = size }) catch {
                allocator.free(path_dup);
                return error.OutOfMemory;
            };
        } else if (std.mem.eql(u8, t.items[0], "tracker") and t.items.len >= 2) {
            const dup = allocator.dupe(u8, t.items[1]) catch return error.OutOfMemory;
            trackers.append(allocator, dup) catch {
                allocator.free(dup);
                return error.OutOfMemory;
            };
        }
    }

    const files_slice = files.toOwnedSlice(allocator) catch return error.OutOfMemory;
    errdefer {
        for (files_slice) |f| allocator.free(f.path);
        allocator.free(files_slice);
    }
    const trackers_slice = trackers.toOwnedSlice(allocator) catch return error.OutOfMemory;
    errdefer {
        for (trackers_slice) |t| allocator.free(t);
        allocator.free(trackers_slice);
    }

    const title_dup = allocator.dupe(u8, title_src) catch return error.OutOfMemory;
    errdefer allocator.free(title_dup);

    const description_dup = allocator.dupe(u8, event.content) catch return error.OutOfMemory;

    return .{
        .info_hash = info_hash,
        .title = title_dup,
        .files = files_slice,
        .trackers = trackers_slice,
        .description = description_dup,
        .pubkey = event.pubkey,
        .created_at = event.created_at,
        .event_id = event.id,
    };
}

/// Build a magnet URI for the entry's infohash + trackers.
/// Caller owns the returned slice.
pub fn magnetUri(allocator: Allocator, entry: TorrentEntry) Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "magnet:?xt=urn:btih:");
    var infohash_hex: [40]u8 = undefined;
    secp.toHex(&entry.info_hash, &infohash_hex);
    try buf.appendSlice(allocator, &infohash_hex);

    if (entry.title.len > 0) {
        try buf.appendSlice(allocator, "&dn=");
        try urlEncode(allocator, &buf, entry.title);
    }
    for (entry.trackers) |t| {
        try buf.appendSlice(allocator, "&tr=");
        try urlEncode(allocator, &buf, t);
    }
    return buf.toOwnedSlice(allocator) catch error.OutOfMemory;
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

fn freeTagList(allocator: Allocator, list: *std.ArrayList(nostr.Tag)) void {
    for (list.items) |t| t.deinit(allocator);
    list.deinit(allocator);
}

fn appendTag(
    allocator: Allocator,
    list: *std.ArrayList(nostr.Tag),
    parts: []const []const u8,
) !void {
    var items: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (items.items) |s| allocator.free(s);
        items.deinit(allocator);
    }
    for (parts) |p| {
        const dup = try allocator.dupe(u8, p);
        items.append(allocator, dup) catch {
            allocator.free(dup);
            return error.OutOfMemory;
        };
    }
    const slice = items.toOwnedSlice(allocator) catch return error.OutOfMemory;
    list.append(allocator, .{ .items = slice }) catch {
        for (slice) |s| allocator.free(s);
        allocator.free(slice);
        return error.OutOfMemory;
    };
}

fn joinPath(allocator: Allocator, components: []const []const u8) ![]u8 {
    var total: usize = 0;
    for (components, 0..) |c, i| {
        total += c.len;
        if (i + 1 < components.len) total += 1;
    }
    var out = try allocator.alloc(u8, total);
    var off: usize = 0;
    for (components, 0..) |c, i| {
        @memcpy(out[off..][0..c.len], c);
        off += c.len;
        if (i + 1 < components.len) {
            out[off] = '/';
            off += 1;
        }
    }
    return out;
}

fn urlEncode(allocator: Allocator, buf: *std.ArrayList(u8), s: []const u8) Error!void {
    const hex = "0123456789ABCDEF";
    for (s) |b| {
        const safe = switch (b) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => true,
            else => false,
        };
        if (safe) {
            buf.append(allocator, b) catch return error.OutOfMemory;
        } else {
            buf.append(allocator, '%') catch return error.OutOfMemory;
            buf.append(allocator, hex[b >> 4]) catch return error.OutOfMemory;
            buf.append(allocator, hex[b & 0x0F]) catch return error.OutOfMemory;
        }
    }
}

// ===========================================================================
// Tests
// ===========================================================================

test "buildFromMetainfo + parseEvent round trip" {
    const allocator = std.testing.allocator;

    var sk: secp.SecretKey = undefined;
    try secp.fromHex("0000000000000000000000000000000000000000000000000000000000000003", &sk);
    const pk = try secp.publicKeyFromSecret(sk);

    // Synthetic metainfo.
    var path_components = [_][]const u8{"movie.mkv"};
    var files = [_]metainfo_mod.FileInfo{.{ .length = 2_147_483_648, .path = &path_components }};
    const meta: metainfo_mod.Metainfo = .{
        .announce = "http://tracker.example.com",
        .announce_list = null,
        .name = "Test Movie",
        .piece_length = 524288,
        .pieces = &.{},
        .files = &files,
        .comment = null,
        .creation_date = null,
        .created_by = null,
        .raw_info = &.{},
        .url_list = null,
    };

    var info_hash: [20]u8 = undefined;
    @memset(&info_hash, 0xAB);

    var ev = try buildFromMetainfo(
        std.testing.io,
        allocator,
        sk,
        pk,
        meta,
        info_hash,
        "a description",
    );
    defer ev.deinit(allocator);

    try std.testing.expect(nostr.verify(ev, allocator));

    const entry = try parseEvent(allocator, ev);
    defer entry.deinit(allocator);

    try std.testing.expectEqualSlices(u8, &info_hash, &entry.info_hash);
    try std.testing.expectEqualStrings("Test Movie", entry.title);
    try std.testing.expectEqualStrings("a description", entry.description);
    try std.testing.expectEqual(@as(usize, 1), entry.files.len);
    try std.testing.expectEqualStrings("movie.mkv", entry.files[0].path);
    try std.testing.expectEqual(@as(u64, 2_147_483_648), entry.files[0].size);
    try std.testing.expectEqual(@as(usize, 1), entry.trackers.len);
    try std.testing.expectEqualStrings("http://tracker.example.com", entry.trackers[0]);
}

test "parseEvent rejects wrong kind" {
    const allocator = std.testing.allocator;

    var ev: nostr.Event = .{
        .id = undefined,
        .pubkey = undefined,
        .created_at = 0,
        .kind = 1,
        .tags = &.{},
        .content = "",
        .sig = undefined,
    };
    @memset(&ev.id, 0);
    @memset(&ev.pubkey, 0);
    @memset(&ev.sig, 0);

    try std.testing.expectError(error.InvalidEvent, parseEvent(allocator, ev));
}

test "parseEvent rejects missing infohash tag" {
    const allocator = std.testing.allocator;
    var ev: nostr.Event = .{
        .id = undefined,
        .pubkey = undefined,
        .created_at = 0,
        .kind = kind_torrent,
        .tags = &.{},
        .content = "",
        .sig = undefined,
    };
    @memset(&ev.id, 0);
    @memset(&ev.pubkey, 0);
    @memset(&ev.sig, 0);
    try std.testing.expectError(error.MissingInfoHash, parseEvent(allocator, ev));
}

test "magnetUri encoding" {
    const allocator = std.testing.allocator;
    var info_hash: [20]u8 = undefined;
    @memset(&info_hash, 0xCD);

    var trackers = [_][]const u8{"http://t.example.com/announce"};
    const entry: TorrentEntry = .{
        .info_hash = info_hash,
        .title = "A Movie",
        .files = &.{},
        .trackers = &trackers,
        .description = "",
        .pubkey = .{0} ** 32,
        .created_at = 0,
        .event_id = .{0} ** 32,
    };

    const uri = try magnetUri(allocator, entry);
    defer allocator.free(uri);

    try std.testing.expectEqualStrings(
        "magnet:?xt=urn:btih:cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd&dn=A%20Movie&tr=http%3A%2F%2Ft.example.com%2Fannounce",
        uri,
    );
}
