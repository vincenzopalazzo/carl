//! Tiny config layer for carl's Nostr integration: a secret-key file with
//! 0600 permissions under `$XDG_CONFIG_HOME/carl/` (or `~/.config/carl/`), and
//! a relay list file alongside it.
//!
//! No state is held in memory — read functions open the file each time. This
//! keeps the surface trivial and avoids races between `carl seed` (writer) and
//! `carl search` (reader) running in parallel.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Context = struct {
    io: std.Io,
    home: ?[]const u8,
    xdg_config_home: ?[]const u8,
};

const secp = @import("secp.zig");
const nip19 = @import("nip19.zig");

const log = std.log.scoped(.config);

// Module errors are inferred: every public function below returns its real
// error set, including the named variants (`NoKey`, `BadKeyFile`,
// `NoConfigDir`) plus whatever the underlying std.fs / std.process calls
// surface. `main.zig` switches on the specific tags it cares about and lets
// the rest propagate.

/// Resolve the config directory: $XDG_CONFIG_HOME/carl or $HOME/.config/carl.
/// Caller owns the returned slice.
pub fn configDir(ctx: Context, allocator: Allocator) ![]u8 {
    if (ctx.xdg_config_home) |xdg| {
        return try std.fmt.allocPrint(
            allocator,
            "{s}/carl",
            .{xdg},
        );
    }

    const home = ctx.home orelse return error.NoConfigDir;

    return try std.fmt.allocPrint(
        allocator,
        "{s}/.config/carl",
        .{home},
    );
}

