//! `carl follow` — mirror every torrent a Nostr pubkey publishes (NIP-35).
//!
//! A follow node subscribes to a publisher's kind-2003 torrent events
//! (NIP-35), downloads each torrent it hasn't mirrored yet (BEP 9 magnet-style
//! bootstrap, peers discovered via kind-30078 peer-announces), and re-seeds it
//! indefinitely — publishing its OWN kind-30078 peer-announce under the local
//! Nostr identity so other leechers can dial the mirror too. The result: seed
//! a file on a laptop, and a follow server elsewhere picks it up and keeps it
//! alive.
//!
//! Two-phase lifecycle per torrent, both restart-safe:
//!   1. download — outbound-only session (metadata via BEP 9 when no .torrent
//!      is saved yet); the resolved `.torrent` is checkpointed to
//!      `<dir>/<infohash>.follow.torrent` so a restart resumes from disk.
//!   2. seed — a fresh session built from the resolved metainfo. On the i2p
//!      route this mirrors `carl seed --i2p-seed`: a SAM session with a
//!      persisted destination (stable `.b32.i2p` across restarts) feeding a
//!      loopback listener via STREAM FORWARD. On the direct route it binds a
//!      public listener and announces `--external-ip` when given.
//!
//! Routes: `direct` and `i2p`. The tor route needs per-mirror hidden services
//! (ControlPort wiring) and is a follow-up.

const std = @import("std");
const Allocator = std.mem.Allocator;

const nostr = @import("nostr.zig");
const nip19 = @import("nip19.zig");
const nip35 = @import("nip35.zig");
const relay_mod = @import("relay.zig");
const nostr_config = @import("nostr_config.zig");
const peer_announce = @import("peer_announce.zig");
const session_mod = @import("session.zig");
const metainfo_mod = @import("metainfo.zig");
const extension = @import("extension.zig");
const i2p_sam = @import("i2p_sam.zig");
const i2p_seed = @import("i2p_seed.zig");
const secp = @import("secp.zig");
const api = @import("api.zig");

const log = std.log.scoped(.follow);

pub const Error = error{
    InvalidPubkey,
    UnsupportedRoute,
    BadSamBridge,
    SamFailed,
    SessionInitFailed,
    SessionFailed,
    Incomplete,
    InvalidTorrent,
    NoListener,
    OutOfMemory,
};

/// Suffix for checkpointed torrents in the mirror dir. The basename is the
/// 40-char infohash hex, so `resumeSaved` can recover the hash from the name.
pub const torrent_suffix = ".follow.torrent";

pub const Options = struct {
    /// The publisher to follow (x-only pubkey).
    pubkey: [32]u8,
    /// Mirror transport: `direct` or `i2p`.
    route: api.Route = .direct,
    /// Where downloaded data + checkpointed torrents live.
    dir: []const u8,
    /// SAM bridge for the i2p route.
    i2p_sam: []const u8 = "127.0.0.1:7656",
    /// Routable IPv4 to put in direct-route peer-announces. Without it a
    /// direct mirror still seeds, but publishes no dialable announce.
    external_ip: ?[4]u8 = null,
    /// Seconds between relay polls for new kind-2003 events.
    poll_interval_s: u64 = 60,
    /// Cap on concurrently mirrored torrents (defends against a flooding
    /// publisher filling the disk).
    max_mirrors: usize = 128,
};

/// Parse a follow target: an `npub1...` (NIP-19) or a 64-char hex pubkey.
pub fn parsePubkeyArg(arg: []const u8) Error![32]u8 {
    if (std.mem.startsWith(u8, arg, "npub1")) {
        const dec = nip19.decode32(arg) catch return error.InvalidPubkey;
        if (dec.kind != .npub) return error.InvalidPubkey;
        return dec.data;
    }
    if (arg.len == 64) {
        var pk: [32]u8 = undefined;
        secp.fromHex(arg, &pk) catch return error.InvalidPubkey;
        return pk;
    }
    return error.InvalidPubkey;
}

/// Recover the infohash from a checkpointed torrent's filename
/// (`<40 hex>.follow.torrent`), or null if the name isn't one of ours.
pub fn hashFromSavedName(name: []const u8) ?[20]u8 {
    if (name.len != 40 + torrent_suffix.len) return null;
    if (!std.mem.endsWith(u8, name, torrent_suffix)) return null;
    var hash: [20]u8 = undefined;
    secp.fromHex(name[0..40], &hash) catch return null;
    return hash;
}

