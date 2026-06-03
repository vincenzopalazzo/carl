//! Config for Carl's Pubky integration: hex secret key, homeserver pubkey, Nexus base URL.

const std = @import("std");
const Allocator = std.mem.Allocator;
const pubky_ffi = @import("pubky_ffi.zig");

const log = std.log.scoped(.pubky_config);

/// Default open testnet homeserver (from Pubky getting-started docs).
pub const default_homeserver = "8pinxxgqs41n4aididenw5apqp1urfmzdztr8jt4abrkdn435ewo";
pub const default_nexus_base = "https://nexus.pubky.app";

pub fn configDir(allocator: Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg| {
        defer allocator.free(xdg);
        return try std.fmt.allocPrint(allocator, "{s}/carl", .{xdg});
    } else |_| {}

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return error.NoConfigDir;
    defer allocator.free(home);
    return try std.fmt.allocPrint(allocator, "{s}/.config/carl", .{home});
}

pub fn ensureConfigDir(allocator: Allocator) ![]u8 {
    const dir = try configDir(allocator);
    errdefer allocator.free(dir);
    std.fs.cwd().makePath(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return dir;
}

pub fn writeSecretKey(allocator: Allocator, secret_hex: []const u8) !void {
    const dir = try ensureConfigDir(allocator);
    defer allocator.free(dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/pubky_secret", .{dir});
    defer allocator.free(path);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.chmod(0o600);
    try file.writeAll(secret_hex);
    try file.writeAll("\n");
}

pub fn readSecretKey(allocator: Allocator) ![]u8 {
    const dir = try configDir(allocator);
    defer allocator.free(dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/pubky_secret", .{dir});
    defer allocator.free(path);
    var file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.NoKey,
        else => return err,
    };
    defer file.close();
    const data = try file.readToEndAlloc(allocator, 256);
    return trimLine(allocator, data);
}

pub fn writeHomeserver(allocator: Allocator, homeserver: []const u8) !void {
    const dir = try ensureConfigDir(allocator);
    defer allocator.free(dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/pubky_homeserver", .{dir});
    defer allocator.free(path);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true, .mode = 0o644 });
    defer file.close();
    try file.writeAll(homeserver);
    try file.writeAll("\n");
}

pub fn readHomeserver(allocator: Allocator) ![]u8 {
    const dir = try configDir(allocator);
    defer allocator.free(dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/pubky_homeserver", .{dir});
    defer allocator.free(path);
    var file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            const dup = try allocator.dupe(u8, default_homeserver);
            return dup;
        },
        else => return err,
    };
    defer file.close();
    const data = try file.readToEndAlloc(allocator, 256);
    const trimmed = try trimLine(allocator, data);
    if (trimmed.len == 0) {
        allocator.free(trimmed);
        return try allocator.dupe(u8, default_homeserver);
    }
    return trimmed;
}

pub fn readNexusBase(allocator: Allocator) ![]u8 {
    const dir = try configDir(allocator);
    defer allocator.free(dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/pubky_nexus", .{dir});
    defer allocator.free(path);
    var file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return try allocator.dupe(u8, default_nexus_base),
        else => return err,
    };
    defer file.close();
    const data = try file.readToEndAlloc(allocator, 256);
    const trimmed = try trimLine(allocator, data);
    if (trimmed.len == 0) {
        allocator.free(trimmed);
        return try allocator.dupe(u8, default_nexus_base);
    }
    return trimmed;
}

pub fn readPublicIdentity(allocator: Allocator) !struct { secret: []const u8, z32: []const u8, uri: []const u8 } {
    const secret = try readSecretKey(allocator);
    errdefer allocator.free(secret);
    const id = try pubky_ffi.publicKeyFromSecret(allocator, secret);
    return .{
        .secret = secret,
        .z32 = id.public_key,
        .uri = id.uri,
    };
}

fn trimLine(allocator: Allocator, data: []const u8) ![]u8 {
    var end = data.len;
    while (end > 0 and (data[end - 1] == '\n' or data[end - 1] == '\r' or data[end - 1] == ' ' or data[end - 1] == '\t')) {
        end -= 1;
    }
    var start: usize = 0;
    while (start < end and (data[start] == ' ' or data[start] == '\t')) start += 1;
    if (start == 0 and end == data.len) return try allocator.dupe(u8, data);
    return try allocator.dupe(u8, data[start..end]);
}

test "default homeserver constant" {
    try std.testing.expect(default_homeserver.len > 10);
}
