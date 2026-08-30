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
//!      persisted destination (stable `.b32.i2p` per torrent, key under
//!      `<config>/i2p-seeds/`) feeding a loopback listener via STREAM FORWARD.
//!      On the direct route it binds a public listener and announces
//!      `--external-ip` when given.
//!
//! Routes: `direct` and `i2p`. The tor route needs per-mirror hidden services
//! (ControlPort wiring) and is a follow-up.
//!
//! Two consumers share this module: the blocking CLI entry (`run`, exits on
//! SIGINT) and the daemon (`Mirror.create`/`start`/`stop`/`destroy`, one
//! mirror per followed publisher, with `torrentsSnapshot` feeding the GUI).

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
    ThreadSpawnFailed,
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
    /// Optional subdirectory of `dir` for checkpointed torrents
    /// (`<dir>/<checkpoint_subdir>/<infohash>.follow.torrent`). Null keeps the
    /// historical layout (checkpoints next to the data); `carl follow` never
    /// sets it, so its on-disk layout is byte-identical. The drive module sets
    /// it to `.carl-drive` so checkpoints stay hidden out of the watched
    /// folder (and out of the publisher's own scan).
    checkpoint_subdir: ?[]const u8 = null,
};

/// Lifecycle of one mirrored torrent, for status displays.
pub const Phase = enum(u8) {
    starting,
    downloading,
    seeding,
    failed,

    pub fn jsonName(self: Phase) []const u8 {
        return @tagName(self);
    }
};

