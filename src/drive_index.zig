//! Carl's shared-drive "drive index" event — kind 30035, a NIP-33
//! parameterized replaceable event.
//!
//! One of these exists per (author, drive): it maps every file path in a
//! shared drive to the V1 infohash of the torrent carrying that file, plus
//! the file's size and mtime. The `d` tag is namespaced `carl-drive:<name>`
//! so a drive index can never collide with kind-30078 peer-announces (NIP-33
//! replacement is keyed on pubkey + kind + d, but the explicit namespace
//! keeps the address human-readable and unambiguous across kinds).
//!
//! Tag schema (content is empty):
//!   ["d", "carl-drive:<name>"],
//!   ["file", "<path>", "<infohash_hex>", "<size_dec>", "<mtime_dec>"], ...
//!
//! Paths are relative, '/'-separated, and validated (no absolute paths, no
//! '\', no NUL, no empty/'.'/'..' components, 512-byte cap) so a malicious
//! publisher cannot make a subscriber write outside the drive directory.
//!
//! NIP-33 semantics: relays and subscribers keep only the newest `created_at`
//! per (pubkey, d). A subscriber MUST reject regressions — a drive-index
//! event whose `created_at` is not strictly newer than the one it already
//! holds is stale and must be dropped. Publishers persist their last
//! `created_at` and pass a monotone-increasing value into `build` (the
//! timestamp is a parameter precisely so this invariant survives restarts).
//!
//! `diff` gives subscribers convergence: from an old index and a freshly
//! parsed one it computes added/changed/removed paths, and detects renames
//! (same infohash at a new path) so unchanged content is not re-downloaded.

const std = @import("std");
const Allocator = std.mem.Allocator;
const nostr = @import("nostr.zig");
const secp = @import("secp.zig");

const log = std.log.scoped(.drive_index);

pub const kind_drive_index: u32 = 30035;

/// Namespace prepended to the drive name in the `d` tag.
pub const d_prefix: []const u8 = "carl-drive:";

/// Relay event-size guard: more files than this in one index is rejected.
pub const max_files: usize = 2048;

/// Longest accepted file path, in bytes.
pub const max_path_len: usize = 512;

pub const Error = error{
    InvalidEvent,
    MissingD,
    InvalidD,
    InvalidPath,
    DuplicatePath,
    InvalidInfoHash,
    InvalidSize,
    InvalidMtime,
    TooManyFiles,
    OutOfMemory,
};

pub const FileEntry = struct {
    /// Relative, '/'-separated, validated with `validatePath`.
    path: []const u8,
    info_hash: [20]u8,
    size: u64,
    mtime: i64,
};

/// A parsed kind-30035 drive index. Owns its strings;
/// `deinit(allocator)` frees everything.
pub const Index = struct {
    /// The `<name>` after `d_prefix` in the `d` tag.
    drive: []const u8,
    files: []FileEntry,
    pubkey: [32]u8,
    created_at: i64,
    event_id: [32]u8,

    pub fn deinit(self: Index, allocator: Allocator) void {
        allocator.free(self.drive);
        for (self.files) |f| allocator.free(f.path);
        allocator.free(self.files);
    }

    /// Look up a file by exact path.
    pub fn find(self: *const Index, path: []const u8) ?*const FileEntry {
        for (self.files) |*f| {
            if (std.mem.eql(u8, f.path, path)) return f;
        }
        return null;
    }
};

