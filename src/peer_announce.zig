//! Carl's custom Nostr "peer announce" event — kind 30078, a NIP-33 parameterized
//! replaceable event.
//!
//! Each seeder publishes one of these per torrent. The `d` tag carries the
//! V1 infohash hex, making the event replaceable per (pubkey, infohash) so
//! seeders can refresh their endpoint without spamming the relay.
//!
//! IPv4 schema:
//!   ["d", "<infohash_hex>"], ["ip", "<ipv4>"], ["port", "<port>"], ["client", "carl/0.1"]
//!
//! Tor hidden-service schema (onion-only, no `ip` tag):
//!   ["d", "<infohash_hex>"], ["host", "<v3.onion>"], ["port", "<port>"], ["client", "carl/0.1"]
//!
//! Carl rejects incoming IPv4 peer-announces whose IP is loopback, private,
//! link-local, or unspecified.

const std = @import("std");
const Allocator = std.mem.Allocator;
const nostr = @import("nostr.zig");
const secp = @import("secp.zig");

pub const kind_peer_announce: u32 = 30078;

/// Tor v3 onion hostname: 56 base32 chars + `.onion` (62 bytes total).
pub const v3_onion_host_len: usize = 62;

pub const Error = error{
    InvalidEvent,
    MissingD,
    BadInfoHash,
    BadIp,
    BadHost,
    BadPort,
    UnsafeIp,
    OutOfMemory,
};

pub const Endpoint = union(enum) {
    ipv4: struct {
        ip: [4]u8,
        port: u16,
    },
    /// `host` is borrowed from the event tag when parsed from the network.
    onion: struct {
        host: []const u8,
        port: u16,
    },
};

/// A peer announce parsed from the network.
pub const PeerAnnounce = struct {
    info_hash: [20]u8,
    endpoint: Endpoint,
    pubkey: [32]u8,
    created_at: i64,
};

/// Build and sign a kind-30078 event for a public IPv4 endpoint.
pub fn build(
    allocator: Allocator,
    sk: secp.SecretKey,
    pk: secp.PublicKey,
    info_hash: [20]u8,
    ip: [4]u8,
    port: u16,
) !nostr.Event {
    var infohash_hex: [40]u8 = undefined;
    secp.toHex(&info_hash, &infohash_hex);

    var ip_buf: [16]u8 = undefined;
    const ip_str = std.fmt.bufPrint(&ip_buf, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch unreachable;
    var port_buf: [6]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch unreachable;

    const d_tag = [_][]const u8{ "d", &infohash_hex };
    const ip_tag = [_][]const u8{ "ip", ip_str };
    const port_tag = [_][]const u8{ "port", port_str };
    const client_tag = [_][]const u8{ "client", "carl/0.1" };
    const tag_sets = [_][]const []const u8{ d_tag[0..], ip_tag[0..], port_tag[0..], client_tag[0..] };
    return buildTagged(allocator, sk, pk, &tag_sets);
}

/// Build and sign a kind-30078 event for a Tor v3 hidden service.
pub fn buildOnion(
    allocator: Allocator,
    sk: secp.SecretKey,
    pk: secp.PublicKey,
    info_hash: [20]u8,
    onion_host: []const u8,
    port: u16,
) !nostr.Event {
    if (!isValidV3OnionHost(onion_host)) return error.BadHost;

    var infohash_hex: [40]u8 = undefined;
    secp.toHex(&info_hash, &infohash_hex);

    var port_buf: [6]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch unreachable;

    const d_tag = [_][]const u8{ "d", &infohash_hex };
    const host_tag = [_][]const u8{ "host", onion_host };
    const port_tag = [_][]const u8{ "port", port_str };
    const client_tag = [_][]const u8{ "client", "carl/0.1" };
    const tag_sets = [_][]const []const u8{ d_tag[0..], host_tag[0..], port_tag[0..], client_tag[0..] };
    return buildTagged(allocator, sk, pk, &tag_sets);
}

/// Parse and validate a kind-30078 event. Supports legacy `ip` tags and `host`
/// tags for `.onion` endpoints. Caller must have already verified the signature.
pub fn parse(event: nostr.Event) Error!PeerAnnounce {
    if (event.kind != kind_peer_announce) return error.InvalidEvent;

    const d = event.firstTagValue("d") orelse return error.MissingD;
    if (d.len != 40) return error.BadInfoHash;
    var info_hash: [20]u8 = undefined;
    secp.fromHex(d, &info_hash) catch return error.BadInfoHash;

    const port_str = event.firstTagValue("port") orelse return error.BadPort;
    const port = std.fmt.parseUnsigned(u16, port_str, 10) catch return error.BadPort;
    if (port == 0) return error.BadPort;

    // Prefer a valid `host` (.onion) over `ip` when both are present so a signed
    // event cannot smuggle a clearnet endpoint alongside an onion hostname.
    if (event.firstTagValue("host")) |host| {
        if (isValidV3OnionHost(host)) {
            return .{
                .info_hash = info_hash,
                .endpoint = .{ .onion = .{ .host = host, .port = port } },
                .pubkey = event.pubkey,
                .created_at = event.created_at,
            };
        }
        return error.BadHost;
    }

    const ip_str = event.firstTagValue("ip") orelse return error.BadIp;
    const ip = parseIpv4(ip_str) orelse return error.BadIp;
    if (!isRoutable(ip)) return error.UnsafeIp;
    return .{
        .info_hash = info_hash,
        .endpoint = .{ .ipv4 = .{ .ip = ip, .port = port } },
        .pubkey = event.pubkey,
        .created_at = event.created_at,
    };
}

/// True for a Tor v3 `.onion` hostname (56-char base32 label + `.onion`).
pub fn isValidV3OnionHost(host: []const u8) bool {
    if (host.len != v3_onion_host_len) return false;
    if (!std.mem.endsWith(u8, host, ".onion")) return false;
    const label = host[0 .. host.len - 6];
    for (label) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '2' and c <= '7');
        if (!ok) return false;
    }
    return true;
}