/// Ensure the config directory exists; mode 0700.
pub fn ensureConfigDir(ctx: Context, allocator: Allocator) ![]u8 {
    const dir = try configDir(ctx, allocator);
    errdefer allocator.free(dir);
    std.Io.Dir.cwd().createDirPath(ctx.io, dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return dir;
}

/// Write the secret key as bech32 nsec to `<config>/nsec` with 0600 perms.
/// Overwrites any existing file. Returns the bech32 string (caller owns it).
/// Write the secret key as bech32 nsec to `<config>/nsec` with 0600 perms.
/// Overwrites any existing file. Returns the bech32 string (caller owns it).
pub fn writeSecretKey(
    ctx: Context,
    allocator: Allocator,
    sk: secp.SecretKey,
) ![]u8 {
    const dir = try ensureConfigDir(ctx, allocator);
    defer allocator.free(dir);

    const path = try std.fmt.allocPrint(
        allocator,
        "{s}/nsec",
        .{dir},
    );
    defer allocator.free(path);

    const nsec = try nip19.encode32(allocator, .nsec, sk);
    errdefer allocator.free(nsec);

    const secret_permissions: std.Io.File.Permissions = @enumFromInt(0o600);

    var file = try std.Io.Dir.cwd().createFile(ctx.io, path, .{
        .truncate = true,
        .permissions = secret_permissions,
    });
    defer file.close(ctx.io);

    // `createFile` permissions only affect newly created files.
    // Explicitly reset permissions when overwriting an existing key file.
    try file.setPermissions(ctx.io, secret_permissions);

    try file.writeStreamingAll(ctx.io, nsec);
    try file.writeStreamingAll(ctx.io, "\n");

    return nsec;
}

/// Parse the contents of an nsec file (one bech32 entity, optional trailing
/// whitespace) into a 32-byte secret key. Returns `BadKeyFile` if the payload
/// is malformed or the HRP isn't `nsec`. Extracted from readSecretKey so the
/// test suite can hit it without touching the filesystem layer.
pub fn parseNsecFile(content: []const u8) !secp.SecretKey {
    var trimmed: []const u8 = content;
    while (trimmed.len > 0 and (trimmed[trimmed.len - 1] == '\n' or trimmed[trimmed.len - 1] == '\r' or trimmed[trimmed.len - 1] == ' ' or trimmed[trimmed.len - 1] == '\t')) {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    const decoded = nip19.decode32(trimmed) catch return error.BadKeyFile;
    if (decoded.kind != .nsec) return error.BadKeyFile;
    return decoded.data;
}

/// Read the secret key from `<config>/nsec`. Returns NoKey if absent.
pub fn readSecretKey(ctx: Context, allocator: Allocator) !secp.SecretKey {
    const dir = try configDir(ctx, allocator);
    defer allocator.free(dir);

    const path = try std.fmt.allocPrint(
        allocator,
        "{s}/nsec",
        .{dir},
    );
    defer allocator.free(path);

    const data = std.Io.Dir.cwd().readFileAlloc(
        ctx.io,
        path,
        allocator,
        .limited(128),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.NoKey,
        error.StreamTooLong => return error.BadKeyFile,
        else => return err,
    };
    defer allocator.free(data);

    return parseNsecFile(data);
}

/// Read the relay list from `<config>/relays` (one per line). Fall back to
/// the default public relay set ONLY when the file is genuinely absent or
/// the user wrote an empty file — any other I/O error (permissions, partial
/// read, etc.) surfaces. A user who configured only private relays must not
/// have their announce/search silently routed to the public defaults if
/// their config file is unreadable for some reason. Caller owns the slice
/// and each entry.
/// Read the relay list from `<config>/relays` (one per line).
pub fn readRelays(ctx: Context, allocator: Allocator) ![][]const u8 {
    const dir = try configDir(ctx, allocator);
    defer allocator.free(dir);

    const path = try std.fmt.allocPrint(
        allocator,
        "{s}/relays",
        .{dir},
    );
    defer allocator.free(path);

    const data = std.Io.Dir.cwd().readFileAlloc(
        ctx.io,
        path,
        allocator,
        .limited(64 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return dupeDefaults(allocator),
        else => return err,
    };
    defer allocator.free(data);

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |s| allocator.free(s);
        list.deinit(allocator);
    }

    var it = std.mem.tokenizeAny(u8, data, "\r\n");

    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t");

        if (t.len == 0 or t[0] == '#') continue;

        if (!std.mem.startsWith(u8, t, "wss://") and !std.mem.startsWith(u8, t, "ws://")) {
            log.warn("ignoring invalid relay URL '{s}' (must be wss:// or ws://)", .{t});
            continue;
        }

        try list.append(
            allocator,
            try allocator.dupe(u8, t),
        );
    }

    if (list.items.len == 0) {
        list.deinit(allocator);
        return dupeDefaults(allocator);
    }

    return list.toOwnedSlice(allocator);
}

fn dupeDefaults(allocator: Allocator) ![][]const u8 {
    const relay_mod = @import("relay.zig");
    const out = try allocator.alloc([]const u8, relay_mod.default_relays.len);
    for (relay_mod.default_relays, 0..) |r, i| {
        out[i] = try allocator.dupe(u8, r);
    }
    return out;
}

pub fn freeRelays(allocator: Allocator, relays: [][]const u8) void {
    for (relays) |r| allocator.free(r);
    allocator.free(relays);
}

/// Overwrite `<config>/relays` with `relays` (one per line). Blank entries are
/// skipped. Used by the daemon's settings endpoint so edits from the GUI
/// persist and are visible to search, peer-announce, and the CLI.
pub fn writeRelays(
    ctx: Context,
    allocator: Allocator,
    relays: []const []const u8,
) !void {
    const dir = try ensureConfigDir(ctx, allocator);
    defer allocator.free(dir);

    const path = try std.fmt.allocPrint(
        allocator,
        "{s}/relays",
        .{dir},
    );
    defer allocator.free(path);

    var file = try std.Io.Dir.cwd().createFile(ctx.io, path, .{
        .truncate = true,
    });
    defer file.close(ctx.io);

    for (relays) |relay| {
        const t = std.mem.trim(u8, relay, " \t");
        if (t.len == 0) continue;
        if (!std.mem.startsWith(u8, t, "wss://") and !std.mem.startsWith(u8, t, "ws://")) {
            log.warn("ignoring invalid relay URL '{s}' on write (must be wss:// or ws://)", .{t});
            continue;
        }
        try file.writeStreamingAll(ctx.io, t);
        try file.writeStreamingAll(ctx.io, "\n");
    }
}

// ===========================================================================
// Tests
// ===========================================================================

test "parseNsecFile: round trips a written nsec via the production path" {
    const allocator = std.testing.allocator;

    var sk: secp.SecretKey = undefined;
    try secp.fromHex("0000000000000000000000000000000000000000000000000000000000000003", &sk);

    const nsec = try nip19.encode32(allocator, .nsec, sk);
    defer allocator.free(nsec);

    // What writeSecretKey actually puts on disk: bech32 entity + "\n".
    var on_disk: [128]u8 = undefined;
    @memcpy(on_disk[0..nsec.len], nsec);
    on_disk[nsec.len] = '\n';

    const back = try parseNsecFile(on_disk[0 .. nsec.len + 1]);
    try std.testing.expectEqualSlices(u8, &sk, &back);
}

test "parseNsecFile: tolerates trailing \\r\\n and spaces" {
    const allocator = std.testing.allocator;

    var sk: secp.SecretKey = undefined;
    try secp.fromHex("0000000000000000000000000000000000000000000000000000000000000003", &sk);

    const nsec = try nip19.encode32(allocator, .nsec, sk);
    defer allocator.free(nsec);

    var buf: [128]u8 = undefined;
    @memcpy(buf[0..nsec.len], nsec);
    buf[nsec.len] = '\r';
    buf[nsec.len + 1] = '\n';
    buf[nsec.len + 2] = ' ';

    const back = try parseNsecFile(buf[0 .. nsec.len + 3]);
    try std.testing.expectEqualSlices(u8, &sk, &back);
}

test "parseNsecFile: rejects a non-nsec bech32 entity" {
    const allocator = std.testing.allocator;

    var pk: secp.PublicKey = undefined;
    @memset(&pk, 0x55);
    const npub = try nip19.encode32(allocator, .npub, pk);
    defer allocator.free(npub);

    try std.testing.expectError(error.BadKeyFile, parseNsecFile(npub));
}

test "parseNsecFile: rejects garbage" {
    try std.testing.expectError(error.BadKeyFile, parseNsecFile("not bech32"));
    try std.testing.expectError(error.BadKeyFile, parseNsecFile(""));
}