/// Build and sign a kind-30035 drive-index event.
///
/// `created_at` is a parameter, not read from the clock: the publisher
/// persists its last published timestamp and must pass a value that is
/// strictly newer, or subscribers (and NIP-33 relays) will treat the event
/// as a regression and drop it.
///
/// Caller owns the returned event (`ev.deinit(allocator)`), same as
/// `nip35.buildFromMetainfo`.
pub fn build(
    allocator: Allocator,
    sk: secp.SecretKey,
    pk: secp.PublicKey,
    drive: []const u8,
    files: []const FileEntry,
    created_at: i64,
) Error!nostr.Event {
    if (drive.len == 0) return error.InvalidD;
    if (files.len > max_files) return error.TooManyFiles;
    for (files, 0..) |f, i| {
        try validatePath(f.path);
        for (files[0..i]) |prev| {
            if (std.mem.eql(u8, prev.path, f.path)) return error.DuplicatePath;
        }
    }

    var tag_list: std.ArrayList(nostr.Tag) = .empty;
    errdefer freeTagList(allocator, &tag_list);

    const d_value = allocator.alloc(u8, d_prefix.len + drive.len) catch return error.OutOfMemory;
    defer allocator.free(d_value);
    @memcpy(d_value[0..d_prefix.len], d_prefix);
    @memcpy(d_value[d_prefix.len..], drive);
    try appendTag(allocator, &tag_list, &[_][]const u8{ "d", d_value });

    for (files) |f| {
        var infohash_hex: [40]u8 = undefined;
        secp.toHex(&f.info_hash, &infohash_hex);
        var size_buf: [24]u8 = undefined;
        const size_str = std.fmt.bufPrint(&size_buf, "{d}", .{f.size}) catch unreachable;
        var mtime_buf: [24]u8 = undefined;
        const mtime_str = std.fmt.bufPrint(&mtime_buf, "{d}", .{f.mtime}) catch unreachable;
        try appendTag(allocator, &tag_list, &[_][]const u8{ "file", f.path, &infohash_hex, size_str, mtime_str });
    }

    const tags_owned = tag_list.toOwnedSlice(allocator) catch return error.OutOfMemory;
    errdefer {
        for (tags_owned) |t| t.deinit(allocator);
        allocator.free(tags_owned);
    }
    const empty_content = allocator.dupe(u8, "") catch return error.OutOfMemory;
    errdefer allocator.free(empty_content);

    var ev: nostr.Event = .{
        .id = undefined,
        .pubkey = pk,
        .created_at = created_at,
        .kind = kind_drive_index,
        .tags = tags_owned,
        .content = empty_content,
        .sig = undefined,
    };
    nostr.sign(&ev, sk, allocator) catch return error.OutOfMemory;
    return ev;
}

/// Validate a drive-index file path: relative, '/'-separated, no escapes.
///
/// Rejects: empty paths, paths longer than `max_path_len`, a leading or
/// trailing '/', any '\' or NUL byte, and any component that is empty,
/// ".", or "..".
///
/// `storage.isValidPathComponent` covers the same ground but is private to
/// storage.zig, so these checks are implemented inline here.
pub fn validatePath(path: []const u8) Error!void {
    if (path.len == 0) return error.InvalidPath;
    if (path.len > max_path_len) return error.InvalidPath;
    if (path[0] == '/') return error.InvalidPath;
    if (path[path.len - 1] == '/') return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (comp.len == 0) return error.InvalidPath;
        if (std.mem.eql(u8, comp, ".")) return error.InvalidPath;
        if (std.mem.eql(u8, comp, "..")) return error.InvalidPath;
    }
}