/// A snapshot row for one mirrored torrent (strings live in the caller's arena).
pub const TorrentInfo = struct {
    name: []const u8,
    hash_hex: [40]u8,
    phase: Phase,
    pct: u8,
    peers: u32,
    down: u64,
    up: u64,
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

pub const Mirror = struct {
    allocator: Allocator,
    /// Owned copies of the caller's option strings (`dir`, `i2p_sam`), so an
    /// embedded mirror survives the caller mutating its config.
    opts: Options,
    mutex: std.Thread.Mutex = .{},
    transfers: std.ArrayList(*Transfer) = .empty,
    /// Per-mirror stop request (the daemon stops one mirror without stopping
    /// the process). The global `session_mod.shutdown_requested` still stops
    /// everything (SIGINT).
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    poll_thread: ?std.Thread = null,
    pk_hex: [64]u8 = undefined,

    /// Heap-allocate a mirror with owned copies of the option strings.
    pub fn create(allocator: Allocator, opts: Options) Error!*Mirror {
        const dir = allocator.dupe(u8, opts.dir) catch return error.OutOfMemory;
        errdefer allocator.free(dir);
        const sam = allocator.dupe(u8, opts.i2p_sam) catch return error.OutOfMemory;
        errdefer allocator.free(sam);
        const subdir: ?[]u8 = if (opts.checkpoint_subdir) |s|
            allocator.dupe(u8, s) catch return error.OutOfMemory
        else
            null;
        errdefer if (subdir) |s| allocator.free(s);
        const self = allocator.create(Mirror) catch return error.OutOfMemory;
        self.* = .{ .allocator = allocator, .opts = opts };
        self.opts.dir = dir;
        self.opts.i2p_sam = sam;
        self.opts.checkpoint_subdir = subdir;
        secp.toHex(&opts.pubkey, &self.pk_hex);
        return self;
    }

    /// Start the poll loop on its own thread. Resumes checkpointed torrents
    /// first, then polls relays every `poll_interval_s`.
    pub fn start(self: *Mirror) Error!void {
        std.fs.cwd().makePath(self.opts.dir) catch {};
        {
            const npub = nip19.encode32(self.allocator, .npub, self.opts.pubkey) catch null;
            defer if (npub) |n| self.allocator.free(n);
            log.info("following {s} (route {s}, dir {s})", .{
                npub orelse @as([]const u8, &self.pk_hex), @tagName(self.opts.route), self.opts.dir,
            });
        }
        // The mirror publishes its own peer-announces; without a local identity
        // it still seeds, but nobody can discover it. Say so once, up front.
        if (nostr_config.readSecretKey(self.allocator)) |_| {} else |_| {
            log.warn("no nostr identity found; mirrored seeds won't be announced. Run `carl nostr-keygen` first.", .{});
        }
        self.poll_thread = std.Thread.spawn(.{}, pollLoop, .{self}) catch return error.ThreadSpawnFailed;
    }

    /// Request stop and join every thread. Safe to call once; `destroy` calls
    /// it too, so callers may simply destroy. Can block for up to a relay
    /// timeout (~10s/relay) if a poll or discovery query is mid-flight.
    pub fn stop(self: *Mirror) void {
        self.stop_flag.store(true, .release);
        // Kick live sessions out of their run loops (same cross-thread `running`
        // signal the manager uses on its sessions).
        self.mutex.lock();
        for (self.transfers.items) |t| {
            if (t.live_session) |s| s.running = false;
        }
        self.mutex.unlock();
        if (self.poll_thread) |p| {
            p.join();
            self.poll_thread = null;
        }
        // After the poll thread is gone nothing appends to `transfers`; join
        // the per-torrent threads without holding the mutex.
        for (self.transfers.items) |t| {
            if (t.thread) |th| {
                th.join();
                t.thread = null;
            }
        }
    }

    /// Stop (if still running) and free everything.
    pub fn destroy(self: *Mirror) void {
        self.stop();
        for (self.transfers.items) |t| t.destroy();
        self.transfers.deinit(self.allocator);
        self.allocator.free(self.opts.dir);
        self.allocator.free(self.opts.i2p_sam);
        if (self.opts.checkpoint_subdir) |s| self.allocator.free(s);
        self.allocator.destroy(self);
    }

    /// True when this mirror (or the whole process) is shutting down.
    pub fn stopping(self: *Mirror) bool {
        return self.stop_flag.load(.acquire) or
            session_mod.shutdown_requested.load(.acquire);
    }

    /// Snapshot every mirrored torrent into `arena` (names duped; progress
    /// read from the live session when one is running).
    pub fn torrentsSnapshot(self: *Mirror, arena: Allocator) Allocator.Error![]TorrentInfo {
        self.mutex.lock();
        defer self.mutex.unlock();
        const out = try arena.alloc(TorrentInfo, self.transfers.items.len);
        for (self.transfers.items, 0..) |t, i| {
            var info: TorrentInfo = .{
                .name = try arena.dupe(u8, t.title),
                .hash_hex = t.hash_hex,
                .phase = @enumFromInt(t.phase.load(.monotonic)),
                .pct = 0,
                .peers = 0,
                .down = 0,
                .up = 0,
            };
            if (t.live_session) |s| {
                const p = s.progressSnapshot();
                info.pct = pctFromCounts(p.have, p.num_pieces);
                info.peers = p.peers;
                info.down = p.down_rate;
                info.up = p.up_rate;
                if (info.phase == .seeding) info.pct = 100;
            } else if (info.phase == .seeding) {
                info.pct = 100;
            }
            out[i] = info;
        }
        return out;
    }

    /// Number of registered transfers (running or not).
    pub fn count(self: *Mirror) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.transfers.items.len;
    }

    /// True when `hash` is already registered (dedupe for `startTransfer`).
    pub fn hasInfoHash(self: *Mirror, hash: [20]u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.transfers.items) |t| {
            if (std.mem.eql(u8, &t.info_hash, &hash)) return true;
        }
        return false;
    }

    /// Stop and evict a single transfer: set its per-transfer stop flag, kick
    /// its live session out of its run loop, remove it from the list (under
    /// the mutex, so a concurrent `torrentsSnapshot` never sees a torn entry),
    /// then join its thread and free it OUTSIDE the mutex. No-op when the
    /// hash isn't registered.
    ///
    /// Must not race `stop`/`destroy`: the caller (the drive loop) serializes
    /// eviction against mirror shutdown by joining its own loop thread before
    /// stopping the mirror.
    pub fn evictTransfer(self: *Mirror, info_hash: [20]u8) void {
        self.mutex.lock();
        var idx: ?usize = null;
        for (self.transfers.items, 0..) |t, i| {
            if (std.mem.eql(u8, &t.info_hash, &info_hash)) {
                idx = i;
                break;
            }
        }
        const i = idx orelse {
            self.mutex.unlock();
            return;
        };
        const t = self.transfers.items[i];
        t.stop_flag.store(true, .release);
        if (t.live_session) |s| s.running = false;
        _ = self.transfers.orderedRemove(i);
        // Take the thread handle while still under the mutex so a concurrent
        // `stop` can never double-join it.
        const th = t.thread;
        t.thread = null;
        self.mutex.unlock();
        if (th) |h| h.join();
        t.destroy();
    }
};

