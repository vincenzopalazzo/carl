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

const builtin = @import("builtin");

const private_permissions: std.Io.File.Permissions =
    if (builtin.os.tag == .windows)
        .default_file
    else
        @enumFromInt(0o600);

const log = std.log.scoped(.i2p_seed);

/// SAM destination private keys are ~884 base64 chars for Ed25519; allow ample
/// headroom for other signature types without being unbounded.
const max_dest_len: usize = 8 * 1024;

/// A usable blob must decode to at least the 387-byte public destination
/// `b32Address` parses (the smallest real SAM blob is 516 base64 chars = 387
/// bytes). Length alone cannot prove a blob is untorn — a truncation on a
/// 4-char base64 boundary still decodes — so SAM rejection is the final
/// arbiter and the caller falls back to a fresh destination on it.
const min_dest_decoded_len: usize = 387;

/// I2P uses its own base64 alphabet — `-` and `~` instead of `+` and `/` —
/// so a valid SAM blob may not decode as standard base64. Accept either.
const i2p_decoder = std.base64.Base64Decoder.init("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-~".*, '=');

/// True if `data` looks like a usable SAM destination private key: decodable
/// (standard or I2P base64 alphabet) to at least the minimum destination size.
pub fn isValidDestBlob(data: []const u8) bool {
    const std_n = std.base64.standard.Decoder.calcSizeForSlice(data) catch 0;
    const i2p_n = i2p_decoder.calcSizeForSlice(data) catch 0;
    return @max(std_n, i2p_n) >= min_dest_decoded_len;
}

fn destPath(
    ctx: nostr_config.Context,
    allocator: Allocator,
    info_hash_hex: []const u8,
) ![]u8 {
    const dir = try nostr_config.configDir(ctx, allocator);
    defer allocator.free(dir);

    return std.fmt.allocPrint(
        allocator,
        "{s}/i2p-seeds/{s}.dest",
        .{ dir, info_hash_hex },
    );
}

/// Load a persisted destination private key for `info_hash_hex`, or null if
/// none is stored yet. Caller owns the returned slice.
pub fn load(
    ctx: nostr_config.Context,
    allocator: Allocator,
    info_hash_hex: []const u8,
) !?[]u8 {
    const path = try destPath(ctx, allocator, info_hash_hex);
    defer allocator.free(path);

    const data = std.Io.Dir.cwd().readFileAlloc(
        ctx.io,
        path,
        allocator,
        .limited(max_dest_len),
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };

    const trimmed = std.mem.trim(u8, data, " \t\r\n");

    if (trimmed.len == 0) {
        allocator.free(data);
        return null;
    }

    if (!isValidDestBlob(trimmed)) {
        log.warn(
            "ignoring corrupt i2p seed destination {s} ({d} bytes) — a fresh address will be generated",
            .{ path, trimmed.len },
        );

        allocator.free(data);
        std.Io.Dir.cwd().deleteFile(ctx.io, path) catch {};
        return null;
    }

    if (trimmed.len == data.len) return data;

    defer allocator.free(data);
    return try allocator.dupe(u8, trimmed);
}

/// Persist `dest_priv` (the SAM private-key blob) for `info_hash_hex`, 0600.
/// Best-effort: a write failure is logged, not fatal — the seed still runs
/// this session, it just won't keep its address on the next restart.
pub fn save(
    ctx: nostr_config.Context,
    allocator: Allocator,
    info_hash_hex: []const u8,
    dest_priv: []const u8,
) void {
    saveImpl(ctx, allocator, info_hash_hex, dest_priv) catch |err| {
        log.warn(
            "could not persist i2p seed destination for {s}: {}",
            .{ info_hash_hex, err },
        );
    };
}

fn saveImpl(
    ctx: nostr_config.Context,
    allocator: Allocator,
    info_hash_hex: []const u8,
    dest_priv: []const u8,
) !void {
    const dir = try nostr_config.configDir(ctx, allocator);
    defer allocator.free(dir);

    const seeds_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/i2p-seeds",
        .{dir},
    );
    defer allocator.free(seeds_dir);

    try std.Io.Dir.cwd().createDirPath(ctx.io, seeds_dir);

    const path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}.dest",
        .{ seeds_dir, info_hash_hex },
    );
    defer allocator.free(path);

    const tmp_path = try std.fmt.allocPrint(
        allocator,
        "{s}.tmp",
        .{path},
    );
    defer allocator.free(tmp_path);

    {
        const file = try std.Io.Dir.cwd().createFile(
            ctx.io,
            tmp_path,
            .{
                .truncate = true,
                .permissions = private_permissions,
            },
        );
        defer file.close(ctx.io);

        try file.writeStreamingAll(ctx.io, dest_priv);
        try file.setPermissions(ctx.io, private_permissions);
    }

    try std.Io.Dir.cwd().rename(
        tmp_path,
        std.Io.Dir.cwd(),
        path,
        ctx.io,
    );
}

test "i2p_seed: isValidDestBlob rejects truncated/corrupt writes" {
    // The 4-byte "AAAA" file a crashed daemon left behind in the field.
    try std.testing.expect(!isValidDestBlob("AAAA"));
    try std.testing.expect(!isValidDestBlob(""));
    try std.testing.expect(!isValidDestBlob("A" ** 100)); // too short
    // Valid base64 torn on a 4-char boundary but below the 387-byte minimum.
    try std.testing.expect(!isValidDestBlob("QUJD" ** 100)); // 400 chars -> 300 bytes
    try std.testing.expect(!isValidDestBlob("QUJD" ** 130 ++ "!!!")); // not base64
    try std.testing.expect(isValidDestBlob("QUJD" ** 130)); // 520 chars -> 390 bytes
    // I2P-alphabet blob (- and ~) must not be rejected as corrupt.
    try std.testing.expect(isValidDestBlob("QUJD" ** 129 ++ "-~JD"));
}

/// Delete the persisted destination for `info_hash_hex` (best-effort).
pub fn remove(
    ctx: nostr_config.Context,
    allocator: Allocator,
    info_hash_hex: []const u8,
) void {
    const path = destPath(ctx, allocator, info_hash_hex) catch return;
    defer allocator.free(path);

    std.Io.Dir.cwd().deleteFile(ctx.io, path) catch {};
}

test "i2p_seed: save then load round-trips; missing is null" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    // Exercise the path math + IO against an explicit temp dir.
    const hex = "aa" ** 20;
    const dir = try std.fmt.allocPrint(allocator, "{s}/carl/i2p-seeds", .{tmp_path});
    defer allocator.free(dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);

    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.dest", .{ dir, hex });
    defer allocator.free(path);

    {
        var f = try std.Io.Dir.cwd().createFile(
            std.testing.io,
            path,
            .{ .truncate = true, .permissions = @enumFromInt(0o600) },
        );
        defer f.close(std.testing.io);

        try f.writeStreamingAll(
            std.testing.io,
            "persisted-key-blob\n",
        );
    }

    const data = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(max_dest_len),
    );
    defer allocator.free(data);
    try std.testing.expectEqualStrings("persisted-key-blob", std.mem.trim(u8, data, " \t\r\n"));
}