/// Parse a kind-30035 event into an owned Index. The event is assumed to
/// have already been signature-verified by the caller.
pub fn parseEvent(allocator: Allocator, event: nostr.Event) Error!Index {
    if (event.kind != kind_drive_index) return error.InvalidEvent;

    const d = event.firstTagValue("d") orelse return error.MissingD;
    if (!std.mem.startsWith(u8, d, d_prefix)) return error.InvalidD;
    const drive_name = d[d_prefix.len..];
    if (drive_name.len == 0) return error.InvalidD;

    var files: std.ArrayList(FileEntry) = .empty;
    errdefer {
        for (files.items) |f| allocator.free(f.path);
        files.deinit(allocator);
    }

    for (event.tags) |t| {
        if (t.items.len == 0) continue;
        if (!std.mem.eql(u8, t.items[0], "file")) continue;
        if (t.items.len != 5) return error.InvalidEvent;
        if (files.items.len >= max_files) return error.TooManyFiles;

        const path = t.items[1];
        try validatePath(path);
        for (files.items) |prev| {
            if (std.mem.eql(u8, prev.path, path)) return error.DuplicatePath;
        }

        const hash_hex = t.items[2];
        if (hash_hex.len != 40) return error.InvalidInfoHash;
        var info_hash: [20]u8 = undefined;
        secp.fromHex(hash_hex, &info_hash) catch return error.InvalidInfoHash;

        const size = std.fmt.parseUnsigned(u64, t.items[3], 10) catch return error.InvalidSize;
        const mtime = std.fmt.parseInt(i64, t.items[4], 10) catch return error.InvalidMtime;

        const path_dup = allocator.dupe(u8, path) catch return error.OutOfMemory;
        files.append(allocator, .{
            .path = path_dup,
            .info_hash = info_hash,
            .size = size,
            .mtime = mtime,
        }) catch {
            allocator.free(path_dup);
            return error.OutOfMemory;
        };
    }

    const files_slice = files.toOwnedSlice(allocator) catch return error.OutOfMemory;
    errdefer {
        for (files_slice) |f| allocator.free(f.path);
        allocator.free(files_slice);
    }
    const drive_dup = allocator.dupe(u8, drive_name) catch return error.OutOfMemory;

    return .{
        .drive = drive_dup,
        .files = files_slice,
        .pubkey = event.pubkey,
        .created_at = event.created_at,
        .event_id = event.id,
    };
}

pub const Rename = struct {
    from: []const u8,
    to: []const u8,
};

/// The difference between two drive indexes, for subscriber convergence.
/// All path strings are owned dupes; `deinit(allocator)` frees everything.
pub const Diff = struct {
    /// Paths in new, absent from old (owned dupes).
    added: [][]const u8,
    /// Paths in both, with a different info_hash (owned dupes).
    changed: [][]const u8,
    /// Paths in old, absent from new (owned dupes).
    removed: [][]const u8,
    /// Same info_hash in removed+added: content moved, not changed (owned dupes).
    renamed: []Rename,

    pub fn deinit(self: Diff, allocator: Allocator) void {
        for (self.added) |p| allocator.free(p);
        allocator.free(self.added);
        for (self.changed) |p| allocator.free(p);
        allocator.free(self.changed);
        for (self.removed) |p| allocator.free(p);
        allocator.free(self.removed);
        for (self.renamed) |r| {
            allocator.free(r.from);
            allocator.free(r.to);
        }
        allocator.free(self.renamed);
    }
};

