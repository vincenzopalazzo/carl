//! High-level publish/fetch helpers for Carl's Pubky discovery layer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const pubky_ffi = @import("pubky_ffi.zig");
const pubky_config = @import("pubky_config.zig");
const pubky_torrent = @import("pubky_torrent.zig");
const pubky_peer_announce = @import("pubky_peer_announce.zig");
const metainfo_mod = @import("metainfo.zig");

pub fn publishSeedIpv4(
    allocator: Allocator,
    mi: metainfo_mod.Metainfo,
    info_hash: [20]u8,
    description: []const u8,
    ip: [4]u8,
    port: u16,
) !void {
    const id = try pubky_config.readPublicIdentity(allocator);
    defer allocator.free(id.secret);
    defer allocator.free(id.z32);
    defer allocator.free(id.uri);

    const hs = try pubky_config.readHomeserver(allocator);
    defer allocator.free(hs);
    pubky_ffi.signup(allocator, id.secret, hs, null) catch {
        // Already registered users get an error — try signin + put.
        try pubky_ffi.signin(allocator, id.secret);
    };

    var path_buf: [80]u8 = undefined;
    const torrent_path = pubky_torrent.torrentPath(info_hash, &path_buf);
    const torrent_json = try pubky_torrent.buildJson(allocator, mi, info_hash, description, id.z32);
    defer allocator.free(torrent_json);
    try pubky_ffi.put(allocator, id.secret, torrent_path, torrent_json);

    var ann_buf: [80]u8 = undefined;
    const announce_path = pubky_peer_announce.announcePath(info_hash, &ann_buf);
    const announce_json = try pubky_peer_announce.buildJsonIpv4(allocator, info_hash, ip, port, id.z32);
    defer allocator.free(announce_json);
    try pubky_ffi.put(allocator, id.secret, announce_path, announce_json);

    std.log.info("pubky publish: {s} + {s}", .{ torrent_path, announce_path });
}

pub fn publishSeedOnion(
    allocator: Allocator,
    mi: metainfo_mod.Metainfo,
    info_hash: [20]u8,
    description: []const u8,
    onion_host: []const u8,
    onion_port: u16,
) !void {
    const id = try pubky_config.readPublicIdentity(allocator);
    defer allocator.free(id.secret);
    defer allocator.free(id.z32);
    defer allocator.free(id.uri);

    const hs = try pubky_config.readHomeserver(allocator);
    defer allocator.free(hs);
    pubky_ffi.signup(allocator, id.secret, hs, null) catch {
        try pubky_ffi.signin(allocator, id.secret);
    };

    var path_buf: [80]u8 = undefined;
    const torrent_path = pubky_torrent.torrentPath(info_hash, &path_buf);
    const torrent_json = try pubky_torrent.buildJson(allocator, mi, info_hash, description, id.z32);
    defer allocator.free(torrent_json);
    try pubky_ffi.put(allocator, id.secret, torrent_path, torrent_json);

    var ann_buf: [80]u8 = undefined;
    const announce_path = pubky_peer_announce.announcePath(info_hash, &ann_buf);
    const announce_json = try pubky_peer_announce.buildJsonOnion(allocator, info_hash, onion_host, onion_port, id.z32);
    defer allocator.free(announce_json);
    try pubky_ffi.put(allocator, id.secret, announce_path, announce_json);
}
