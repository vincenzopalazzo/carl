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

/// Old defaults that mean "the user never chose a directory": the CLI/daemon
/// placeholder "." and the retired desktop default `~/Downloads/carl-download`.
/// A persisted value matching these is ignored so stale state from before the
/// unified work dir doesn't pin the old per-frontend behavior.
pub fn isPlaceholder(a: Allocator, dir: []const u8) bool {
    if (dir.len == 0 or std.mem.eql(u8, dir, ".")) return true;
    const home = std.process.getEnvVarOwned(a, "HOME") catch return false;
    defer a.free(home);
    const legacy = std.fmt.allocPrint(a, "{s}/Downloads/carl-download", .{home}) catch return false;
    defer a.free(legacy);
    return std.mem.eql(u8, dir, legacy);
}

/// Built-in default: `$HOME/Downloads/carl` ("." without HOME). Caller owns
/// the returned slice.
pub fn defaultDir(a: Allocator) Allocator.Error![]u8 {
    const home = std.process.getEnvVarOwned(a, "HOME") catch return a.dupe(u8, ".");
    defer a.free(home);
    return std.fmt.allocPrint(a, "{s}/Downloads/carl", .{home});
}

/// Resolve the working directory (override > persisted setting > default).
/// Caller owns the returned slice.
pub fn resolve(a: Allocator) Allocator.Error![]u8 {
    if (std.process.getEnvVarOwned(a, "CARL_DIR")) |env| {
        if (env.len > 0) return env;
        a.free(env);
    } else |_| {}
    if (state.loadDownloadDir(a)) |dir| {
        if (!isPlaceholder(a, dir)) return dir;
        a.free(dir);
    }
    return defaultDir(a);
}

/// Resolve and create the directory (best-effort). Caller owns the slice.
pub fn ensure(a: Allocator) Allocator.Error![]u8 {
    const dir = try resolve(a);
    std.fs.cwd().makePath(dir) catch {};
    return dir;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "isPlaceholder: empty and dot are placeholders" {
    try testing.expect(isPlaceholder(testing.allocator, ""));
    try testing.expect(isPlaceholder(testing.allocator, "."));
    try testing.expect(!isPlaceholder(testing.allocator, "/some/real/dir"));
}

test "isPlaceholder: legacy desktop default is a placeholder" {
    const a = testing.allocator;
    const home = std.process.getEnvVarOwned(a, "HOME") catch return; // no HOME: nothing to check
    defer a.free(home);
    const legacy = try std.fmt.allocPrint(a, "{s}/Downloads/carl-download", .{home});
    defer a.free(legacy);
    try testing.expect(isPlaceholder(a, legacy));
}

test "defaultDir: lands under HOME/Downloads/carl" {
    const a = testing.allocator;
    const dir = try defaultDir(a);
    defer a.free(dir);
    if (std.process.getEnvVarOwned(a, "HOME")) |home| {
        defer a.free(home);
        const expected = try std.fmt.allocPrint(a, "{s}/Downloads/carl", .{home});
        defer a.free(expected);
        try testing.expectEqualStrings(expected, dir);
    } else |_| {
        try testing.expectEqualStrings(".", dir);
    }
}