/// Compute what a subscriber must do to converge from `old` to `new`.
/// `old == null` means every path in `new` is added. A path that disappears
/// from `old` while its infohash reappears under a new path in `new` is
/// reported as a rename rather than a remove+add.
pub fn diff(allocator: Allocator, old: ?*const Index, new: *const Index) Error!Diff {
    var added_idx: std.ArrayList(usize) = .empty;
    defer added_idx.deinit(allocator);
    var changed_idx: std.ArrayList(usize) = .empty;
    defer changed_idx.deinit(allocator);
    var removed_idx: std.ArrayList(usize) = .empty;
    defer removed_idx.deinit(allocator);

    if (old) |o| {
        for (new.files, 0..) |f, i| {
            if (o.find(f.path)) |of| {
                if (!std.mem.eql(u8, &of.info_hash, &f.info_hash)) {
                    changed_idx.append(allocator, i) catch return error.OutOfMemory;
                }
            } else {
                added_idx.append(allocator, i) catch return error.OutOfMemory;
            }
        }
        for (o.files, 0..) |f, i| {
            if (new.find(f.path) == null) {
                removed_idx.append(allocator, i) catch return error.OutOfMemory;
            }
        }
    } else {
        for (new.files, 0..) |_, i| {
            added_idx.append(allocator, i) catch return error.OutOfMemory;
        }
    }

    // Rename detection: pair each removed path with an added path that
    // carries the same infohash. First match wins; a consumed added entry
    // cannot be renamed-to twice.
    const consumed = allocator.alloc(bool, added_idx.items.len) catch return error.OutOfMemory;
    defer allocator.free(consumed);
    @memset(consumed, false);

    var rename_pairs: std.ArrayList([2]usize) = .empty; // { old files idx, new files idx }
    defer rename_pairs.deinit(allocator);
    var kept_removed: std.ArrayList(usize) = .empty;
    defer kept_removed.deinit(allocator);

    if (old) |o| {
        for (removed_idx.items) |oi| {
            const of = o.files[oi];
            var matched = false;
            for (added_idx.items, 0..) |ni, k| {
                if (consumed[k]) continue;
                if (std.mem.eql(u8, &of.info_hash, &new.files[ni].info_hash)) {
                    consumed[k] = true;
                    matched = true;
                    rename_pairs.append(allocator, .{ oi, ni }) catch return error.OutOfMemory;
                    break;
                }
            }
            if (!matched) kept_removed.append(allocator, oi) catch return error.OutOfMemory;
        }
    }

    // Materialize owned dupes.
    var n_added: usize = 0;
    for (consumed) |c| {
        if (!c) n_added += 1;
    }

    var added_filled: usize = 0;
    const added = allocator.alloc([]const u8, n_added) catch return error.OutOfMemory;
    errdefer {
        for (added[0..added_filled]) |p| allocator.free(p);
        allocator.free(added);
    }
    for (added_idx.items, 0..) |ni, k| {
        if (consumed[k]) continue;
        added[added_filled] = allocator.dupe(u8, new.files[ni].path) catch return error.OutOfMemory;
        added_filled += 1;
    }

    var changed_filled: usize = 0;
    const changed = allocator.alloc([]const u8, changed_idx.items.len) catch return error.OutOfMemory;
    errdefer {
        for (changed[0..changed_filled]) |p| allocator.free(p);
        allocator.free(changed);
    }
    for (changed_idx.items) |ni| {
        changed[changed_filled] = allocator.dupe(u8, new.files[ni].path) catch return error.OutOfMemory;
        changed_filled += 1;
    }

    var removed_filled: usize = 0;
    const removed = allocator.alloc([]const u8, kept_removed.items.len) catch return error.OutOfMemory;
    errdefer {
        for (removed[0..removed_filled]) |p| allocator.free(p);
        allocator.free(removed);
    }
    if (old) |o| {
        for (kept_removed.items) |oi| {
            removed[removed_filled] = allocator.dupe(u8, o.files[oi].path) catch return error.OutOfMemory;
            removed_filled += 1;
        }
    }

    var renamed_filled: usize = 0;
    const renamed = allocator.alloc(Rename, rename_pairs.items.len) catch return error.OutOfMemory;
    errdefer {
        for (renamed[0..renamed_filled]) |r| {
            allocator.free(r.from);
            allocator.free(r.to);
        }
        allocator.free(renamed);
    }
    if (old) |o| {
        for (rename_pairs.items) |pair| {
            const from_dup = allocator.dupe(u8, o.files[pair[0]].path) catch return error.OutOfMemory;
            errdefer allocator.free(from_dup);
            const to_dup = allocator.dupe(u8, new.files[pair[1]].path) catch return error.OutOfMemory;
            renamed[renamed_filled] = .{ .from = from_dup, .to = to_dup };
            renamed_filled += 1;
        }
    }

    return .{
        .added = added,
        .changed = changed,
        .removed = removed,
        .renamed = renamed,
    };
}