/// Reject loopback, private, link-local, CGNAT, unspecified, broadcast, multicast.
pub fn isRoutable(ip: [4]u8) bool {
    if (ip[0] == 0) return false;
    if (ip[0] == 127) return false;
    if (ip[0] == 10) return false;
    if (ip[0] == 172 and (ip[1] >= 16 and ip[1] <= 31)) return false;
    if (ip[0] == 192 and ip[1] == 168) return false;
    if (ip[0] == 169 and ip[1] == 254) return false;
    if (ip[0] == 100 and (ip[1] >= 64 and ip[1] <= 127)) return false;
    if (ip[0] >= 224 and ip[0] <= 239) return false;
    if (ip[0] >= 240) return false;
    if (ip[0] == 255 and ip[1] == 255 and ip[2] == 255 and ip[3] == 255) return false;
    return true;
}

fn buildTagged(
    allocator: Allocator,
    sk: secp.SecretKey,
    pk: secp.PublicKey,
    tag_sets: []const []const []const u8,
) !nostr.Event {
    var tag_list: std.ArrayList(nostr.Tag) = .empty;
    errdefer freeTagList(allocator, &tag_list);

    for (tag_sets) |parts| {
        try appendTag(allocator, &tag_list, parts);
    }

    const tags_owned = tag_list.toOwnedSlice(allocator) catch return error.OutOfMemory;
    errdefer {
        for (tags_owned) |t| t.deinit(allocator);
        allocator.free(tags_owned);
    }
    const empty_content = allocator.dupe(u8, "") catch return error.OutOfMemory;

    var ev: nostr.Event = .{
        .id = undefined,
        .pubkey = pk,
        .created_at = std.time.timestamp(),
        .kind = kind_peer_announce,
        .tags = tags_owned,
        .content = empty_content,
        .sig = undefined,
    };
    nostr.sign(&ev, sk, allocator) catch return error.OutOfMemory;
    return ev;
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

// ===========================================================================
// Tests
// ===========================================================================

test "build + parse ipv4 round trip" {
    const allocator = std.testing.allocator;

    var sk: secp.SecretKey = undefined;
    try secp.fromHex("0000000000000000000000000000000000000000000000000000000000000003", &sk);
    const pk = try secp.publicKeyFromSecret(sk);

    var info_hash: [20]u8 = undefined;
    @memset(&info_hash, 0xEF);

    var ev = try build(allocator, sk, pk, info_hash, .{ 203, 0, 113, 7 }, 6881);
    defer ev.deinit(allocator);

    try std.testing.expect(nostr.verify(ev, allocator));

    const ann = try parse(ev);
    try std.testing.expectEqualSlices(u8, &info_hash, &ann.info_hash);
    try std.testing.expect(ann.endpoint == .ipv4);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 203, 0, 113, 7 }, &ann.endpoint.ipv4.ip);
    try std.testing.expectEqual(@as(u16, 6881), ann.endpoint.ipv4.port);
}

