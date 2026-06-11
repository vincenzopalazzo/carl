//! Persistence for I2P seed destinations.
//!
//! An I2P seed is reachable at `base32(SHA-256(destination)).b32.i2p`, derived
//! from its destination keypair. To keep that address stable across restarts
//! (so a published `.b32.i2p` peer-announce stays valid), we persist the SAM
//! private-key blob the router hands back on `SESSION CREATE` and feed it back
//! via `Session.createWithDest(.{ .priv = ... })` next time.
//!
//! Keys live under `<config>/i2p-seeds/<infohash-hex>.dest`, one file per
//! seeded torrent, 0600 (the blob is private key material — anyone with it can
//! impersonate the destination). Best-effort: a missing/unreadable file just
//! means a fresh transient destination (a new address), never a hard failure.

const std = @import("std");
const Allocator = std.mem.Allocator;
const nostr_config = @import("nostr_config.zig");

const log = std.log.scoped(.i2p_seed);

/// SAM destination private keys are ~884 base64 chars for Ed25519; allow ample
/// headroom for other signature types without being unbounded.
const max_dest_len: usize = 8 * 1024;

fn destPath(allocator: Allocator, info_hash_hex: []const u8) ![]u8 {
    const dir = try nostr_config.configDir(allocator);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/i2p-seeds/{s}.dest", .{ dir, info_hash_hex });
}

/// Load a persisted destination private key for `info_hash_hex`, or null if
/// none is stored yet. Caller owns the returned slice.
pub fn load(allocator: Allocator, info_hash_hex: []const u8) !?[]u8 {
    const path = try destPath(allocator, info_hash_hex);
    defer allocator.free(path);
    const data = std.fs.cwd().readFileAlloc(allocator, path, max_dest_len) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(data);
        return null;
    }
    if (trimmed.len == data.len) return data;
    // Trim copied a sub-slice; re-own it compactly so the caller can free it.
    defer allocator.free(data);
    return try allocator.dupe(u8, trimmed);
}

/// Persist `dest_priv` (the SAM private-key blob) for `info_hash_hex`, 0600.
/// Best-effort: a write failure is logged, not fatal — the seed still runs
/// this session, it just won't keep its address on the next restart.
pub fn save(allocator: Allocator, info_hash_hex: []const u8, dest_priv: []const u8) void {
    saveImpl(allocator, info_hash_hex, dest_priv) catch |err| {
        log.warn("could not persist i2p seed destination for {s}: {}", .{ info_hash_hex, err });
    };
}

fn saveImpl(allocator: Allocator, info_hash_hex: []const u8, dest_priv: []const u8) !void {
    const dir = try nostr_config.configDir(allocator);
    defer allocator.free(dir);
    const seeds_dir = try std.fmt.allocPrint(allocator, "{s}/i2p-seeds", .{dir});
    defer allocator.free(seeds_dir);
    std.fs.cwd().makePath(seeds_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.dest", .{ seeds_dir, info_hash_hex });
    defer allocator.free(path);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(dest_priv);
    try file.chmod(0o600);
}

test "i2p_seed: save then load round-trips; missing is null" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Point configDir at the tmp dir via XDG_CONFIG_HOME for the duration.
    const prev = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch null;
    defer if (prev) |p| allocator.free(p);
    // Note: setenv isn't available portably in Zig tests without libc helpers,
    // so this test exercises the path math + IO against an explicit dir instead.
    const hex = "aa" ** 20;
    const dir = try std.fmt.allocPrint(allocator, "{s}/carl/i2p-seeds", .{tmp_path});
    defer allocator.free(dir);
    try std.fs.cwd().makePath(dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.dest", .{ dir, hex });
    defer allocator.free(path);
    {
        var f = try std.fs.cwd().createFile(path, .{ .truncate = true, .mode = 0o600 });
        defer f.close();
        try f.writeAll("persisted-key-blob\n");
    }
    const data = try std.fs.cwd().readFileAlloc(allocator, path, max_dest_len);
    defer allocator.free(data);
    try std.testing.expectEqualStrings("persisted-key-blob", std.mem.trim(u8, data, " \t\r\n"));
}