/// Build a relay Filter selecting exactly one drive index: kind 30035 from
/// `author`, with a `#d` tag filter on `carl-drive:<drive>`.
///
/// The filter borrows from the caller-provided buffers, which must outlive
/// the returned Filter. `d_buf` must be at least `d_prefix.len + drive.len`
/// bytes. Returns null if `drive` is empty or `d_buf` is too small.
pub fn indexFilter(
    author: [32]u8,
    drive: []const u8,
    d_buf: []u8,
    author_hex_buf: *[64]u8,
    kinds_buf: *[1]u32,
    authors_buf: *[1][]const u8,
    values_buf: *[1][]const u8,
    tags_buf: *[1]nostr.Filter.TagFilter,
) ?nostr.Filter {
    if (drive.len == 0) return null;
    if (d_buf.len < d_prefix.len + drive.len) return null;
    @memcpy(d_buf[0..d_prefix.len], d_prefix);
    @memcpy(d_buf[d_prefix.len..][0..drive.len], drive);

    secp.toHex(&author, author_hex_buf);
    authors_buf[0] = author_hex_buf;
    kinds_buf[0] = kind_drive_index;
    values_buf[0] = d_buf[0 .. d_prefix.len + drive.len];
    tags_buf[0] = .{ .letter = 'd', .values = values_buf };

    return .{
        .kinds = kinds_buf,
        .authors = authors_buf,
        .tags = tags_buf,
    };
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
) Error!void {
    var items: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (items.items) |s| allocator.free(s);
        items.deinit(allocator);
    }
    for (parts) |p| {
        const dup = allocator.dupe(u8, p) catch return error.OutOfMemory;
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

// ===========================================================================
// Tests
// ===========================================================================

const test_sk_hex = "0000000000000000000000000000000000000000000000000000000000000003";
const hash40 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

fn testKeys() !struct { sk: secp.SecretKey, pk: secp.PublicKey } {
    var sk: secp.SecretKey = undefined;
    try secp.fromHex(test_sk_hex, &sk);
    const pk = try secp.publicKeyFromSecret(sk);
    return .{ .sk = sk, .pk = pk };
}

/// Build an unsigned kind-`kind` event with a `d` tag and raw `file` tags,
/// bypassing `build`'s validation so parseEvent rejection paths are testable.
fn makeRawEvent(
    allocator: Allocator,
    kind: u32,
    d_value: ?[]const u8,
    file_specs: []const []const []const u8,
) !nostr.Event {
    var tag_list: std.ArrayList(nostr.Tag) = .empty;
    errdefer freeTagList(allocator, &tag_list);
    if (d_value) |dv| try appendTag(allocator, &tag_list, &[_][]const u8{ "d", dv });
    for (file_specs) |spec| try appendTag(allocator, &tag_list, spec);
    const tags = try tag_list.toOwnedSlice(allocator);
    errdefer {
        for (tags) |t| t.deinit(allocator);
        allocator.free(tags);
    }
    return .{
        .id = .{0} ** 32,
        .pubkey = .{0} ** 32,
        .created_at = 42,
        .kind = kind,
        .tags = tags,
        .content = try allocator.dupe(u8, ""),
        .sig = .{0} ** 64,
    };
}

fn testEntry(comptime path: []const u8, comptime byte: u8, size: u64, mtime: i64) FileEntry {
    return .{ .path = path, .info_hash = .{byte} ** 20, .size = size, .mtime = mtime };
}

fn testIndex(files: []FileEntry) Index {
    return .{
        .drive = "d",
        .files = files,
        .pubkey = .{0} ** 32,
        .created_at = 0,
        .event_id = .{0} ** 32,
    };
}

test "build + parseEvent round trip" {
    const allocator = std.testing.allocator;
    const keys = try testKeys();

    const files = [_]FileEntry{
        testEntry("docs/report.pdf", 0xAB, 12345, 1_700_000_000),
        testEntry("photo.jpg", 0xCD, 777, -5),
    };
    var ev = try build(allocator, keys.sk, keys.pk, "photos", &files, 1_700_000_123);
    defer ev.deinit(allocator);

    try std.testing.expect(nostr.verify(ev, allocator));
    try std.testing.expectEqualStrings("carl-drive:photos", ev.firstTagValue("d").?);
    try std.testing.expectEqualStrings("", ev.content);

    const idx = try parseEvent(allocator, ev);
    defer idx.deinit(allocator);

    try std.testing.expectEqualStrings("photos", idx.drive);
    try std.testing.expectEqual(@as(i64, 1_700_000_123), idx.created_at);
    try std.testing.expectEqualSlices(u8, &keys.pk, &idx.pubkey);
    try std.testing.expectEqual(@as(usize, 2), idx.files.len);

    try std.testing.expectEqualStrings("docs/report.pdf", idx.files[0].path);
    try std.testing.expectEqualSlices(u8, &files[0].info_hash, &idx.files[0].info_hash);
    try std.testing.expectEqual(@as(u64, 12345), idx.files[0].size);
    try std.testing.expectEqual(@as(i64, 1_700_000_000), idx.files[0].mtime);
    try std.testing.expectEqual(@as(i64, -5), idx.files[1].mtime);

    // find()
    const found = idx.find("photo.jpg").?;
    try std.testing.expectEqual(@as(u64, 777), found.size);
    try std.testing.expect(idx.find("nope.txt") == null);
}

test "parseEvent rejects wrong kind, missing d, wrong d prefix" {
    const allocator = std.testing.allocator;
    const valid_file = [_][]const u8{ "file", "a/b.txt", hash40, "10", "20" };

    {
        var ev = try makeRawEvent(allocator, 1, "carl-drive:x", &.{valid_file[0..]});
        defer ev.deinit(allocator);
        try std.testing.expectError(error.InvalidEvent, parseEvent(allocator, ev));
    }
    {
        var ev = try makeRawEvent(allocator, kind_drive_index, null, &.{valid_file[0..]});
        defer ev.deinit(allocator);
        try std.testing.expectError(error.MissingD, parseEvent(allocator, ev));
    }
    {
        var ev = try makeRawEvent(allocator, kind_drive_index, "other:x", &.{valid_file[0..]});
        defer ev.deinit(allocator);
        try std.testing.expectError(error.InvalidD, parseEvent(allocator, ev));
    }
    {
        // prefix present but empty drive name
        var ev = try makeRawEvent(allocator, kind_drive_index, "carl-drive:", &.{valid_file[0..]});
        defer ev.deinit(allocator);
        try std.testing.expectError(error.InvalidD, parseEvent(allocator, ev));
    }
}

test "parseEvent rejects invalid paths" {
    const allocator = std.testing.allocator;
    const bad_paths = [_][]const u8{
        "",
        "../x",
        "a/b/../../c",
        "/abs",
        "a//b",
        "a/./b",
        "a\\b",
        "a/",
    };
    for (bad_paths) |bp| {
        const spec = [_][]const u8{ "file", bp, hash40, "10", "20" };
        var ev = try makeRawEvent(allocator, kind_drive_index, "carl-drive:x", &.{spec[0..]});
        defer ev.deinit(allocator);
        try std.testing.expectError(error.InvalidPath, parseEvent(allocator, ev));
    }

    // overlong path
    var long_buf: [max_path_len + 1]u8 = undefined;
    @memset(&long_buf, 'a');
    const long_spec = [_][]const u8{ "file", &long_buf, hash40, "10", "20" };
    var ev = try makeRawEvent(allocator, kind_drive_index, "carl-drive:x", &.{long_spec[0..]});
    defer ev.deinit(allocator);
    try std.testing.expectError(error.InvalidPath, parseEvent(allocator, ev));
}

test "parseEvent rejects duplicate path, bad infohash, bad numbers, bad arity" {
    const allocator = std.testing.allocator;

    {
        const s1 = [_][]const u8{ "file", "dup.txt", hash40, "1", "2" };
        const s2 = [_][]const u8{ "file", "dup.txt", hash40, "3", "4" };
        var ev = try makeRawEvent(allocator, kind_drive_index, "carl-drive:x", &.{ s1[0..], s2[0..] });
        defer ev.deinit(allocator);
        try std.testing.expectError(error.DuplicatePath, parseEvent(allocator, ev));
    }
    {
        const spec = [_][]const u8{ "file", "a.txt", "deadbeef", "1", "2" };
        var ev = try makeRawEvent(allocator, kind_drive_index, "carl-drive:x", &.{spec[0..]});
        defer ev.deinit(allocator);
        try std.testing.expectError(error.InvalidInfoHash, parseEvent(allocator, ev));
    }
    {
        const spec = [_][]const u8{ "file", "a.txt", "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz", "1", "2" };
        var ev = try makeRawEvent(allocator, kind_drive_index, "carl-drive:x", &.{spec[0..]});
        defer ev.deinit(allocator);
        try std.testing.expectError(error.InvalidInfoHash, parseEvent(allocator, ev));
    }
    {
        const spec = [_][]const u8{ "file", "a.txt", hash40, "not-a-size", "2" };
        var ev = try makeRawEvent(allocator, kind_drive_index, "carl-drive:x", &.{spec[0..]});
        defer ev.deinit(allocator);
        try std.testing.expectError(error.InvalidSize, parseEvent(allocator, ev));
    }
    {
        const spec = [_][]const u8{ "file", "a.txt", hash40, "1", "not-an-mtime" };
        var ev = try makeRawEvent(allocator, kind_drive_index, "carl-drive:x", &.{spec[0..]});
        defer ev.deinit(allocator);
        try std.testing.expectError(error.InvalidMtime, parseEvent(allocator, ev));
    }
    {
        // file tag with 4 elements instead of 5
        const spec = [_][]const u8{ "file", "a.txt", hash40, "1" };
        var ev = try makeRawEvent(allocator, kind_drive_index, "carl-drive:x", &.{spec[0..]});
        defer ev.deinit(allocator);
        try std.testing.expectError(error.InvalidEvent, parseEvent(allocator, ev));
    }
}

test "build rejects duplicate paths, invalid paths, empty drive" {
    const allocator = std.testing.allocator;
    const keys = try testKeys();

    const dup_files = [_]FileEntry{
        testEntry("x.txt", 0, 0, 0),
        testEntry("x.txt", 1, 0, 0),
    };
    try std.testing.expectError(error.DuplicatePath, build(allocator, keys.sk, keys.pk, "d", &dup_files, 1));

    const bad_files = [_]FileEntry{testEntry("../evil", 0, 0, 0)};
    try std.testing.expectError(error.InvalidPath, build(allocator, keys.sk, keys.pk, "d", &bad_files, 1));

    try std.testing.expectError(error.InvalidD, build(allocator, keys.sk, keys.pk, "", &.{}, 1));
}

test "diff: null old marks everything added" {
    const allocator = std.testing.allocator;
    var files = [_]FileEntry{
        testEntry("a.txt", 1, 10, 1),
        testEntry("b.txt", 2, 20, 2),
    };
    const new_idx = testIndex(&files);

    const d = try diff(allocator, null, &new_idx);
    defer d.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), d.added.len);
    try std.testing.expectEqualStrings("a.txt", d.added[0]);
    try std.testing.expectEqualStrings("b.txt", d.added[1]);
    try std.testing.expectEqual(@as(usize, 0), d.changed.len);
    try std.testing.expectEqual(@as(usize, 0), d.removed.len);
    try std.testing.expectEqual(@as(usize, 0), d.renamed.len);
}