const Mirror = struct {
    allocator: Allocator,
    opts: Options,
    mutex: std.Thread.Mutex = .{},
    transfers: std.ArrayList(*Transfer) = .empty,

    fn count(self: *Mirror) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.transfers.items.len;
    }

    fn hasInfoHash(self: *Mirror, hash: [20]u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.transfers.items) |t| {
            if (std.mem.eql(u8, &t.info_hash, &hash)) return true;
        }
        return false;
    }
};

const Transfer = struct {
    allocator: Allocator,
    mirror: *Mirror,
    info_hash: [20]u8,
    hash_hex: [40]u8,
    /// Display title from the NIP-35 event (may be empty). Owned.
    title: []u8,
    /// Tracker URLs from the NIP-35 event. Owned.
    trackers: [][]u8,
    /// `<dir>/<infohash>.follow.torrent`. Owned.
    torrent_path: []u8,
    thread: ?std.Thread = null,

    fn destroy(self: *Transfer) void {
        const a = self.allocator;
        a.free(self.title);
        for (self.trackers) |t| a.free(t);
        a.free(self.trackers);
        a.free(self.torrent_path);
        a.destroy(self);
    }
};

fn sigintHandler(_: i32) callconv(.c) void {
    session_mod.shutdown_requested.store(true, .release);
}

fn shuttingDown() bool {
    return session_mod.shutdown_requested.load(.acquire);
}