fn pctFromCounts(have: u32, num_pieces: u32) u8 {
    if (num_pieces == 0) return 0;
    const p = @as(u64, have) * 100 / num_pieces;
    return @intCast(@min(p, 100));
}

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
    /// Current `Phase`, published for snapshots (written by the mirror thread).
    phase: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(Phase.starting)),
    /// The session currently driven by this transfer's thread, for cross-thread
    /// progress reads and stop signaling. Guarded by `mirror.mutex`; cleared
    /// before the session is deinitialized.
    live_session: ?*session_mod.Session = null,
    /// Per-transfer stop request, set by `Mirror.evictTransfer` (the drive
    /// module evicts one torrent without stopping the whole mirror). Checked
    /// alongside `mirror.stopping()` everywhere a transfer thread unwinds.
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn setPhase(self: *Transfer, p: Phase) void {
        self.phase.store(@intFromEnum(p), .monotonic);
    }

    /// Publish `session` as this transfer's live session for the duration of a
    /// phase — unless a stop was requested while the session was being set up
    /// (SAM create + storage piece verification can take seconds, and an
    /// eviction landing in that window must not let the transfer slip into
    /// `session.run` with no live session for the evictor to stop).
    /// Mutex-serialized against `evictTransfer`/`Mirror.stop`, which set the
    /// stop flag and kick the live session under the same mutex, so exactly
    /// one side wins: either the transfer sees the stop here and never
    /// publishes (the caller unwinds before `session.run`), or the evictor
    /// sees the published session and sets `running = false`.
    /// Returns false when stopping (session NOT published).
    fn publishSessionUnlessStopping(self: *Transfer, session: *session_mod.Session) bool {
        self.mirror.mutex.lock();
        defer self.mirror.mutex.unlock();
        if (transferStopping(self)) return false;
        self.live_session = session;
        return true;
    }

    fn clearSession(self: *Transfer) void {
        self.mirror.mutex.lock();
        self.live_session = null;
        self.mirror.mutex.unlock();
    }

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

/// Run the follow loop until SIGINT. Blocks. (CLI entry; the daemon embeds
/// `Mirror` directly.)
pub fn run(allocator: Allocator, opts: Options) !void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = sigintHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);

    const mirror = try Mirror.create(allocator, opts);
    defer mirror.destroy();
    try mirror.start();

    while (!mirror.stopping()) {
        std.Thread.sleep(200 * std.time.ns_per_ms);
    }
    log.info("shutting down; stopping {d} mirror(s)...", .{mirror.count()});
}

fn pollLoop(mirror: *Mirror) void {
    resumeSaved(mirror);
    while (!mirror.stopping()) {
        pollOnce(mirror);
        // Sleep the poll interval in small slices so stop lands promptly.
        var slept_ms: u64 = 0;
        while (!mirror.stopping() and slept_ms < mirror.opts.poll_interval_s * 1000) {
            std.Thread.sleep(200 * std.time.ns_per_ms);
            slept_ms += 200;
        }
    }
}