test "diff: changed infohash detected" {
    const allocator = std.testing.allocator;
    var old_files = [_]FileEntry{
        testEntry("a.txt", 1, 10, 1),
        testEntry("same.txt", 9, 5, 5),
    };
    var new_files = [_]FileEntry{
        testEntry("a.txt", 2, 10, 2),
        testEntry("same.txt", 9, 5, 5),
    };
    const old_idx = testIndex(&old_files);
    const new_idx = testIndex(&new_files);

    const d = try diff(allocator, &old_idx, &new_idx);
    defer d.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), d.added.len);
    try std.testing.expectEqual(@as(usize, 1), d.changed.len);
    try std.testing.expectEqualStrings("a.txt", d.changed[0]);
    try std.testing.expectEqual(@as(usize, 0), d.removed.len);
    try std.testing.expectEqual(@as(usize, 0), d.renamed.len);
}

test "diff: removal detected" {
    const allocator = std.testing.allocator;
    var old_files = [_]FileEntry{
        testEntry("a.txt", 1, 10, 1),
        testEntry("gone.txt", 2, 20, 2),
    };
    var new_files = [_]FileEntry{
        testEntry("a.txt", 1, 10, 1),
    };
    const old_idx = testIndex(&old_files);
    const new_idx = testIndex(&new_files);

    const d = try diff(allocator, &old_idx, &new_idx);
    defer d.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), d.added.len);
    try std.testing.expectEqual(@as(usize, 0), d.changed.len);
    try std.testing.expectEqual(@as(usize, 1), d.removed.len);
    try std.testing.expectEqualStrings("gone.txt", d.removed[0]);
    try std.testing.expectEqual(@as(usize, 0), d.renamed.len);
}