/// Run the follow loop until SIGINT. Blocks.
pub fn run(allocator: Allocator, opts: Options) !void {
    std.fs.cwd().makePath(opts.dir) catch {};

    var pk_hex: [64]u8 = undefined;
    secp.toHex(&opts.pubkey, &pk_hex);
    {
        const npub = nip19.encode32(allocator, .npub, opts.pubkey) catch null;
        defer if (npub) |n| allocator.free(n);
        log.info("following {s} (route {s}, dir {s})", .{
            npub orelse @as([]const u8, &pk_hex), @tagName(opts.route), opts.dir,
        });
    }

    // The mirror publishes its own peer-announces; without a local identity it
    // still seeds, but nobody can discover it. Say so once, up front.
    if (nostr_config.readSecretKey(allocator)) |_| {} else |_| {
        log.warn("no nostr identity found; mirrored seeds won't be announced. Run `carl nostr-keygen` first.", .{});
    }

    const act = std.posix.Sigaction{
        .handler = .{ .handler = sigintHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);

    var mirror = Mirror{ .allocator = allocator, .opts = opts };
    defer {
        // Threads observe the shutdown flag inside their session loops; join
        // them before freeing anything they borrow.
        for (mirror.transfers.items) |t| {
            if (t.thread) |th| th.join();
            t.destroy();
        }
        mirror.transfers.deinit(allocator);
    }

    resumeSaved(&mirror);

    while (!shuttingDown()) {
        pollOnce(&mirror, &pk_hex);
        // Sleep the poll interval in small slices so Ctrl-C lands promptly.
        var slept_ms: u64 = 0;
        while (!shuttingDown() and slept_ms < opts.poll_interval_s * 1000) {
            std.Thread.sleep(200 * std.time.ns_per_ms);
            slept_ms += 200;
        }
    }
    log.info("shutting down; stopping {d} mirror(s)...", .{mirror.count()});
}

/// Re-add every checkpointed torrent in the mirror dir, so a restart resumes
/// (and re-seeds) without waiting for relays.
fn resumeSaved(mirror: *Mirror) void {
    var dir = std.fs.cwd().openDir(mirror.opts.dir, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        const hash = hashFromSavedName(entry.name) orelse continue;
        if (mirror.hasInfoHash(hash)) continue;
        startTransfer(mirror, hash, "", &.{}) catch |err| {
            log.warn("could not resume saved torrent {s}: {}", .{ entry.name, err });
        };
        log.info("resuming saved torrent {s}", .{entry.name});
    }
}

/// One relay sweep: fetch the publisher's kind-2003 events and start a mirror
/// for every infohash we don't have yet.
fn pollOnce(mirror: *Mirror, pk_hex: *const [64]u8) void {
    const a = mirror.allocator;

    const relay_urls = nostr_config.readRelays(a) catch return;
    defer nostr_config.freeRelays(a, relay_urls);

    var authors_arr = [_][]const u8{pk_hex};
    const filter: nostr.Filter = .{
        .authors = &authors_arr,
        .kinds = &[_]u32{nip35.kind_torrent},
        .limit = 500,
    };

    var started: usize = 0;
    for (relay_urls) |url| {
        if (shuttingDown()) return;
        var r = relay_mod.Relay.connect(a, url, null) catch |err| {
            log.debug("relay {s}: {}", .{ url, err });
            continue;
        };
        defer r.deinit();
        const events = relay_mod.subscribeAndCollect(a, &r, filter, .{
            .timeout_ms = 10_000,
            .max_events = 500,
            .verify_signatures = true,
        }) catch continue;
        defer {
            for (events) |e| e.deinit(a);
            a.free(events);
        }
        for (events) |ev| {
            // The authors filter is relay-side and untrusted; the signature
            // check only proves the event matches its *claimed* pubkey. Make
            // sure that pubkey is the one we follow.
            if (!std.mem.eql(u8, &ev.pubkey, &mirror.opts.pubkey)) continue;
            const entry = nip35.parseEvent(a, ev) catch continue;
            defer entry.deinit(a);
            if (mirror.hasInfoHash(entry.info_hash)) continue;
            if (mirror.count() >= mirror.opts.max_mirrors) {
                log.warn("mirror cap ({d}) reached; skipping new torrents", .{mirror.opts.max_mirrors});
                return;
            }
            startTransfer(mirror, entry.info_hash, entry.title, entry.trackers) catch |err| {
                log.warn("could not start mirror for {s}: {}", .{ entry.title, err });
                continue;
            };
            started += 1;
            log.info("new torrent from publisher: {s}", .{entry.title});
        }
    }
    if (started > 0) log.info("started {d} new mirror(s)", .{started});
}

/// Create the Transfer, register it (so dedupe sees it immediately), and spawn
/// its mirror thread.
fn startTransfer(
    mirror: *Mirror,
    info_hash: [20]u8,
    title: []const u8,
    trackers: []const []const u8,
) Error!void {
    const a = mirror.allocator;

    var hash_hex: [40]u8 = undefined;
    secp.toHex(&info_hash, &hash_hex);

    const title_dup = a.dupe(u8, title) catch return error.OutOfMemory;
    errdefer a.free(title_dup);

    var tr_list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (tr_list.items) |s| a.free(s);
        tr_list.deinit(a);
    }
    for (trackers) |tr| {
        const dup = a.dupe(u8, tr) catch return error.OutOfMemory;
        tr_list.append(a, dup) catch {
            a.free(dup);
            return error.OutOfMemory;
        };
    }
    const tr_owned = tr_list.toOwnedSlice(a) catch return error.OutOfMemory;
    errdefer {
        for (tr_owned) |s| a.free(s);
        a.free(tr_owned);
    }

    const torrent_path = std.fmt.allocPrint(a, "{s}/{s}{s}", .{ mirror.opts.dir, &hash_hex, torrent_suffix }) catch
        return error.OutOfMemory;
    errdefer a.free(torrent_path);

    const t = a.create(Transfer) catch return error.OutOfMemory;
    t.* = .{
        .allocator = a,
        .mirror = mirror,
        .info_hash = info_hash,
        .hash_hex = hash_hex,
        .title = title_dup,
        .trackers = tr_owned,
        .torrent_path = torrent_path,
    };

    mirror.mutex.lock();
    mirror.transfers.append(a, t) catch {
        mirror.mutex.unlock();
        // Raw destroy: the owned pieces are still freed by the errdefers above
        // (t.destroy() here would double-free them).
        a.destroy(t);
        return error.OutOfMemory;
    };
    mirror.mutex.unlock();

    t.thread = std.Thread.spawn(.{}, mirrorThread, .{t}) catch {
        // Leave the (threadless) entry registered: removing it would require
        // unwinding ownership mid-list; the next restart retries it.
        log.warn("could not spawn mirror thread for {s}", .{&t.hash_hex});
        return;
    };
}

