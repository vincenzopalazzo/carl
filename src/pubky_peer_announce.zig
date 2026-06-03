//! Peer announce JSON on Pubky (`/pub/carl.app/announces/{infohash}.json`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const secp = @import("secp.zig");
const peer_announce_mod = @import("peer_announce.zig");

pub const Error = error{
    InvalidJson,
    MissingInfoHash,
    InvalidInfoHash,
    BadEndpoint,
    UnsafeIp,
    OutOfMemory,
};

pub const Endpoint = peer_announce_mod.Endpoint;

pub const PeerAnnounce = struct {
    info_hash: [20]u8,
    endpoint: Endpoint,
    pubky_z32: []const u8,
    updated_at: i64,
};

pub fn announcePath(info_hash: [20]u8, buf: *[80]u8) []const u8 {
    var ih_hex: [40]u8 = undefined;
    secp.toHex(&info_hash, &ih_hex);
    return std.fmt.bufPrint(buf, "/pub/carl.app/announces/{s}.json", .{&ih_hex}) catch unreachable;
}

pub fn buildJsonIpv4(
    allocator: Allocator,
    info_hash: [20]u8,
    ip: [4]u8,
    port: u16,
    pubky_z32: []const u8,
) ![]u8 {
    if (!peer_announce_mod.isRoutable(ip)) return error.UnsafeIp;
    var ih_hex: [40]u8 = undefined;
    secp.toHex(&info_hash, &ih_hex);
    return std.fmt.allocPrint(allocator, "{{\"info_hash\":\"{s}\",\"endpoint\":{{\"type\":\"ipv4\",\"ip\":\"{d}.{d}.{d}.{d}\",\"port\":{d}}},\"client\":\"carl/0.1\",\"pubky\":\"{s}\",\"updated_at\":{d}}}", .{
        &ih_hex,
        ip[0],
        ip[1],
        ip[2],
        ip[3],
        port,
        pubky_z32,
        std.time.timestamp(),
    });
}

pub fn buildJsonOnion(
    allocator: Allocator,
    info_hash: [20]u8,
    onion_host: []const u8,
    port: u16,
    pubky_z32: []const u8,
) ![]u8 {
    if (!peer_announce_mod.isValidV3OnionHost(onion_host)) return error.BadEndpoint;
    var ih_hex: [40]u8 = undefined;
    secp.toHex(&info_hash, &ih_hex);
    return std.fmt.allocPrint(allocator, "{{\"info_hash\":\"{s}\",\"endpoint\":{{\"type\":\"onion\",\"host\":\"{s}\",\"port\":{d}}},\"client\":\"carl/0.1\",\"pubky\":\"{s}\",\"updated_at\":{d}}}", .{
        &ih_hex,
        onion_host,
        port,
        pubky_z32,
        std.time.timestamp(),
    });
}

pub fn parseJson(allocator: Allocator, text: []const u8, default_pubky: []const u8) Error!PeerAnnounce {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    const obj = parsed.value.object;

    const ih_str = obj.get("info_hash") orelse return error.MissingInfoHash;
    const ih_text = switch (ih_str) {
        .string => |s| s,
        else => return error.InvalidInfoHash,
    };
    if (ih_text.len != 40) return error.InvalidInfoHash;
    var info_hash: [20]u8 = undefined;
    secp.fromHex(ih_text, &info_hash) catch return error.InvalidInfoHash;

    const ep_val = obj.get("endpoint") orelse return error.BadEndpoint;
    if (ep_val != .object) return error.BadEndpoint;
    const ep = ep_val.object;
    const ty = ep.get("type") orelse return error.BadEndpoint;
    const type_str = switch (ty) {
        .string => |s| s,
        else => return error.BadEndpoint,
    };

    const endpoint: Endpoint = if (std.mem.eql(u8, type_str, "onion")) blk: {
        const host = ep.get("host") orelse return error.BadEndpoint;
        const host_str = switch (host) {
            .string => |s| s,
            else => return error.BadEndpoint,
        };
        if (!peer_announce_mod.isValidV3OnionHost(host_str)) return error.BadEndpoint;
        const port_v = ep.get("port") orelse return error.BadEndpoint;
        const port: u16 = switch (port_v) {
            .integer => |i| @intCast(i),
            else => return error.BadEndpoint,
        };
        break :blk .{ .onion = .{ .host = host_str, .port = port } };
    } else if (std.mem.eql(u8, type_str, "ipv4")) blk: {
        const ip_v = ep.get("ip") orelse return error.BadEndpoint;
        const ip_str = switch (ip_v) {
            .string => |s| s,
            else => return error.BadEndpoint,
        };
        const ip = parseIpv4(ip_str) orelse return error.BadEndpoint;
        if (!peer_announce_mod.isRoutable(ip)) return error.UnsafeIp;
        const port_v = ep.get("port") orelse return error.BadEndpoint;
        const port: u16 = switch (port_v) {
            .integer => |i| @intCast(i),
            else => return error.BadEndpoint,
        };
        break :blk .{ .ipv4 = .{ .ip = ip, .port = port } };
    } else return error.BadEndpoint;

    const pubky_z32 = if (obj.get("pubky")) |pubky_field| switch (pubky_field) {
        .string => |s| try allocator.dupe(u8, s),
        else => try allocator.dupe(u8, default_pubky),
    } else try allocator.dupe(u8, default_pubky);

    const updated_at: i64 = if (obj.get("updated_at")) |updated| switch (updated) {
        .integer => |i| i,
        else => 0,
    } else 0;

    return .{
        .info_hash = info_hash,
        .endpoint = endpoint,
        .pubky_z32 = pubky_z32,
        .updated_at = updated_at,
    };
}

fn parseIpv4(s: []const u8) ?[4]u8 {
    var result: [4]u8 = undefined;
    var octet: usize = 0;
    var start: usize = 0;
    for (s, 0..) |c, i| {
        if (c == '.') {
            if (octet >= 3) return null;
            const v = std.fmt.parseUnsigned(u8, s[start..i], 10) catch return null;
            result[octet] = v;
            octet += 1;
            start = i + 1;
        }
    }
    if (octet != 3) return null;
    const v = std.fmt.parseUnsigned(u8, s[start..], 10) catch return null;
    result[3] = v;
    return result;
}

test "buildJsonIpv4 rejects loopback" {
    const allocator = std.testing.allocator;
    var ih: [20]u8 = undefined;
    @memset(&ih, 1);
    try std.testing.expectError(error.UnsafeIp, buildJsonIpv4(allocator, ih, .{ 127, 0, 0, 1 }, 6881, "testpubky"));
}