test "build + parse onion round trip" {
    const allocator = std.testing.allocator;
    var label: [56]u8 = undefined;
    @memset(&label, 'a');
    var host_buf: [v3_onion_host_len]u8 = undefined;
    const onion = std.fmt.bufPrint(&host_buf, "{s}.onion", .{&label}) catch unreachable;

    var sk: secp.SecretKey = undefined;
    try secp.fromHex("0000000000000000000000000000000000000000000000000000000000000003", &sk);
    const pk = try secp.publicKeyFromSecret(sk);

    const info_hash: [20]u8 = .{0xAB} ** 20;
    var ev = try buildOnion(allocator, sk, pk, info_hash, onion, 80);
    defer ev.deinit(allocator);

    const ann = try parse(ev);
    try std.testing.expect(ann.endpoint == .onion);
    try std.testing.expectEqualStrings(onion, ann.endpoint.onion.host);
    try std.testing.expectEqual(@as(u16, 80), ann.endpoint.onion.port);
}

test "parse rejects private IP" {
    const allocator = std.testing.allocator;

    var sk: secp.SecretKey = undefined;
    try secp.fromHex("0000000000000000000000000000000000000000000000000000000000000003", &sk);
    const pk = try secp.publicKeyFromSecret(sk);

    var info_hash: [20]u8 = undefined;
    @memset(&info_hash, 0xEF);

    var ev = try build(allocator, sk, pk, info_hash, .{ 192, 168, 1, 1 }, 6881);
    defer ev.deinit(allocator);
    try std.testing.expectError(error.UnsafeIp, parse(ev));
}

test "parse rejects bad onion host" {
    const allocator = std.testing.allocator;
    var sk: secp.SecretKey = undefined;
    try secp.fromHex("0000000000000000000000000000000000000000000000000000000000000003", &sk);
    const pk = try secp.publicKeyFromSecret(sk);
    const info_hash: [20]u8 = .{0} ** 20;
    try std.testing.expectError(error.BadHost, buildOnion(allocator, sk, pk, info_hash, "not-an-onion", 80));
}

test "parse rejects wrong kind" {
    const ev: nostr.Event = .{
        .id = .{0} ** 32,
        .pubkey = .{0} ** 32,
        .created_at = 0,
        .kind = 1,
        .tags = &.{},
        .content = "",
        .sig = .{0} ** 64,
    };
    try std.testing.expectError(error.InvalidEvent, parse(ev));
}

test "isRoutable spot checks" {
    try std.testing.expect(isRoutable(.{ 8, 8, 8, 8 }));
    try std.testing.expect(!isRoutable(.{ 127, 0, 0, 1 }));
}

test "isValidV3OnionHost" {
    var label: [56]u8 = undefined;
    @memset(&label, 'a');
    var host_buf: [v3_onion_host_len]u8 = undefined;
    const ok = std.fmt.bufPrint(&host_buf, "{s}.onion", .{&label}) catch unreachable;
    try std.testing.expect(isValidV3OnionHost(ok));
    try std.testing.expect(!isValidV3OnionHost("short.onion"));
    try std.testing.expect(!isValidV3OnionHost("aaaa.com"));
}