fn mirrorThread(t: *Transfer) void {
    mirrorTorrent(t) catch |err| {
        if (shuttingDown()) return;
        log.warn("mirror {s} ({s}) stopped: {}", .{ &t.hash_hex, t.title, err });
    };
}

fn mirrorTorrent(t: *Transfer) Error!void {
    const a = t.allocator;

    // Phase 1 — get the data (and the resolved metainfo) onto disk.
    const mi = try ensureDownloaded(t);
    defer mi.deinit(a);
    if (shuttingDown()) return;

    log.info("mirror {s}: download complete, starting reseed", .{t.title});

    // Phase 2 — reseed forever (until shutdown).
    try seedForever(t, mi);
}

/// Make sure the torrent's data is fully on disk. Returns the resolved
/// metainfo (caller owns). Uses the checkpointed `.torrent` when present
/// (restart path); otherwise bootstraps metadata over BEP 9 and checkpoints it.
fn ensureDownloaded(t: *Transfer) Error!metainfo_mod.Metainfo {
    const a = t.allocator;

    if (std.fs.cwd().readFileAlloc(a, t.torrent_path, 10 * 1024 * 1024) catch null) |data| {
        defer a.free(data);
        const mi = metainfo_mod.parse(a, data) catch return error.InvalidTorrent;
        errdefer mi.deinit(a);
        try runDownload(t, mi, false);
        return mi;
    }

    // No checkpoint yet: magnet-style bootstrap from the NIP-35 entry.
    {
        const mi = try placeholderMetainfo(a, t);
        defer mi.deinit(a);
        try runDownload(t, mi, true);
    }
    const data = std.fs.cwd().readFileAlloc(a, t.torrent_path, 10 * 1024 * 1024) catch
        return error.InvalidTorrent;
    defer a.free(data);
    return metainfo_mod.parse(a, data) catch error.InvalidTorrent;
}

/// Build the placeholder metainfo a magnet-style session starts from: just the
/// display name and the NIP-35 trackers; geometry arrives with the metadata.
fn placeholderMetainfo(a: Allocator, t: *Transfer) Error!metainfo_mod.Metainfo {
    const name = a.dupe(u8, if (t.title.len > 0) t.title else "unknown") catch return error.OutOfMemory;
    errdefer a.free(name);

    const path0 = a.alloc([]const u8, 1) catch return error.OutOfMemory;
    errdefer a.free(path0);
    path0[0] = a.dupe(u8, name) catch return error.OutOfMemory;
    errdefer a.free(path0[0]);

    const files = a.alloc(metainfo_mod.FileInfo, 1) catch return error.OutOfMemory;
    errdefer a.free(files);
    files[0] = .{ .length = 0, .path = path0 };

    var announce_list: ?[]const []const []const u8 = null;
    errdefer if (announce_list) |tiers| {
        for (tiers) |tier| {
            for (tier) |tr| a.free(tr);
            a.free(tier);
        }
        a.free(tiers);
    };
    if (t.trackers.len > 0) {
        const tier = a.alloc([]const u8, t.trackers.len) catch return error.OutOfMemory;
        var filled: usize = 0;
        errdefer {
            for (tier[0..filled]) |tr| a.free(tr);
            a.free(tier);
        }
        while (filled < t.trackers.len) : (filled += 1) {
            tier[filled] = a.dupe(u8, t.trackers[filled]) catch return error.OutOfMemory;
        }
        const tiers = a.alloc([]const []const u8, 1) catch return error.OutOfMemory;
        tiers[0] = tier;
        announce_list = tiers;
    }

    const announce = a.dupe(u8, if (t.trackers.len > 0) t.trackers[0] else "") catch return error.OutOfMemory;
    errdefer a.free(announce);

    return .{
        .announce = announce,
        .announce_list = announce_list,
        .name = name,
        .piece_length = 0,
        .pieces = &.{},
        .files = files,
        .comment = null,
        .creation_date = null,
        .created_by = null,
        .raw_info = &.{},
        .url_list = null,
    };
}

