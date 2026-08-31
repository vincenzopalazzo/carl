//! The unified carl working directory: the default download *and* seed
//! directory shared by the CLI, the daemon, and the desktop GUI. Downloads
//! land here and seeds default to reading from here, so anything in the
//! directory can be reseeded from any frontend — drop a file in, seed it.
//!
//! Resolution order:
//!   1. `$CARL_DIR` — explicit override (tests, scripting)
//!   2. the persisted `downloadDir` setting in `<config>/carl.db` (the GUI's
//!      Settings screen writes it there via the daemon), so the CLI follows
//!      whatever directory the user picked in the app and vice versa
//!   3. `$HOME/Downloads/carl`
//!
//! Falls back to "." only when HOME is unavailable. Best-effort by design:
//! the only error surfaced is OOM — a missing/corrupt DB just falls through
//! to the built-in default.

const std = @import("std");
const Allocator = std.mem.Allocator;
const state = @import("state.zig");
const nostr_config = @import("nostr_config.zig");

/// Old defaults that mean "the user never chose a directory": the CLI/daemon
/// placeholder "." and the retired desktop default `~/Downloads/carl-download`.
/// A persisted value matching these is ignored so stale state from before the
/// unified work dir doesn't pin the old per-frontend behavior.
pub fn isPlaceholder(
    a: Allocator,
    home: ?[]const u8,
    dir: []const u8,
) bool {
    if (dir.len == 0 or std.mem.eql(u8, dir, ".")) return true;

    const home_dir = home orelse return false;

    const legacy = std.fmt.allocPrint(
        a,
        "{s}/Downloads/carl-download",
        .{home_dir},
    ) catch return false;
    defer a.free(legacy);

    return std.mem.eql(u8, dir, legacy);
}

/// Built-in default: `$HOME/Downloads/carl` ("." without HOME). Caller owns
/// the returned slice.
pub fn defaultDir(a: Allocator, home: ?[]const u8) Allocator.Error![]u8 {
    const home_dir = home orelse return a.dupe(u8, ".");

    return std.fmt.allocPrint(
        a,
        "{s}/Downloads/carl",
        .{home_dir},
    );
}

/// The `$CARL_DIR` override, or null when unset/empty. Callers that need to
/// know whether the override is active (and not just the resolved result) use
/// this directly — e.g. the daemon, which must keep the override outranking
/// the persisted setting across `Manager.restore`. Caller owns the slice.
pub fn envOverride(a: Allocator, carl_dir: ?[]const u8) Allocator.Error!?[]u8 {
    const env = carl_dir orelse return null;

    if (env.len == 0) return null;

    return try a.dupe(u8, env);
}

/// Resolve the working directory (override > persisted setting > default).
/// Caller owns the returned slice.
pub fn resolve(
    ctx: nostr_config.Context,
    a: Allocator,
    carl_dir: ?[]const u8,
) Allocator.Error![]u8 {
    if (try envOverride(a, carl_dir)) |dir| return dir;

    if (state.loadDownloadDir(ctx, a)) |dir| {
        if (!isPlaceholder(a, ctx.home, dir)) return dir;
        a.free(dir);
    }

    return defaultDir(a, ctx.home);
}

/// Resolve and create the directory (best-effort). Caller owns the slice.
pub fn ensure(
    ctx: nostr_config.Context,
    a: Allocator,
    carl_dir: ?[]const u8,
) Allocator.Error![]u8 {
    const dir = try resolve(ctx, a, carl_dir);

    std.Io.Dir.cwd().createDirPath(ctx.io, dir) catch {};

    return dir;
}

/// The restart shelf: `<base>/seeds`, a subdirectory of the work dir holding
/// everything needed to bring transfers back after a restart — each transfer's
/// resolved `.torrent`, checkpointed as `<infohash>.torrent`. Keeping the
/// recipes here (instead of pointing at a magnet source or a user file
/// elsewhere on disk) means a restart never depends on the original seeder
/// being online or on a file outside carl's own directory. Shared convention:
/// the `carl follow` mirror flow checkpoints its torrents the same way.
/// Caller owns the returned slice; the directory is not created here.
pub fn seedsDir(a: Allocator, base: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(a, "{s}/seeds", .{base});
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "seedsDir: appends the seeds shelf to the base dir" {
    const dir = try seedsDir(testing.allocator, "/tmp/carl-work");
    defer testing.allocator.free(dir);
    try testing.expectEqualStrings("/tmp/carl-work/seeds", dir);
}

test "isPlaceholder: empty and dot are placeholders" {
    try testing.expect(
        isPlaceholder(testing.allocator, null, ""),
    );
    try testing.expect(
        isPlaceholder(testing.allocator, null, "."),
    );
    try testing.expect(
        !isPlaceholder(testing.allocator, null, "/some/real/dir"),
    );
}

test "isPlaceholder: legacy desktop default is a placeholder" {
    const a = testing.allocator;
    const home = "/home/test";

    const legacy = try std.fmt.allocPrint(
        a,
        "{s}/Downloads/carl-download",
        .{home},
    );
    defer a.free(legacy);

    try testing.expect(
        isPlaceholder(a, home, legacy),
    );
}

test "defaultDir: lands under HOME/Downloads/carl" {
    const a = testing.allocator;
    const home = "/home/test";

    const dir = try defaultDir(a, home);
    defer a.free(dir);

    try testing.expectEqualStrings(
        "/home/test/Downloads/carl",
        dir,
    );
}
