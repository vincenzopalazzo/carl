//! Carl's custom Nostr "peer announce" event — kind 30078, a NIP-33 parameterized
//! replaceable event.
//!
//! Each seeder publishes one of these per torrent. The `d` tag carries the
//! V1 infohash hex, making the event replaceable per (pubkey, infohash) so
//! seeders can refresh `(ip, port)` without spamming the relay. Subscribers
//! filter on `#d=<infohash>` to find current seeders.
//!
//! NIP-33 reserves the 30000-39999 range for parameterized replaceable; 30078
//! is the same kind nostr's `nostr-tools` uses for "app data" — we tag-scope
//! by `d=infohash` so it doesn't collide with other apps.
//!
//! Schema:
//!   {
//!     "kind": 30078,
//!     "tags": [
//!       ["d", "<infohash_hex>"],
//!       ["ip", "<ipv4>"],
//!       ["port", "<port>"],
//!       ["client", "carl/0.1"]
//!     ],
//!     "content": ""
//!   }
//!
//! Carl rejects incoming peer-announce events whose IP is loopback, private,
//! link-local, or unspecified — relays must not be able to redirect peers to
//! attacker-controlled networks.

const std = @import("std");
const Allocator = std.mem.Allocator;
const nostr = @import("nostr.zig");
const secp = @import("secp.zig");

const log = std.log.scoped(.peer_announce);

pub const kind_peer_announce: u32 = 30078;

pub const Error = error{
    InvalidEvent,
    MissingD,
    BadInfoHash,
    BadIp,
    BadPort,
    UnsafeIp,
    OutOfMemory,
};

/// A peer announce parsed from the network.
pub const PeerAnnounce = struct {
    info_hash: [20]u8,
    ip: [4]u8,
    port: u16,
    pubkey: [32]u8,
    created_at: i64,
};

/// Build and sign a kind-30078 event announcing that `pk` is seeding
/// `info_hash` at `ip:port`.
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

    var tag_list: std.ArrayList(nostr.Tag) = .empty;
    errdefer freeTagList(allocator, &tag_list);

    try appendTag(allocator, &tag_list, &[_][]const u8{ "d", &infohash_hex });
    try appendTag(allocator, &tag_list, &[_][]const u8{ "ip", ip_str });
    try appendTag(allocator, &tag_list, &[_][]const u8{ "port", port_str });
    try appendTag(allocator, &tag_list, &[_][]const u8{ "client", "carl/0.1" });

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

/// Parse and validate a kind-30078 event. Returns the announce only if the
/// IP is routable (rejects private/loopback/link-local/unspecified).
/// Caller must have already signature-verified `event`.
pub fn parse(event: nostr.Event) Error!PeerAnnounce {
    if (event.kind != kind_peer_announce) return error.InvalidEvent;

    const d = event.firstTagValue("d") orelse return error.MissingD;
    if (d.len != 40) return error.BadInfoHash;
    var info_hash: [20]u8 = undefined;
    secp.fromHex(d, &info_hash) catch return error.BadInfoHash;

    const ip_str = event.firstTagValue("ip") orelse return error.BadIp;
    const ip = parseIpv4(ip_str) orelse return error.BadIp;
    if (!isRoutable(ip)) return error.UnsafeIp;

    const port_str = event.firstTagValue("port") orelse return error.BadPort;
    const port = std.fmt.parseUnsigned(u16, port_str, 10) catch return error.BadPort;
    if (port == 0) return error.BadPort;

    return .{
        .info_hash = info_hash,
        .ip = ip,
        .port = port,
        .pubkey = event.pubkey,
        .created_at = event.created_at,
    };
}

/// Reject loopback (127/8), private (10/8, 172.16/12, 192.168/16), link-local
/// (169.254/16), CGNAT (100.64/10), unspecified (0.0.0.0), broadcast, and
/// multicast (224/4). These are not routable on the public Internet and
/// could be used to redirect a downloader to an attacker-controlled LAN host.
pub fn isRoutable(ip: [4]u8) bool {
    if (ip[0] == 0) return false; // 0.0.0.0/8
    if (ip[0] == 127) return false; // loopback
    if (ip[0] == 10) return false; // 10/8
    if (ip[0] == 172 and (ip[1] >= 16 and ip[1] <= 31)) return false; // 172.16/12
    if (ip[0] == 192 and ip[1] == 168) return false; // 192.168/16
    if (ip[0] == 169 and ip[1] == 254) return false; // 169.254/16
    if (ip[0] == 100 and (ip[1] >= 64 and ip[1] <= 127)) return false; // CGNAT
    if (ip[0] >= 224 and ip[0] <= 239) return false; // multicast
    if (ip[0] >= 240) return false; // reserved
    if (ip[0] == 255 and ip[1] == 255 and ip[2] == 255 and ip[3] == 255) return false; // broadcast
    return true;
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

test "build + parse round trip" {
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
    try std.testing.expectEqualSlices(u8, &[_]u8{ 203, 0, 113, 7 }, &ann.ip);
    try std.testing.expectEqual(@as(u16, 6881), ann.port);
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

test "parse rejects loopback" {
    const allocator = std.testing.allocator;
    var sk: secp.SecretKey = undefined;
    try secp.fromHex("0000000000000000000000000000000000000000000000000000000000000003", &sk);
    const pk = try secp.publicKeyFromSecret(sk);
    const info_hash: [20]u8 = .{0} ** 20;
    var ev = try build(allocator, sk, pk, info_hash, .{ 127, 0, 0, 1 }, 6881);
    defer ev.deinit(allocator);
    try std.testing.expectError(error.UnsafeIp, parse(ev));
}

test "parse rejects link-local" {
    const allocator = std.testing.allocator;
    var sk: secp.SecretKey = undefined;
    try secp.fromHex("0000000000000000000000000000000000000000000000000000000000000003", &sk);
    const pk = try secp.publicKeyFromSecret(sk);
    const info_hash: [20]u8 = .{0} ** 20;
    var ev = try build(allocator, sk, pk, info_hash, .{ 169, 254, 1, 1 }, 6881);
    defer ev.deinit(allocator);
    try std.testing.expectError(error.UnsafeIp, parse(ev));
}

test "parse rejects multicast" {
    const allocator = std.testing.allocator;
    var sk: secp.SecretKey = undefined;
    try secp.fromHex("0000000000000000000000000000000000000000000000000000000000000003", &sk);
    const pk = try secp.publicKeyFromSecret(sk);
    const info_hash: [20]u8 = .{0} ** 20;
    var ev = try build(allocator, sk, pk, info_hash, .{ 239, 1, 2, 3 }, 6881);
    defer ev.deinit(allocator);
    try std.testing.expectError(error.UnsafeIp, parse(ev));
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
    try std.testing.expect(isRoutable(.{ 1, 1, 1, 1 }));
    try std.testing.expect(isRoutable(.{ 203, 0, 113, 5 }));
    try std.testing.expect(!isRoutable(.{ 0, 0, 0, 0 }));
    try std.testing.expect(!isRoutable(.{ 127, 0, 0, 1 }));
    try std.testing.expect(!isRoutable(.{ 10, 0, 0, 1 }));
    try std.testing.expect(!isRoutable(.{ 172, 20, 0, 1 }));
    try std.testing.expect(!isRoutable(.{ 192, 168, 0, 1 }));
    try std.testing.expect(!isRoutable(.{ 169, 254, 0, 1 }));
    try std.testing.expect(!isRoutable(.{ 100, 64, 0, 1 }));
    try std.testing.expect(!isRoutable(.{ 255, 255, 255, 255 }));
}