/// Phase 1: run an outbound-only download session to completion. With
/// `magnet`, the session bootstraps metadata over BEP 9 and we checkpoint the
/// resolved `.torrent` (even on an incomplete run, so the next attempt skips
/// the bootstrap). Peers come from kind-30078 announces, re-queried by the
/// session whenever it has none.
fn runDownload(t: *Transfer, mi: metainfo_mod.Metainfo, magnet: bool) Error!void {
    const a = t.allocator;
    const opts = t.mirror.opts;

    var i2p_session: ?i2p_sam.Session = null;
    defer if (i2p_session) |*s| s.deinit();
    if (opts.route == .i2p) {
        const bridge = i2p_sam.parseUrl(opts.i2p_sam) catch return error.BadSamBridge;
        i2p_session = i2p_sam.Session.create(a, bridge, "carl-follow") catch |err| {
            log.warn("i2p SAM session failed: {} (is the router running with SAM enabled?)", .{err});
            return error.SamFailed;
        };
    }
    const i2p_ptr: ?*i2p_sam.Session = if (i2p_session) |*s| s else null;

    const port = pickFreePort(false) orelse 6881;
    var session = session_mod.Session.init(a, mi, opts.dir, .download, port, null, .any, false, i2p_ptr, false) catch
        return error.SessionInitFailed;
    defer session.deinit();
    if (magnet) {
        session.info_hash = t.info_hash;
        session.metadata_download = extension.MetadataDownload.init(a, t.info_hash);
        session.metadata_only = true;
    }
    // Phase 1 must RETURN on completion (phase 2 builds the real seed session).
    session.seed_after_complete = false;
    session.setPeerDiscovery(&session, rediscoverPeersCb);
    discoverPeers(a, t.info_hash, &session);

    session.run() catch return error.SessionFailed;

    if (magnet) {
        if (session.copyTorrent(a)) |blob| {
            defer a.free(blob);
            writeFileAtomic(t.torrent_path, blob) catch |err| {
                log.warn("could not checkpoint {s}: {}", .{ t.torrent_path, err });
            };
        }
    }

    const p = session.progressSnapshot();
    if (!(p.num_pieces > 0 and p.have >= p.num_pieces)) return error.Incomplete;
}

/// Phase 2: build the seed session for the route and run it until shutdown.
fn seedForever(t: *Transfer, mi: metainfo_mod.Metainfo) Error!void {
    const a = t.allocator;
    const opts = t.mirror.opts;

    switch (opts.route) {
        .i2p => {
            const bridge = i2p_sam.parseUrl(opts.i2p_sam) catch return error.BadSamBridge;
            const port = pickFreePort(true) orelse return error.NoListener;

            // Persisted destination keyed by infohash → stable `.b32.i2p`, so
            // the announce survives restarts (same scheme as `carl seed`).
            const persisted = i2p_seed.load(a, &t.hash_hex) catch null;
            defer if (persisted) |p| a.free(p);
            const dest: i2p_sam.Session.Dest = if (persisted) |p| .{ .priv = p } else .transient;
            var sam = i2p_sam.Session.createWithDest(a, bridge, "carl-follow-seed", dest) catch |err| {
                log.warn("i2p SAM seed session failed: {}", .{err});
                return error.SamFailed;
            };
            defer sam.deinit();
            if (persisted == null) i2p_seed.save(a, &t.hash_hex, sam.destination);

            const host = i2p_sam.b32Address(a, sam.destination) catch return error.SamFailed;
            defer a.free(host);

            var session = session_mod.Session.init(a, mi, opts.dir, .seed, port, null, .loopback, false, &sam, true) catch
                return error.SessionInitFailed;
            defer session.deinit();
            if (session.listener == null) return error.NoListener;
            sam.forward(port) catch {
                log.warn("i2p STREAM FORWARD failed; mirror would be unreachable", .{});
                return error.SamFailed;
            };

            publishAnnounce(a, t.info_hash, .{ .i2p_host = host });
            log.info("mirror seeding {s} at {s}", .{ t.title, host });
            session.run() catch return error.SessionFailed;
        },
        .direct => {
            const port = pickFreePort(false) orelse return error.NoListener;
            var session = session_mod.Session.init(a, mi, opts.dir, .seed, port, null, .any, false, null, false) catch
                return error.SessionInitFailed;
            defer session.deinit();
            if (session.listener == null) return error.NoListener;

            if (opts.external_ip) |ip| {
                publishAnnounce(a, t.info_hash, .{ .ipv4 = .{ .ip = ip, .port = port } });
            } else {
                log.warn("no --external-ip; reseeding {s} without a dialable announce", .{t.title});
            }
            log.info("mirror seeding {s} on port {d}", .{ t.title, port });
            session.run() catch return error.SessionFailed;
        },
        else => return error.UnsupportedRoute,
    }
}