test "diff: same infohash at a new path is a rename, not add+remove" {
    const allocator = std.testing.allocator;
    var old_files = [_]FileEntry{
        testEntry("old-name.txt", 7, 10, 1),
        testEntry("keep.txt", 8, 20, 2),
    };
    var new_files = [_]FileEntry{
        testEntry("keep.txt", 8, 20, 2),
        testEntry("new-name.txt", 7, 10, 1),
    };
    const old_idx = testIndex(&old_files);
    const new_idx = testIndex(&new_files);

    const d = try diff(allocator, &old_idx, &new_idx);
    defer d.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), d.added.len);
    try std.testing.expectEqual(@as(usize, 0), d.changed.len);
    try std.testing.expectEqual(@as(usize, 0), d.removed.len);
    try std.testing.expectEqual(@as(usize, 1), d.renamed.len);
    try std.testing.expectEqualStrings("old-name.txt", d.renamed[0].from);
    try std.testing.expectEqualStrings("new-name.txt", d.renamed[0].to);
}

test "TooManyFiles boundary" {
    const allocator = std.testing.allocator;
    const keys = try testKeys();

    // max_files + 1 -> rejected before any path validation.
    var too_many: [max_files + 1]FileEntry = undefined;
    for (&too_many) |*f| f.* = .{ .path = "x", .info_hash = .{0} ** 20, .size = 0, .mtime = 0 };
    try std.testing.expectError(error.TooManyFiles, build(allocator, keys.sk, keys.pk, "d", &too_many, 1));

    // exactly max_files -> accepted, and parses back.
    var path_bufs: [max_files][16]u8 = undefined;
    var entries: [max_files]FileEntry = undefined;
    for (&entries, 0..) |*f, i| {
        const p = std.fmt.bufPrint(&path_bufs[i], "f{d}", .{i}) catch unreachable;
        f.* = .{ .path = p, .info_hash = .{0} ** 20, .size = @intCast(i), .mtime = 0 };
    }
    var ev = try build(allocator, keys.sk, keys.pk, "d", &entries, 1);
    defer ev.deinit(allocator);
    const idx = try parseEvent(allocator, ev);
    defer idx.deinit(allocator);
    try std.testing.expectEqual(max_files, idx.files.len);
}

