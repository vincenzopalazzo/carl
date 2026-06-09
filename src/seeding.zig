//! Shared seeding helpers used by BOTH the CLI (`carl seed`) and the daemon
//! (`Manager.addSeed`), so a seed created from the desktop UI behaves exactly
//! like one created on the command line — same Nostr events, same relays, same
//! routing. Previously the CLI published a NIP-35 metadata event *and* a
//! dialable peer-announce while the daemon published only the metadata, so a
//! UI-created Tor seed was discoverable but unreachable (no peer to dial).
//!
//! `publish` emits the torrent's NIP-35 discovery event (kind 2003) and, when
//! `ann` names a reachable endpoint, a peer-announce (kind 30078) carrying the
//! `.onion` host or routable IPv4 a leecher needs to connect.

const std = @import("std");
const Allocator = std.mem.Allocator;

const metainfo = @import("metainfo.zig");
const nip35 = @import("nip35.zig");
const peer_announce = @import("peer_announce.zig");
const nostr = @import("nostr.zig");
const relay = @import("relay.zig");
const nostr_config = @import("nostr_config.zig");
const secp = @import("secp.zig");
const proxy_mod = @import("proxy.zig");

const log = std.log.scoped(.seeding);

/// The reachable endpoint to advertise for a seed.
pub const Announce = union(enum) {
    /// Discovery metadata only (NIP-35); no dialable peer-announce. Used when
    /// the seed has no routable endpoint (e.g. a plain direct/proxy seed).
    none,
    /// Tor hidden service: advertise the v3 `.onion` host + virtual port.
    onion: struct { host: []const u8, port: u16 },
    /// Classic public seed: advertise a routable IPv4 + port.
    ipv4: struct { ip: [4]u8, port: u16 },
};

/// Publish a torrent's NIP-35 discovery event (kind 2003) and, when `ann` names
/// a reachable endpoint, a peer-announce (kind 30078) so leechers can dial the
/// seeder. `proxy` routes the relay connections (e.g. Tor SOCKS) so publishing
/// doesn't leak. Propagates `readSecretKey`'s error (e.g. `error.NoKey` when no
/// identity is configured) so callers can report the real reason.
pub fn publish(
    allocator: Allocator,
    mi: metainfo.Metainfo,
    info_hash: [20]u8,
    ann: Announce,
    description: []const u8,
    proxy: ?proxy_mod.Proxy,
) !void {
    const sk = try nostr_config.readSecretKey(allocator);
    const pk = try secp.publicKeyFromSecret(sk);

    var torrent_ev = try nip35.buildFromMetainfo(allocator, sk, pk, mi, info_hash, description);
    defer torrent_ev.deinit(allocator);

    const announce_ev: ?nostr.Event = switch (ann) {
        .none => null,
        .onion => |o| try peer_announce.buildOnion(allocator, sk, pk, info_hash, o.host, o.port),
        .ipv4 => |v| try peer_announce.build(allocator, sk, pk, info_hash, v.ip, v.port),
    };
    defer if (announce_ev) |ev| ev.deinit(allocator);

    const relay_urls = try nostr_config.readRelays(allocator);
    defer nostr_config.freeRelays(allocator, relay_urls);

    var torrent_acks: usize = 0;
    var announce_acks: usize = 0;
    for (relay_urls) |url| {
        var r = relay.Relay.connect(allocator, url, proxy) catch |err| {
            log.warn("nostr publish: {s}: {}", .{ url, err });
            continue;
        };
        defer r.deinit();
        if (relay.publishAndWait(allocator, &r, torrent_ev, 5_000)) torrent_acks += 1;
        if (announce_ev) |ev| {
            if (relay.publishAndWait(allocator, &r, ev, 5_000)) announce_acks += 1;
        }
    }
    log.info("nostr publish: kind-2003 {d}/{d} relays, kind-30078 {d}/{d} relays", .{
        torrent_acks, relay_urls.len, announce_acks, relay_urls.len,
    });
}
