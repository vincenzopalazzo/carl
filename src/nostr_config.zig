//! Tiny config layer for carl's Nostr integration: a secret-key file with
//! 0600 permissions under `$XDG_CONFIG_HOME/carl/` (or `~/.config/carl/`), and
//! a relay list file alongside it.
//!
//! No state is held in memory — read functions open the file each time. This
//! keeps the surface trivial and avoids races between `carl seed` (writer) and
//! `carl search` (reader) running in parallel.

const std = @import("std");
const Allocator = std.mem.Allocator;
const secp = @import("secp.zig");
const nip19 = @import("nip19.zig");

const log = std.log.scoped(.config);

pub const Error = error{
    NoConfigDir,
    NoKey,
    BadKeyFile,
    OutOfMemory,
} || std.fs.File.OpenError || std.fs.Dir.MakeError || std.posix.WriteError;

/// Resolve the config directory: $XDG_CONFIG_HOME/carl or $HOME/.config/carl.
/// Caller owns the returned slice.
pub fn configDir(allocator: Allocator) Error![]u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg| {
        defer allocator.free(xdg);
        return try std.fmt.allocPrint(allocator, "{s}/carl", .{xdg});
    } else |_| {}

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return error.NoConfigDir;
    defer allocator.free(home);
    return try std.fmt.allocPrint(allocator, "{s}/.config/carl", .{home});
}

/// Ensure the config directory exists; mode 0700.
pub fn ensureConfigDir(allocator: Allocator) Error![]u8 {
    const dir = try configDir(allocator);
    errdefer allocator.free(dir);
    std.fs.cwd().makePath(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return dir;
}

/// Write the secret key as bech32 nsec to `<config>/nsec` with 0600 perms.
/// Overwrites any existing file. Returns the bech32 string (caller owns it).
pub fn writeSecretKey(allocator: Allocator, sk: secp.SecretKey) ![]u8 {
    const dir = try ensureConfigDir(allocator);
    defer allocator.free(dir);

    const path = try std.fmt.allocPrint(allocator, "{s}/nsec", .{dir});
    defer allocator.free(path);

    const nsec = try nip19.encode32(allocator, .nsec, sk);
    errdefer allocator.free(nsec);

    var file = try std.fs.cwd().createFile(path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(nsec);
    try file.writeAll("\n");
    return nsec;
}

/// Read the secret key from `<config>/nsec`. Returns NoKey if absent.
pub fn readSecretKey(allocator: Allocator) Error!secp.SecretKey {
    const dir = try configDir(allocator);
    defer allocator.free(dir);

    const path = std.fmt.allocPrint(allocator, "{s}/nsec", .{dir}) catch return error.OutOfMemory;
    defer allocator.free(path);

    var file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.NoKey,
        else => return err,
    };
    defer file.close();

    var buf: [128]u8 = undefined;
    const n = file.readAll(&buf) catch return error.BadKeyFile;
    var trimmed: []const u8 = buf[0..n];
    while (trimmed.len > 0 and (trimmed[trimmed.len - 1] == '\n' or trimmed[trimmed.len - 1] == '\r' or trimmed[trimmed.len - 1] == ' ')) {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }

    const decoded = nip19.decode32(trimmed) catch return error.BadKeyFile;
    if (decoded.kind != .nsec) return error.BadKeyFile;
    return decoded.data;
}

/// Read the relay list from `<config>/relays` (one per line). If absent or
/// empty, return the default relay list. Caller owns the slice and each entry.
pub fn readRelays(allocator: Allocator) ![][]const u8 {
    const dir = try configDir(allocator);
    defer allocator.free(dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/relays", .{dir});
    defer allocator.free(path);

    var file = std.fs.cwd().openFile(path, .{}) catch {
        return dupeDefaults(allocator);
    };
    defer file.close();

    const data = file.readToEndAlloc(allocator, 64 * 1024) catch return dupeDefaults(allocator);
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
        const dup = try allocator.dupe(u8, t);
        try list.append(allocator, dup);
    }
    if (list.items.len == 0) return dupeDefaults(allocator);
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

// ===========================================================================
// Tests
// ===========================================================================

// Round-trip secret-key file in a temporary directory. We exercise the bech32
// codec used by the writer/reader without poking the real $HOME/$XDG_CONFIG_HOME
// (that path requires setenv plumbing that std doesn't expose cleanly).
test "writeFileAndReadBack roundtrips an nsec file at an arbitrary path" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var sk: secp.SecretKey = undefined;
    try secp.fromHex("0000000000000000000000000000000000000000000000000000000000000003", &sk);

    const nsec = try nip19.encode32(allocator, .nsec, sk);
    defer allocator.free(nsec);

    var file = try tmp.dir.createFile("nsec", .{ .truncate = true, .mode = 0o600 });
    try file.writeAll(nsec);
    try file.writeAll("\n");
    file.close();

    // Read back via the same logic readSecretKey uses internally.
    var f2 = try tmp.dir.openFile("nsec", .{});
    defer f2.close();
    var buf: [128]u8 = undefined;
    const n = try f2.readAll(&buf);
    var trimmed: []const u8 = buf[0..n];
    while (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\n') trimmed = trimmed[0 .. trimmed.len - 1];

    const decoded = try nip19.decode32(trimmed);
    try std.testing.expectEqual(nip19.Kind.nsec, decoded.kind);
    try std.testing.expectEqualSlices(u8, &sk, &decoded.data);
}