test "indexFilter builds kinds/authors/#d filter" {
    const author: [32]u8 = .{7} ** 32;
    var d_buf: [128]u8 = undefined;
    var author_hex_buf: [64]u8 = undefined;
    var kinds_buf: [1]u32 = undefined;
    var authors_buf: [1][]const u8 = undefined;
    var values_buf: [1][]const u8 = undefined;
    var tags_buf: [1]nostr.Filter.TagFilter = undefined;

    const f = indexFilter(author, "photos", &d_buf, &author_hex_buf, &kinds_buf, &authors_buf, &values_buf, &tags_buf).?;
    try std.testing.expectEqual(kind_drive_index, f.kinds.?[0]);
    try std.testing.expectEqual(@as(u8, 'd'), f.tags.?[0].letter);
    try std.testing.expectEqualStrings("carl-drive:photos", f.tags.?[0].values[0]);
    var expected_hex: [64]u8 = undefined;
    secp.toHex(&author, &expected_hex);
    try std.testing.expectEqualStrings(&expected_hex, f.authors.?[0]);

    // d_buf too small -> null
    var tiny: [4]u8 = undefined;
    try std.testing.expect(indexFilter(author, "photos", &tiny, &author_hex_buf, &kinds_buf, &authors_buf, &values_buf, &tags_buf) == null);
}