/// Re-add every checkpointed torrent in the mirror dir, so a restart resumes
/// (and re-seeds) without waiting for relays.
fn resumeSaved(mirror: *Mirror) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const scan_dir: []const u8 = if (mirror.opts.checkpoint_subdir) |sub|
        std.fmt.bufPrint(&buf, "{s}/{s}", .{ mirror.opts.dir, sub }) catch return
    else
        mirror.opts.dir;
    var dir = std.fs.cwd().openDir(scan_dir, .{ .iterate = true }) catch return;
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
fn pollOnce(mirror: *Mirror) void {
    const a = mirror.allocator;

    const relay_urls = nostr_config.readRelays(a) catch return;
    defer nostr_config.freeRelays(a, relay_urls);

    var authors_arr = [_][]const u8{&mirror.pk_hex};
    const filter: nostr.Filter = .{
        .authors = &authors_arr,
        .kinds = &[_]u32{nip35.kind_torrent},
        .limit = 500,
    };

    var started: usize = 0;
    for (relay_urls) |url| {
        if (mirror.stopping()) return;
        // Periodic mirror poll: honor the health gate.
        var r = relay_mod.dial(a, url, null, .honor) catch |err| {
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

/// True when a transfer thread should unwind cleanly (no error phase, no
/// warn): either the whole mirror is stopping or this transfer alone was
/// evicted via `Mirror.evictTransfer`.
fn transferStopping(t: *Transfer) bool {
    return t.stop_flag.load(.acquire) or t.mirror.stopping();
}

/// Create the Transfer, register it (so dedupe sees it immediately), and spawn
/// its mirror thread. Public so the drive module can drive per-file mirrors
/// through the same download→seed lifecycle (`mirrorTorrentEntry` in the
/// drive design is simply this function with `trackers = &.{}`).
pub fn startTransfer(
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

    const torrent_path = if (mirror.opts.checkpoint_subdir) |sub|
        std.fmt.allocPrint(a, "{s}/{s}/{s}{s}", .{ mirror.opts.dir, sub, &hash_hex, torrent_suffix }) catch
            return error.OutOfMemory
    else
        std.fmt.allocPrint(a, "{s}/{s}{s}", .{ mirror.opts.dir, &hash_hex, torrent_suffix }) catch
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
        t.setPhase(.failed);
        log.warn("could not spawn mirror thread for {s}", .{&t.hash_hex});
        return;
    };
}

fn mirrorThread(t: *Transfer) void {
    mirrorTorrent(t) catch |err| {
        if (transferStopping(t)) return;
        t.setPhase(.failed);
        log.warn("mirror {s} ({s}) stopped: {}", .{ &t.hash_hex, t.title, err });
    };
}

fn mirrorTorrent(t: *Transfer) Error!void {
    const a = t.allocator;

    if (transferStopping(t)) return;

    // Phase 1 — get the data (and the resolved metainfo) onto disk.
    const mi = try ensureDownloaded(t);
    defer mi.deinit(a);
    if (transferStopping(t)) return;

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
        // The checkpoint's name beats the (possibly empty) NIP-35 title for
        // status displays — resumed transfers start with an empty title.
        if (t.title.len == 0 and mi.name.len > 0) {
            if (a.dupe(u8, mi.name)) |dup| {
                t.mirror.mutex.lock();
                a.free(t.title);
                t.title = dup;
                t.mirror.mutex.unlock();
            } else |_| {}
        }
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

    // SAM session create can take seconds; an eviction landing in that window
    // must unwind here, not after the storage verify + full download run.
    if (transferStopping(t)) return;

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

    // Stop requested during session init (storage verify): unwind before the
    // session runs. Publishing is mutex-serialized against the evictor, so a
    // stop can never slip through unpublished.
    if (!t.publishSessionUnlessStopping(&session)) return;
    defer t.clearSession();
    t.setPhase(.downloading);

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

            // SAM session create can take seconds; an eviction landing in
            // that window must unwind here, not slip into seed mode with no
            // live session for the evictor to stop.
            if (transferStopping(t)) return;

            const host = i2p_sam.b32Address(a, sam.destination) catch return error.SamFailed;
            defer a.free(host);

            var session = session_mod.Session.init(a, mi, opts.dir, .seed, port, null, .loopback, false, &sam, true) catch
                return error.SessionInitFailed;
            defer session.deinit();
            if (session.listener == null) return error.NoListener;
            // Storage piece verification (inside Session.init) is the second
            // long window; honor a stop before forwarding + announcing.
            if (transferStopping(t)) return;
            sam.forward(port) catch {
                log.warn("i2p STREAM FORWARD failed; mirror would be unreachable", .{});
                return error.SamFailed;
            };

            // Final stop check at the seed-entry boundary, mutex-serialized
            // against the evictor: never enter seed mode unstoppably.
            if (!t.publishSessionUnlessStopping(&session)) return;
            defer t.clearSession();
            t.setPhase(.seeding);

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

            // Stop check at the seed-entry boundary (covers a stop requested
            // during the storage verify inside Session.init), mutex-
            // serialized against the evictor.
            if (!t.publishSessionUnlessStopping(&session)) return;
            defer t.clearSession();
            t.setPhase(.seeding);

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
    const gate = relay_mod.oneShotGate(relay_urls, null);
    for (relay_urls) |url| {
        var r = relay_mod.dial(a, url, null, gate) catch continue;
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
        if (!session.running or session_mod.shutdown_requested.load(.acquire)) return;
        // Peer re-discovery on a schedule: honor the health gate.
        var r = relay_mod.dial(a, url, null, .honor) catch continue;
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

test "Mirror create/start/stop lifecycle with no relays reachable" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);

    const mirror = try Mirror.create(a, .{
        .pubkey = .{7} ** 32,
        .dir = dir,
        .poll_interval_s = 1,
    });
    // No start(): create/destroy alone must not leak or hang.
    try std.testing.expectEqual(@as(usize, 0), mirror.count());
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const snap = try mirror.torrentsSnapshot(arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), snap.len);
    mirror.destroy();
}

test "Transfer.publishSessionUnlessStopping honors the stop flag at the seed-entry boundary" {
    const a = std.testing.allocator;
    var mirror = Mirror{ .allocator = a, .opts = .{ .pubkey = .{0} ** 32, .dir = "." } };
    var t = Transfer{
        .allocator = a,
        .mirror = &mirror,
        .info_hash = .{0xEF} ** 20,
        .hash_hex = .{'e'} ** 40,
        .title = @constCast("f"),
        .trackers = &.{},
        .torrent_path = @constCast("unused"),
    };
    // Dummy session pointer: stored/cleared only, never dereferenced.
    const dummy: *session_mod.Session = @ptrFromInt(0x1000);

    // No stop requested: the session publishes normally (the pre-fix
    // behavior for the common path).
    try std.testing.expect(t.publishSessionUnlessStopping(dummy));
    try std.testing.expect(t.live_session == dummy);
    t.clearSession();
    try std.testing.expect(t.live_session == null);

    // Per-transfer stop (eviction) requested during seed setup: the transfer
    // must refuse to publish so the caller unwinds instead of entering seed
    // mode with no live session for the evictor to stop.
    t.stop_flag.store(true, .release);
    try std.testing.expect(!t.publishSessionUnlessStopping(dummy));
    try std.testing.expect(t.live_session == null);

    // Mirror-level stop is honored the same way.
    t.stop_flag.store(false, .release);
    mirror.stop_flag.store(true, .release);
    try std.testing.expect(!t.publishSessionUnlessStopping(dummy));
    try std.testing.expect(t.live_session == null);
}

test "Phase jsonName matches enum tags" {
    try std.testing.expectEqualStrings("downloading", Phase.downloading.jsonName());
    try std.testing.expectEqualStrings("seeding", Phase.seeding.jsonName());
}