const AnnounceEndpoint = union(enum) {
    i2p_host: []const u8,
    ipv4: struct { ip: [4]u8, port: u16 },
};

/// Publish our kind-30078 peer-announce for a mirrored torrent under the local
/// identity. Best-effort: without a key (or with all relays down) the mirror
/// still seeds; it's just not discoverable, which was warned about at startup.
fn publishAnnounce(a: Allocator, info_hash: [20]u8, endpoint: AnnounceEndpoint) void {
    const sk = nostr_config.readSecretKey(a) catch return;
    const pk = secp.publicKeyFromSecret(sk) catch return;

    const ev = switch (endpoint) {
        .i2p_host => |host| peer_announce.buildI2p(a, sk, pk, info_hash, host, 0),
        .ipv4 => |v| peer_announce.build(a, sk, pk, info_hash, v.ip, v.port),
    } catch |err| {
        log.warn("could not build peer-announce: {}", .{err});
        return;
    };
    defer ev.deinit(a);

    const relay_urls = nostr_config.readRelays(a) catch return;
    defer nostr_config.freeRelays(a, relay_urls);

    var acks: usize = 0;
    for (relay_urls) |url| {
        var r = relay_mod.Relay.connect(a, url, null) catch continue;
        defer r.deinit();
        if (relay_mod.publishAndWait(a, &r, ev, 5_000)) acks += 1;
    }
    log.info("peer-announce published: {d}/{d} relays", .{ acks, relay_urls.len });
}

/// `Session.PeerDiscovery` callback (session thread): re-query announces when
/// the transfer has zero peers.
fn rediscoverPeersCb(ctx: *anyopaque) void {
    const session: *session_mod.Session = @ptrCast(@alignCast(ctx));
    discoverPeers(session.allocator, session.info_hash, session);
}

/// Query relays for kind-30078 peer-announces on `info_hash` and connect every
/// endpoint the session's transport can reach: IPv4 on the direct route, I2P
/// destinations over the SAM transport. (Onion peers need a SOCKS proxy the
/// follow routes don't carry; skipped.)
fn discoverPeers(a: Allocator, info_hash: [20]u8, session: *session_mod.Session) void {
    var ih_hex: [40]u8 = undefined;
    secp.toHex(&info_hash, &ih_hex);

    const relay_urls = nostr_config.readRelays(a) catch return;
    defer nostr_config.freeRelays(a, relay_urls);

    var values_arr = [_][]const u8{&ih_hex};
    var tag_filters = [_]nostr.Filter.TagFilter{.{ .letter = 'd', .values = &values_arr }};
    const filter: nostr.Filter = .{
        .kinds = &[_]u32{peer_announce.kind_peer_announce},
        .tags = &tag_filters,
        .limit = 200,
    };

    var added: usize = 0;
    for (relay_urls) |url| {
        if (!session.running or shuttingDown()) return;
        var r = relay_mod.Relay.connect(a, url, null) catch continue;
        defer r.deinit();
        const events = relay_mod.subscribeAndCollect(a, &r, filter, .{
            .timeout_ms = 10_000,
            .max_events = 200,
            .verify_signatures = true,
        }) catch continue;
        defer {
            for (events) |e| e.deinit(a);
            a.free(events);
        }
        for (events) |ev| {
            const ann = peer_announce.parse(ev) catch continue;
            if (!std.mem.eql(u8, &ann.info_hash, &info_hash)) continue;
            if (added >= 50) break;
            switch (ann.endpoint) {
                .ipv4 => |ep| {
                    if (session.i2p != null) continue; // no clearnet on i2p
                    const addr = std.net.Address.initIp4(ep.ip, ep.port);
                    session.connectDirectPeer(addr) catch continue;
                    added += 1;
                },
                .onion => continue,
                .i2p => |ep| {
                    if (session.i2p == null) continue;
                    session.connectI2pPeer(ep.host, ep.port) catch continue;
                    added += 1;
                },
            }
        }
    }
    if (added > 0) log.info("connected {d} peer(s) from nostr announces", .{added});
}

/// Discover a free port by binding port 0 (loopback for forwarded i2p seeds,
/// 0.0.0.0 for public listeners). Tiny TOCTOU window before the session
/// re-binds; callers treat a later bind failure as fatal for the mirror.
fn pickFreePort(loopback: bool) ?u16 {
    const ip: [4]u8 = if (loopback) .{ 127, 0, 0, 1 } else .{ 0, 0, 0, 0 };
    var server = std.net.Address.initIp4(ip, 0).listen(.{ .reuse_address = true }) catch return null;
    defer server.deinit();
    return server.listen_address.getPort();
}

/// Write via a temp file + rename so a crash mid-write never leaves a torn
/// checkpoint (a torn `.torrent` would wedge the restart path).
fn writeFileAtomic(path: []const u8, data: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&buf, "{s}.tmp", .{path});
    {
        var f = try std.fs.cwd().createFile(tmp, .{ .truncate = true });
        defer f.close();
        try f.writeAll(data);
    }
    try std.fs.cwd().rename(tmp, path);
}

// ===========================================================================
// Tests
// ===========================================================================

test "parsePubkeyArg accepts hex and npub, rejects junk" {
    var pk: [32]u8 = undefined;
    for (&pk, 0..) |*b, i| b.* = @intCast(i);
    var hex: [64]u8 = undefined;
    secp.toHex(&pk, &hex);

    const from_hex = try parsePubkeyArg(&hex);
    try std.testing.expectEqualSlices(u8, &pk, &from_hex);

    const npub = try nip19.encode32(std.testing.allocator, .npub, pk);
    defer std.testing.allocator.free(npub);
    const from_npub = try parsePubkeyArg(npub);
    try std.testing.expectEqualSlices(u8, &pk, &from_npub);

    try std.testing.expectError(error.InvalidPubkey, parsePubkeyArg("not-a-key"));
    try std.testing.expectError(error.InvalidPubkey, parsePubkeyArg("npub1invalid"));
    // nsec must be rejected even though it decodes as valid bech32.
    const nsec = try nip19.encode32(std.testing.allocator, .nsec, pk);
    defer std.testing.allocator.free(nsec);
    try std.testing.expectError(error.InvalidPubkey, parsePubkeyArg(nsec));
}

test "hashFromSavedName round-trips and rejects other files" {
    var hash: [20]u8 = undefined;
    @memset(&hash, 0xAB);
    var hex: [40]u8 = undefined;
    secp.toHex(&hash, &hex);

    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "{s}{s}", .{ &hex, torrent_suffix });
    const got = hashFromSavedName(name) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, &hash, &got);

    try std.testing.expect(hashFromSavedName("data.bin") == null);
    try std.testing.expect(hashFromSavedName("short.follow.torrent") == null);
    // Right length, bad hex.
    const bad = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz.follow.torrent";
    try std.testing.expect(hashFromSavedName(bad) == null);
}

test "placeholderMetainfo carries title and NIP-35 trackers" {
    const a = std.testing.allocator;
    var mirror = Mirror{ .allocator = a, .opts = .{ .pubkey = .{0} ** 32, .dir = "." } };
    var trackers_arr = [_][]u8{ @constCast("http://t1/announce"), @constCast("udp://t2:1337") };
    var t = Transfer{
        .allocator = a,
        .mirror = &mirror,
        .info_hash = .{0xCD} ** 20,
        .hash_hex = .{'c'} ** 40,
        .title = @constCast("My File"),
        .trackers = &trackers_arr,
        .torrent_path = @constCast("unused"),
    };
    const mi = try placeholderMetainfo(a, &t);
    defer mi.deinit(a);
    try std.testing.expectEqualStrings("My File", mi.name);
    try std.testing.expectEqualStrings("http://t1/announce", mi.announce);
    try std.testing.expect(mi.announce_list != null);
    try std.testing.expectEqual(@as(usize, 2), mi.announce_list.?[0].len);
}

test "pickFreePort returns a usable port" {
    const port = pickFreePort(true) orelse return error.TestUnexpectedResult;
    try std.testing.expect(port > 0);
}
