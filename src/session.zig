/// Central session coordinator with poll-based event loop.
///
/// Implements BEP 3 choking algorithm, rarest-first piece selection,
/// endgame mode, multi-tracker failover (BEP 12), and UDP tracker (BEP 15).
const std = @import("std");
const Allocator = std.mem.Allocator;
const metainfo = @import("metainfo.zig");
const tracker_mod = @import("tracker.zig");
const udp_tracker = @import("udp_tracker.zig");
const wire = @import("wire.zig");
const piece_mod = @import("piece.zig");
const storage_mod = @import("storage.zig");
const peer_mod = @import("peer.zig");
const extension = @import("extension.zig");
const bencode = @import("bencode.zig");
const dht_mod = @import("dht.zig");
const proxy_mod = @import("proxy.zig");
const i2p_sam = @import("i2p_sam.zig");

const log = std.log.scoped(.session);

const max_peers: usize = 50;
/// Cap on simultaneously in-progress pieces. With large pieces (e.g. 8 MiB /
/// 512 blocks) and high peer churn, spreading blocks across many pieces means
/// none ever completes. Concentrating on a few pieces lets multiple peers
/// contribute blocks to the SAME piece, completing it far sooner — after which
/// it can be verified, written, and shared (uploaded). 4 is aggressive enough
/// to complete pieces quickly even in high-churn public swarms where each peer
/// only contributes a handful of blocks before dropping.
const max_concurrent_pieces: usize = 4;
const unchoke_slots: usize = 4;
const unchoke_interval_secs: i64 = 10;
/// Cooldown after a DHT walk fails, so a peerless session does not respawn a
/// full cold bootstrap on every maintenance tick.
const dht_retry_backoff_secs: i64 = 60;
const optimistic_interval_secs: i64 = 30;
/// How often to re-run Nostr peer discovery while a transfer has zero peers.
/// One-shot discovery at startup isn't enough — a download whose only seed
/// dropped (or that found nothing at first) must keep retrying or it stalls at
/// no_peers forever. Re-querying relays is slow (~seconds per relay), so only
/// retry when stuck at zero peers and not more often than this.
const peer_rediscovery_interval_secs: i64 = 45;
/// How long an outstanding block request may go unanswered before it is
/// cancelled and released back to the scheduler. Long enough that a slow
/// anonymized route (I2P round trips run seconds) is never penalized; short
/// enough that one silent peer can't hold blocks hostage while others could
/// fetch them.
const request_timeout_secs: i64 = 60;

/// Periodic peer re-discovery hook. The session run loop calls `run(ctx)` on
/// its own thread when the transfer has zero peers, so the callback can safely
/// add peers (the peer set is single-threaded). The manager/CLI wire this to
/// their Nostr peer-announce lookup for `--nostr` downloads.
pub const PeerDiscovery = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque) void,
};

/// Fired once when a download completes (all pieces verified). Runs on the
/// session thread, so it can read session state safely. The manager wires
/// this to publish the torrent on Nostr (NIP-35) if not already present.
pub const OnComplete = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque) void,
};

/// Global flag for graceful shutdown on SIGINT. Atomic because it's
/// written from a signal handler and read from event loop / test threads.
pub var shutdown_requested = std.atomic.Value(bool).init(false);

fn sigintHandler(_: i32) callconv(.c) void {
    shutdown_requested.store(true, .release);
}

pub const Mode = enum { download, seed };

pub const ListenBind = enum { any, loopback };

/// Shared, refcounted state between a Session and its detached DHT worker.
/// Kept on the heap so the worker can finish (and free it) after the session
/// is destroyed — the session never joins a lookup, so shutdown stays instant.
const DhtState = struct {
    mutex: std.Thread.Mutex = .{},
    query_active: bool = false,
    failed: bool = false,
    /// Earliest time a new lookup may start; set after a failed lookup so a
    /// zero-peer session does not respawn a cold bootstrap every tick.
    retry_after: i64 = 0,
    peers: []tracker_mod.Peer = &.{},
    nodes: u32 = 0,
    /// Set by the session at teardown so an in-flight walk stops at its next
    /// network step instead of running out its full timeout budget.
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    refs: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),

    fn ref(self: *DhtState) void {
        _ = self.refs.fetchAdd(1, .acq_rel);
    }

    /// Drops one reference; the last holder frees the posted peers and the
    /// state itself. Safe to call from either thread.
    fn unref(self: *DhtState, allocator: Allocator) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            if (self.peers.len > 0) allocator.free(self.peers);
            allocator.destroy(self);
        }
    }
};

pub const Session = struct {
    allocator: Allocator,
    meta: metainfo.Metainfo,
    info_hash: [20]u8,
    peer_id: [20]u8,
    our_bitfield: piece_mod.Bitfield,
    store: storage_mod.Storage,

    peers: std.ArrayList(*peer_mod.PeerConnection),
    active_pieces: std.AutoHashMap(u32, *piece_mod.PieceProgress),

    // Piece availability counts (how many peers have each piece)
    piece_availability: []u32,

    listener: ?std.net.Server,
    listen_port: u16,
    output_dir: []const u8,
    mode: Mode,

    // Tracker state
    tracker_interval: u64,
    last_announce_time: i64,
    uploaded: u64,
    downloaded: u64,

    // Torrent geometry
    total_length: u64,
    piece_len: u64,
    num_pieces: u32,

    // Control
    running: bool,

    // Guards the fields read by `progressSnapshot` against the metadata-complete
    // transition (which reallocates `our_bitfield`). Lets the daemon read live
    // progress from another thread without a use-after-free. Defaulted so the
    // init struct literal need not set it.
    snapshot_mutex: std.Thread.Mutex = .{},

    // The resolved `.torrent` bytes, built once metadata completes (magnet path)
    // so the daemon can persist it and resume the torrent fully — verifying
    // on-disk pieces — instead of re-bootstrapping a magnet. Guarded by
    // `snapshot_mutex`; freed in deinit. Defaulted so init need not set it.
    torrent_blob: ?[]u8 = null,

    // Cross-thread progress snapshot. The daemon reads live progress from
    // another thread; rather than have it touch `our_bitfield`/`peers` (which
    // the session thread mutates), the session keeps these atomics exact —
    // restated after every change — and the daemon reads only these. Defaulted
    // so init need not set them; `init` seeds `have_pieces` from resume.
    have_pieces: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    peer_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    // Live transfer rate, bytes/sec, smoothed (EWMA) and resampled once a second
    // by the session thread in `sampleRate` so the daemon's cross-thread snapshot
    // reads a stable value no matter how often (or from how many clients) it
    // polls — unlike the old per-snapshot delta, which corrupted with >1 reader.
    // Read lock-free by `progressSnapshot`. Defaulted so `init` need not set them.
    down_rate: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    up_rate: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    // Wall-clock second of the last byte of real download progress (piece OR
    // metadata). The snapshot turns this into "downloading vs stalled" without a
    // cadence-dependent delta. Seeded to start time in `init`.
    last_progress_s: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    // BEP 9 metadata-fetch progress, published as atomics by the session thread
    // (restated whenever the `metadata_download` tracker advances). The snapshot
    // reads these instead of reaching into the tracker, so it never races the
    // tracker's realloc/teardown. Both 0 once metadata is in or for a non-magnet.
    meta_have: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    meta_total: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    // Sampling bookkeeping — touched only by the session thread in `sampleRate`.
    rate_last_s: i64 = 0,
    rate_last_in: u64 = 0,
    rate_last_out: u64 = 0,
    // Last second `maintenance` ran the per-peer tick (pipeline resize +
    // request expiry). Gates that work to 1 Hz like `sampleRate`.
    peer_tick_last_s: i64 = 0,
    // Cached tracker peer list for replenishment. In a mostly-NAT'd public
    // swarm most tracker peers are unreachable, so a single connect burst finds
    // almost nothing. The session cycles through the cached list (skipping
    // already-connected peers) until the pool fills with reachable peers.
    // Freed in deinit.
    cached_peers: []tracker_mod.Peer = &.{},
    // Throttle for peer replenishment (maintenance). Connecting is cheap (async),
    // but rate-limiting avoids hammering the same unreachable hosts every tick.
    last_replenish_s: i64 = 0,
    // BEP 9 metadata bytes received this session. Counted toward the download
    // rate (and progress timestamp) so the metadata-fetch phase shows real speed
    // even though piece `downloaded` is still 0 then.
    meta_bytes_in: u64 = 0,
    // Piece payload bytes received off the wire this session, counted per
    // block before hash verification. Drives the download rate and progress
    // timestamp instead of `downloaded` (which only advances on verified
    // pieces): on slow links (e.g. a single I2P peer) one piece can take far
    // longer than the stall threshold to assemble, and counting only verified
    // pieces flaps the status between downloading and stalled.
    block_bytes_in: u64 = 0,

    /// Guards the published per-file snapshot. Written by the session thread
    /// in `maintenance` (1 Hz), read by `fileSnapshot` from the daemon thread.
    file_snap_mutex: std.Thread.Mutex = .{},
    /// Published per-file snapshot, or null before metadata is in. Owned by
    /// the session; freed before each re-publish and in `deinit`.
    file_snap: ?[]FileSnap = null,
    peer_snap_mutex: std.Thread.Mutex = .{},
    peer_snap: ?[]PeerInfo = null,
    /// Primary tracker URL (owned), captured at init and re-captured on
    /// metadata completion. Guarded by `snapshot_mutex`. Freed in deinit.
    src_tracker_url: ?[]u8 = null,
    /// Source snapshot atomics — updated by the session thread, read lock-free
    /// by `progressSnapshot`.
    src_seeders: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    src_leechers: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// 0 = not announced yet, 1 = last announce ok.
    src_tracker_state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    src_dht_nodes: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    src_announce_interval_s: std.atomic.Value(i64) = std.atomic.Value(i64).init(1800),
    src_last_announce_s: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    // Choking state
    last_unchoke_time: i64,
    last_optimistic_time: i64,
    optimistic_peer: ?*peer_mod.PeerConnection,

    // Endgame mode
    endgame_active: bool,

    // BEP 9 metadata download (magnet link mode)
    metadata_download: ?extension.MetadataDownload,
    metadata_only: bool, // true when started from magnet link

    /// When true, `download` keeps running as a seeder after the download
    /// completes instead of exiting. Off by default: `download` should finish
    /// and return; use `carl seed` (or `download --seed`) to keep seeding.
    /// Defaulted so the init struct literal need not set it.
    seed_after_complete: bool = false,

    /// True once `onMetadataComplete` has replaced `meta` with a freshly
    /// allocated, fully-owned Metainfo (magnet path). The original `meta` is
    /// owned by the caller; this replacement is owned by the session and freed
    /// in `deinit`. Defaulted so the init struct literal need not set it.
    meta_owned: bool = false,

    // BEP 5 DHT. Discovery runs on a dedicated detached worker thread: a
    // lookup (bootstrap + iterative query, each step with UDP timeouts)
    // blocks for seconds, and running it inline stalled the event loop —
    // observed as a ~9s gap between "announcing to tracker..." and
    // "session started" when trackers returned zero peers, freezing peer I/O
    // and web seeding. The worker owns its Dht instance and hands results
    // back through the refcounted DhtState, so a session can shut down at
    // any moment without joining (or leaking into) the lookup.
    dht_state: ?*DhtState = null,
    /// Handle for the in-flight lookup. The worker allocates through the
    /// session allocator, so it MUST be joined before that allocator dies —
    /// refcounting DhtState protects the state, not the allocator behind it.
    dht_thread: ?std.Thread = null,
    /// One DHT node ID for the whole session (see Dht.initWithId).
    dht_node_id: [20]u8 = undefined,
    dht_node_id_set: bool = false,

    // Outbound proxy (SOCKS5/SOCKS5h/HTTP CONNECT). When set, peers and HTTP
    // trackers are tunneled; DHT, UDP trackers, web seeds, and the inbound
    // listener are disabled to avoid leaking the real IP.
    proxy: ?proxy_mod.Proxy,

    /// Native I2P transport (SAM v3). Borrowed; owned by the manager and set
    /// after init for the `i2p` route. When set, peers are dialed as `.b32.i2p`
    /// destinations over SAM instead of TCP/SOCKS. Mutually exclusive with proxy.
    i2p: ?*i2p_sam.Session = null,

    /// Where the inbound listener binds when active.
    listen_bind: ListenBind,
    /// Tor hidden-service seed: no tracker/DHT (would leak or bypass Tor).
    tor_hidden: bool,
    /// I2P inbound seed: a SAM `STREAM FORWARD` delivers remote peers to our
    /// loopback listener, so — unlike a leech-only i2p transfer — the listener
    /// must come up (bound to loopback only; the forward is the public face).
    /// Clearnet discovery stays off via `anonymized()` (i2p is set).
    i2p_hidden: bool,

    /// Optional periodic peer re-discovery (set by the manager/CLI for `--nostr`
    /// downloads). Invoked by the run loop when the transfer has zero peers.
    peer_discovery: ?PeerDiscovery = null,
    /// Timestamp of the last peer re-discovery, to rate-limit retries.
    last_peer_discovery_s: i64 = 0,
    /// Fired once when a download completes. The manager uses this to broadcast
    /// the torrent on Nostr (NIP-35) if not already present on relays.
    on_complete: ?OnComplete = null,

    // Progress tracking
    start_time: i64,
    last_progress_time: i64,
    last_progress_bytes: u64,

    pub fn init(
        allocator: Allocator,
        meta: metainfo.Metainfo,
        output_dir: []const u8,
        mode: Mode,
        listen_port: u16,
        proxy: ?proxy_mod.Proxy,
        listen_bind: ListenBind,
        tor_hidden: bool,
        i2p: ?*i2p_sam.Session,
        i2p_hidden: bool,
    ) !Session {
        const total_length = piece_mod.totalLength(meta.files);
        const num_pieces = piece_mod.numPieces(total_length, meta.piece_length);
        const info_hash = metainfo.infoHash(meta.raw_info);

        // Own our copy of output_dir: callers pass arena/manager-owned buffers
        // (e.g. the seed-upload arena, or cfg.download_dir which setDownloadDir
        // frees) that don't outlive this session, and we reuse it later when a
        // magnet resolves (storage re-init). Freed in deinit.
        const output_dir_owned = try allocator.dupe(u8, output_dir);
        errdefer allocator.free(output_dir_owned);

        const tracker_url = if (meta.announce.len > 0)
            allocator.dupe(u8, meta.announce) catch null
        else
            null;
        errdefer if (tracker_url) |u| allocator.free(u);

        var peer_id: [20]u8 = undefined;
        @memcpy(peer_id[0..8], "-CA0010-");
        std.crypto.random.bytes(peer_id[8..]);

        var our_bitfield = try piece_mod.Bitfield.init(allocator, num_pieces);
        errdefer our_bitfield.deinit(allocator);

        const piece_availability = allocator.alloc(u32, num_pieces) catch return error.OutOfMemory;
        @memset(piece_availability, 0);
        errdefer allocator.free(piece_availability);

        const create = mode == .download;
        var store = storage_mod.Storage.init(allocator, meta, output_dir, create) catch
            return error.StorageInitFailed;
        errdefer store.deinit();

        // Verify existing pieces (resume + seed)
        {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            stderr.print("verifying existing pieces...\n", .{}) catch {};
            for (0..num_pieces) |i| {
                const idx: u32 = @intCast(i);
                const plen = piece_mod.pieceLength(idx, meta.piece_length, total_length);
                const data = store.readPiece(allocator, idx, plen) catch continue;
                defer allocator.free(data);
                const hash = piece_mod.pieceHash(meta.pieces, idx) orelse continue;
                if (piece_mod.verifyPiece(data, hash)) {
                    our_bitfield.setPiece(idx);
                }
            }
            const verified = our_bitfield.count();
            if (verified > 0) {
                stderr.print("resume: {d}/{d} pieces already verified\n", .{ verified, num_pieces }) catch {};
            }
        }

        // Skip the inbound listener entirely on any anonymized transport
        // (proxy/Tor/I2P): accepting incoming clearnet peers would reveal the
        // real IP. The exception is an I2P inbound seed (`i2p_hidden`): its
        // listener binds loopback and is fed only by the SAM forward, never the
        // clearnet — the same shape as a Tor hidden-service seed.
        var listener: ?std.net.Server = null;
        if (((proxy == null and i2p == null) or i2p_hidden) and (mode == .seed or our_bitfield.count() > 0)) {
            const bind_ip: [4]u8 = switch (listen_bind) {
                .any => .{ 0, 0, 0, 0 },
                .loopback => .{ 127, 0, 0, 1 },
            };
            const addr = std.net.Address.initIp4(bind_ip, listen_port);
            listener = addr.listen(.{ .reuse_address = true }) catch null;
        }

        const now = std.time.timestamp();

        return .{
            .allocator = allocator,
            .meta = meta,
            .info_hash = info_hash,
            .peer_id = peer_id,
            .our_bitfield = our_bitfield,
            .store = store,
            .peers = .empty,
            .active_pieces = std.AutoHashMap(u32, *piece_mod.PieceProgress).init(allocator),
            .piece_availability = piece_availability,
            .listener = listener,
            .listen_port = listen_port,
            .output_dir = output_dir_owned,
            .have_pieces = std.atomic.Value(usize).init(our_bitfield.count()),
            .mode = mode,
            .tracker_interval = 1800,
            .last_announce_time = 0,
            .uploaded = 0,
            .downloaded = 0,
            .total_length = total_length,
            .piece_len = meta.piece_length,
            .num_pieces = num_pieces,
            .running = true,
            .last_unchoke_time = now - unchoke_interval_secs, // trigger immediately on first tick
            .last_optimistic_time = now - optimistic_interval_secs,
            .optimistic_peer = null,
            .endgame_active = false,
            .metadata_download = null,
            .metadata_only = false,
            .proxy = proxy,
            .i2p = i2p,
            .listen_bind = listen_bind,
            .tor_hidden = tor_hidden,
            .i2p_hidden = i2p_hidden,
            .start_time = now,
            .last_progress_time = now,
            .last_progress_bytes = 0,
            // Seed to "now" so a fresh transfer isn't instantly judged stalled
            // before its first poll tick. `now` here is seconds (timestamp()).
            .last_progress_s = std.atomic.Value(i64).init(now),
            .rate_last_s = now,
            .src_tracker_url = tracker_url,
        };
    }

    pub fn deinit(self: *Session) void {
        var it = self.active_pieces.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.active_pieces.deinit();
        self.allocator.free(self.piece_availability);

        for (self.peers.items) |p| {
            p.deinit();
            self.allocator.destroy(p);
        }
        self.peers.deinit(self.allocator);
        if (self.cached_peers.len > 0) self.allocator.free(self.cached_peers);

        self.stopDhtWorker();
        if (self.dht_state) |st| st.unref(self.allocator);
        if (self.metadata_download) |*md| md.deinit();
        if (self.listener) |*l| l.deinit();
        if (self.torrent_blob) |b| self.allocator.free(b);
        self.freeFileSnapSlice(self.file_snap);
        self.freePeerSnapSlice(self.peer_snap);
        if (self.src_tracker_url) |u| self.allocator.free(u);
        self.allocator.free(self.output_dir);
        self.our_bitfield.deinit(self.allocator);
        self.store.deinit();
        // The magnet path replaces `meta` with a session-owned copy; free it.
        // The original caller-owned `meta` is freed by the caller.
        if (self.meta_owned) self.meta.deinit(self.allocator);
    }

    /// A consistent, race-safe view of the session's live progress, for other
    /// threads (the daemon). Reads are taken under `snapshot_mutex` so the
    /// magnet metadata-complete transition (which reallocates `our_bitfield`)
    /// can't be observed half-applied.
    pub const Progress = struct {
        have: u32,
        num_pieces: u32,
        downloaded: u64,
        uploaded: u64,
        total_length: u64,
        peers: u32,
        mode: Mode,
        metadata_only: bool,
        /// Live download/upload rate (bytes/sec), session-smoothed.
        down_rate: u64,
        up_rate: u64,
        /// BEP 9 metadata pieces received / total (total 0 until a peer reports
        /// the metadata size). Both 0 once metadata is in or for a non-magnet.
        meta_have: u32,
        meta_total: u32,
        /// Seconds since the last byte of real progress arrived. Lets the snapshot
        /// distinguish active "downloading" from "stalled" without a delta.
        idle_secs: i64,
        // ---- Source snapshot (published via atomics + snapshot_mutex) ----
        tracker_url: []const u8,
        seeders: u32,
        leechers: u32,
        /// 0 = not announced, 1 = last announce ok.
        tracker_state: u32,
        dht_nodes: u32,
        dht_active: bool,
        nostr_active: bool,
        announce_interval_s: i64,
        last_announce_s: i64,
    };

    /// One file's summary, published by the session thread for cross-thread
    /// reads (the daemon's per-tick snapshot). Owned by `file_snap`.
    pub const FileSnap = struct {
        name: []u8,
        size: u64,
        pct: u8,
    };

    pub const PeerInfo = struct {
        addr: []u8,
        port: u16,
        client: []u8,
        down: u64,
        up: u64,
        pct: u8,
        flags: []u8,
        onion: bool,
    };

    /// A copy of the resolved `.torrent` bytes, or null if metadata isn't in
    /// yet (or this was never a magnet). Caller owns the result.
    pub fn copyTorrent(self: *Session, a: Allocator) ?[]u8 {
        self.snapshot_mutex.lock();
        defer self.snapshot_mutex.unlock();
        const blob = self.torrent_blob orelse return null;
        return a.dupe(u8, blob) catch null;
    }

    pub fn progressSnapshot(self: *Session) Progress {
        self.snapshot_mutex.lock();
        defer self.snapshot_mutex.unlock();
        // `have`/`peers` come from atomics the session thread keeps exact, so we
        // never touch `our_bitfield`/`peers` (mutated lockless on that thread).
        // `num_pieces`/`total_length` are still read under the mutex because the
        // metadata-complete transition reassigns them. Metadata-fetch progress is
        // read from session atomics (not the tracker struct), so it never races
        // the tracker's realloc/teardown on the session thread.
        const last_prog = self.last_progress_s.load(.monotonic);
        return .{
            .have = @intCast(self.have_pieces.load(.monotonic)),
            .num_pieces = self.num_pieces,
            .downloaded = self.downloaded,
            .uploaded = self.uploaded,
            .total_length = self.total_length,
            .peers = @intCast(self.peer_count.load(.monotonic)),
            .mode = self.mode,
            .metadata_only = self.metadata_only,
            .down_rate = self.down_rate.load(.monotonic),
            .up_rate = self.up_rate.load(.monotonic),
            .meta_have = self.meta_have.load(.monotonic),
            .meta_total = self.meta_total.load(.monotonic),
            .idle_secs = @max(0, std.time.timestamp() - last_prog),
            .tracker_url = if (self.src_tracker_url) |u| u else "",
            .seeders = self.src_seeders.load(.monotonic),
            .leechers = self.src_leechers.load(.monotonic),
            .tracker_state = self.src_tracker_state.load(.monotonic),
            .dht_nodes = self.src_dht_nodes.load(.monotonic),
            .dht_active = !self.anonymized() and !self.tor_hidden,
            .nostr_active = self.peer_discovery != null,
            .announce_interval_s = self.src_announce_interval_s.load(.monotonic),
            .last_announce_s = self.src_last_announce_s.load(.monotonic),
        };
    }

    // ---- Per-file snapshot (published for cross-thread reads) ----

    fn freeFileSnapSlice(self: *Session, snap: ?[]FileSnap) void {
        if (snap) |s| {
            for (s) |f| self.allocator.free(f.name);
            self.allocator.free(s);
        }
    }

    /// Copy the session's published per-file snapshot for cross-thread reads.
    pub fn fileSnapshot(self: *Session, a: Allocator) Allocator.Error![]FileSnap {
        self.file_snap_mutex.lock();
        defer self.file_snap_mutex.unlock();
        const snap = self.file_snap orelse return try a.alloc(FileSnap, 0);
        const out = try a.alloc(FileSnap, snap.len);
        for (snap, 0..) |f, i| {
            out[i] = .{
                .name = try a.dupe(u8, f.name),
                .size = f.size,
                .pct = f.pct,
            };
        }
        return out;
    }

    /// Build and publish a per-file snapshot from `meta.files` + the bitfield.
    /// Called from `maintenance` (1 Hz). For magnet torrents this is empty
    /// until metadata resolves, then picks up the real file list.
    fn publishFileSnap(self: *Session) void {
        const count = self.meta.files.len;
        if (count == 0 or self.piece_len == 0) {
            self.file_snap_mutex.lock();
            const old = self.file_snap;
            self.file_snap = null;
            self.file_snap_mutex.unlock();
            self.freeFileSnapSlice(old);
            return;
        }

        const snap = self.allocator.alloc(FileSnap, count) catch return;
        var written: usize = 0;
        for (self.meta.files, 0..) |file, fi| {
            // Join path components with "/".
            var name_buf: [1024]u8 = undefined;
            var name_len: usize = 0;
            for (file.path) |comp| {
                if (name_len > 0 and name_len < name_buf.len) {
                    name_buf[name_len] = '/';
                    name_len += 1;
                }
                const cl = @min(comp.len, name_buf.len - name_len);
                @memcpy(name_buf[name_len..][0..cl], comp[0..cl]);
                name_len += cl;
            }

            // Per-file completion, weighted by byte overlap for boundary
            // pieces (a file occupying 1 byte of a piece shouldn't count
            // that piece as fully complete for this file).
            const fstart = self.store.file_map.file_starts[fi];
            const flen = self.store.file_map.file_lengths[fi];
            const pct: u8 = computeFilePct(
                self.our_bitfield,
                fstart,
                flen,
                self.piece_len,
                self.num_pieces,
            );

            snap[written] = .{
                .name = self.allocator.dupe(u8, name_buf[0..name_len]) catch continue,
                .size = file.length,
                .pct = pct,
            };
            written += 1;
        }

        self.file_snap_mutex.lock();
        const old = self.file_snap;
        self.file_snap = snap[0..written];
        self.file_snap_mutex.unlock();
        self.freeFileSnapSlice(old);
    }

    // ---- Per-peer snapshot (published for cross-thread reads) ----

    fn freePeerSnapSlice(self: *Session, snap: ?[]PeerInfo) void {
        if (snap) |s| {
            for (s) |p| {
                self.allocator.free(p.addr);
                self.allocator.free(p.client);
                self.allocator.free(p.flags);
            }
            self.allocator.free(s);
        }
    }

    pub fn peerSnapshot(self: *Session, a: Allocator) Allocator.Error![]PeerInfo {
        self.peer_snap_mutex.lock();
        defer self.peer_snap_mutex.unlock();
        const snap = self.peer_snap orelse return try a.alloc(PeerInfo, 0);
        const out = try a.alloc(PeerInfo, snap.len);
        for (snap, 0..) |p, i| {
            out[i] = .{
                .addr = try a.dupe(u8, p.addr),
                .client = try a.dupe(u8, p.client),
                .flags = try a.dupe(u8, p.flags),
                .port = p.port,
                .down = p.down,
                .up = p.up,
                .pct = p.pct,
                .onion = p.onion,
            };
        }
        return out;
    }

    fn publishPeerSnap(self: *Session) void {
        const count = self.peers.items.len;
        if (count == 0) {
            self.peer_snap_mutex.lock();
            const old = self.peer_snap;
            self.peer_snap = null;
            self.peer_snap_mutex.unlock();
            self.freePeerSnapSlice(old);
            return;
        }

        const snap = self.allocator.alloc(PeerInfo, count) catch return;
        var written: usize = 0;
        for (self.peers.items) |p| {
            if (p.state == .disconnected) continue;
            snap[written] = self.buildPeerInfo(p) catch continue;
            written += 1;
        }

        const published = self.allocator.realloc(snap, written) catch snap[0..written];
        self.peer_snap_mutex.lock();
        const old = self.peer_snap;
        self.peer_snap = published;
        self.peer_snap_mutex.unlock();
        self.freePeerSnapSlice(old);
    }

    fn buildPeerInfo(self: *Session, p: *peer_mod.PeerConnection) Allocator.Error!PeerInfo {
        var addr_owned: []u8 = undefined;
        var port: u16 = 0;
        var is_onion = false;

        if (p.connect_host) |host| {
            if (std.mem.endsWith(u8, host, ".onion")) {
                is_onion = true;
                addr_owned = try self.allocator.dupe(u8, host);
                port = p.address.getPort();
            } else {
                addr_owned = try self.allocator.dupe(u8, host);
                port = p.address.getPort();
            }
        } else {
            const ip: *const [4]u8 = @ptrCast(&p.address.in.sa.addr);
            var buf: [32]u8 = undefined;
            const formatted = std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}", .{
                ip[0], ip[1], ip[2], ip[3],
            }) catch unreachable;
            addr_owned = try self.allocator.dupe(u8, formatted);
            port = p.address.getPort();
        }

        var client_buf: [64]u8 = undefined;
        const client_src: []const u8 = if (p.client_name) |name|
            if (std.unicode.utf8ValidateSlice(name)) name else "unknown"
        else
            decodeClientName(&client_buf, p.peer_id);
        const client_owned = try self.allocator.dupe(u8, client_src);

        const peer_pct: u8 = if (p.peer_bitfield) |bf| blk: {
            if (self.num_pieces == 0) break :blk 0;
            const pct = @as(u64, bf.count()) * 100 / self.num_pieces;
            break :blk @intCast(@min(pct, 100));
        } else 0;

        var flags_buf: [4]u8 = undefined;
        const flags_owned = try self.allocator.dupe(u8, peerFlags(&flags_buf, p));

        return .{
            .addr = addr_owned,
            .port = port,
            .client = client_owned,
            .down = p.down_rate,
            .up = p.up_rate,
            .pct = peer_pct,
            .flags = flags_owned,
            .onion = is_onion,
        };
    }

    /// Resample the download/upload rate. Called once per second from the
    /// session thread (`maintenance`). Counts payload block bytes
    /// (`block_bytes_in`, stamped before verification so mid-piece progress on
    /// slow links registers) plus received metadata bytes, applies an EWMA
    /// (alpha 1/4) for a stable display value, and stamps `last_progress_s`
    /// whenever real bytes arrived so the snapshot can tell "downloading"
    /// from "stalled".
    fn sampleRate(self: *Session, now_s: i64) void {
        const in_bytes = self.block_bytes_in + self.meta_bytes_in;
        const out_bytes = self.uploaded;
        if (self.rate_last_s == 0) {
            self.rate_last_s = now_s;
            self.rate_last_in = in_bytes;
            self.rate_last_out = out_bytes;
            return;
        }
        const dt = now_s - self.rate_last_s;
        if (dt <= 0) return; // sample at most once per (1s-granularity) clock tick

        const din = in_bytes -| self.rate_last_in;
        const dout = out_bytes -| self.rate_last_out;
        const dt_u: u64 = @intCast(dt);
        const inst_in = din / dt_u;
        const inst_out = dout / dt_u;
        // EWMA: rate = (3*prev + inst) / 4. Smooths bursty piece arrival.
        self.down_rate.store((self.down_rate.load(.monotonic) * 3 + inst_in) / 4, .monotonic);
        self.up_rate.store((self.up_rate.load(.monotonic) * 3 + inst_out) / 4, .monotonic);
        if (din > 0) self.last_progress_s.store(now_s, .monotonic);

        self.rate_last_s = now_s;
        self.rate_last_in = in_bytes;
        self.rate_last_out = out_bytes;
    }

    /// Wire a periodic peer re-discovery callback (see `PeerDiscovery`). Call
    /// before `run`; the loop invokes it on this thread when peers hit zero.
    pub fn setPeerDiscovery(self: *Session, ctx: *anyopaque, run_fn: *const fn (ctx: *anyopaque) void) void {
        self.peer_discovery = .{ .ctx = ctx, .run = run_fn };
    }

    pub fn setOnComplete(self: *Session, ctx: *anyopaque, run_fn: *const fn (ctx: *anyopaque) void) void {
        self.on_complete = .{ .ctx = ctx, .run = run_fn };
    }

    pub fn run(self: *Session) !void {
        const stdout = std.fs.File.stdout().deprecatedWriter();
        const stderr = std.fs.File.stderr().deprecatedWriter();
        // Start the re-discovery clock now so the first retry waits a full
        // interval after any startup discovery the caller already ran.
        self.last_peer_discovery_s = std.time.timestamp();

        const act = std.posix.Sigaction{
            .handler = .{ .handler = sigintHandler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);

        if (self.proxy) |px| {
            log.info(
                "proxy enabled ({s} {s}:{d}); DHT, UDP trackers, web seeds, and incoming peers disabled for anonymity",
                .{ @tagName(px.scheme), px.host, px.port },
            );
            // With DHT and UDP trackers off, an HTTP/HTTPS tracker is the only
            // peer source left. Warn loudly if the torrent has none, otherwise
            // the session polls forever with nothing to discover.
            if (!self.hasProxyUsableTracker()) {
                log.warn(
                    "no proxy-usable peer source: DHT and UDP trackers are disabled and this torrent has no http(s):// tracker. No peers can be found -- add an http(s):// tracker or run without --proxy.",
                    .{},
                );
            }
        }

        // Multi-tracker announce (BEP 12) / DHT peer discovery
        const has_trackers = (self.meta.announce.len > 0) or (self.meta.announce_list != null);
        if (!self.tor_hidden) {
            if (has_trackers) {
                stderr.print("announcing to tracker...\n", .{}) catch {};
            }
            self.doMultiTrackerAnnounce(.started) catch |err| {
                if (has_trackers) {
                    log.debug("all trackers failed: {}", .{err});
                }
            };
        } else {
            log.info("tor hidden-service mode: tracker and DHT announces disabled", .{});
        }

        stdout.print("session started: {d} pieces, {d} bytes\n", .{ self.num_pieces, self.total_length }) catch {};

        while (self.running and !shutdown_requested.load(.acquire)) {
            if (self.mode == .download and !self.metadata_only and self.num_pieces > 0 and self.our_bitfield.isComplete()) {
                stdout.print("\ndownload complete!\n", .{}) catch {};
                self.doMultiTrackerAnnounce(.completed) catch {};
                if (self.on_complete) |cb| cb.run(cb.ctx);

                // By default `download` is done now -- stop the loop and let the
                // process exit instead of lingering as a seeder forever (which,
                // when proxied, can't even accept incoming peers). Opt back into
                // seed-after-download with `--seed`.
                if (!self.seed_after_complete) {
                    // Release the files right away: the Session object can
                    // outlive completion (the daemon keeps it registered until
                    // removal), and a finished download must not hold its
                    // files open — that blocks other programs from using them.
                    self.store.closeFiles();
                    self.running = false;
                    break;
                }

                // Don't open an inbound clearnet listener on any anonymized
                // transport (would leak our IP).
                if (self.listener == null and !self.anonymized()) {
                    const bind_ip: [4]u8 = switch (self.listen_bind) {
                        .any => .{ 0, 0, 0, 0 },
                        .loopback => .{ 127, 0, 0, 1 },
                    };
                    const addr = std.net.Address.initIp4(bind_ip, self.listen_port);
                    self.listener = addr.listen(.{ .reuse_address = true }) catch null;
                }
                self.mode = .seed;
                // Seeding only reads — swap the write handles for read-only
                // ones so the completed files are usable by other programs.
                self.store.downgradeToReadOnly();
                if (!self.anonymized()) {
                    stdout.print("now seeding on port {d}...\n", .{self.listen_port}) catch {};
                } else {
                    stdout.print("download complete; seeding to outbound peers only (anonymized)\n", .{}) catch {};
                }
            }

            var fds: [max_peers + 1]std.posix.pollfd = undefined;
            const nfds = self.buildPollFds(&fds);

            _ = std.posix.poll(fds[0..nfds], 1000) catch 0;

            self.processPollResults(fds[0..nfds]) catch {};

            // Try web seed downloads if available
            if (self.mode == .download and !self.metadata_only) {
                self.tryWebSeedDownload() catch {};
            }

            // Check endgame activation
            if (self.mode == .download and !self.endgame_active) {
                self.checkEndgame();
            }

            self.scheduleRequests() catch {};
            self.maintenance() catch {};
        }

        if (shutdown_requested.load(.acquire)) {
            stderr.print("\nshutting down gracefully...\n", .{}) catch {};
        }
        if (!self.tor_hidden) {
            self.doMultiTrackerAnnounce(.stopped) catch {};
            stderr.print("sent stopped announce to tracker\n", .{}) catch {};
        }
    }

    fn buildPollFds(self: *Session, fds: *[max_peers + 1]std.posix.pollfd) usize {
        var n: usize = 0;

        if (self.listener) |l| {
            fds[n] = .{ .fd = l.stream.handle, .events = std.posix.POLL.IN, .revents = 0 };
            n += 1;
        }

        for (self.peers.items) |p| {
            if (p.state == .disconnected or p.stream == null) continue;
            if (n >= fds.len) break;

            var events: i16 = std.posix.POLL.IN;
            // A clearnet peer mid non-blocking connect becomes writable (POLLOUT)
            // exactly when the connect resolves — poll for that, not POLLIN.
            if (p.state == .connecting) {
                events = std.posix.POLL.OUT;
            } else if (p.wantsSend()) {
                events |= std.posix.POLL.OUT;
            }

            fds[n] = .{ .fd = p.fd(), .events = events, .revents = 0 };
            n += 1;
        }

        return n;
    }

    fn processPollResults(self: *Session, fds: []std.posix.pollfd) !void {
        var fd_idx: usize = 0;

        if (self.listener != null) {
            if (fds[fd_idx].revents & std.posix.POLL.IN != 0) {
                self.acceptIncoming() catch {};
            }
            fd_idx += 1;
        }

        for (self.peers.items) |p| {
            if (p.state == .disconnected or p.stream == null) continue;
            if (fd_idx >= fds.len) break;

            const revents = fds[fd_idx].revents;

            if (revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
                if (p.state == .active) log.debug("peer dropped (HUP/ERR), idle {d}s", .{std.time.timestamp() - p.last_recv_time});
                p.disconnect();
                fd_idx += 1;
                continue;
            }

            // Clearnet non-blocking connect just resolved (socket is writable).
            if (p.state == .connecting) {
                if (revents & std.posix.POLL.OUT != 0) {
                    p.finishConnect(self.info_hash, self.peer_id) catch {
                        p.disconnect();
                        fd_idx += 1;
                        continue;
                    };
                    // Flush the just-queued handshake without waiting a poll cycle.
                    _ = p.flushSend() catch {
                        p.disconnect();
                    };
                }
                fd_idx += 1;
                continue;
            }

            // SOCKS5 proxy connect reply is ready (socket readable).
            if (p.state == .socks_connecting) {
                if (revents & std.posix.POLL.IN != 0) {
                    p.finishProxyConnect(self.info_hash, self.peer_id) catch {
                        p.disconnect();
                        fd_idx += 1;
                        continue;
                    };
                    _ = p.flushSend() catch {
                        p.disconnect();
                    };
                }
                fd_idx += 1;
                continue;
            }

            if (revents & std.posix.POLL.IN != 0) {
                _ = p.readIncoming() catch {
                    if (p.state == .active) log.debug("peer read-err, idle {d}s", .{std.time.timestamp() - p.last_recv_time});
                    p.disconnect();
                    fd_idx += 1;
                    continue;
                };

                if (p.state == .handshaking) {
                    if (p.tryParseHandshake()) |hs| {
                        if (!std.mem.eql(u8, &hs.info_hash, &self.info_hash)) {
                            p.disconnect();
                            fd_idx += 1;
                            continue;
                        }
                        p.peer_id = hs.peer_id;
                        p.state = .active;
                        p.supports_extensions = extension.supportsExtensions(hs.reserved);

                        // BEP 3: send a bitfield as the FIRST message after the
                        // handshake (before extension handshake) — strict peers
                        // reject or stall on a delayed bitfield.
                        if (self.num_pieces > 0) {
                            p.enqueueMessage(.{ .bitfield = self.our_bitfield.rawBytes() }) catch {};
                        }

                        // Send BEP 10 extension handshake if peer supports it
                        if (p.supports_extensions) {
                            const ms = if (self.meta.raw_info.len > 0)
                                std.math.cast(u32, self.meta.raw_info.len)
                            else
                                null;
                            const ext_hs = extension.buildExtensionHandshake(self.allocator, ms, self.listen_port) catch null;
                            if (ext_hs) |hs_payload| {
                                defer self.allocator.free(hs_payload);
                                p.enqueueMessage(.{ .extended = hs_payload }) catch {};
                            }
                        }

                        // Some strict clients stall
                        // (never unchoke) waiting for a bitfield that never comes.
                        if (self.num_pieces > 0) {
                            p.enqueueMessage(.{ .bitfield = self.our_bitfield.rawBytes() }) catch {};
                        }

                        // Only express interest once we know the piece layout
                        // (post-metadata) and can send a bitfield with it.
                        // During the magnet metadata phase num_pieces is 0, so we
                        // have no bitfield — sending interested alone (BEP 3 says
                        // bitfield must precede it) confuses strict peers into
                        // never unchoking us. onMetadataComplete sends both later.
                        if (self.mode == .download and self.num_pieces > 0) {
                            p.am_interested = true;
                            p.enqueueMessage(.interested) catch {};
                        }
                    }
                }

                while (p.state == .active) {
                    const msg = p.nextMessage() catch {
                        p.disconnect();
                        break;
                    };
                    if (msg) |m| {
                        self.handleMessage(p, m) catch {};
                        m.deinit(self.allocator);
                    } else break;
                }
            }

            if (revents & std.posix.POLL.OUT != 0) {
                _ = p.flushSend() catch {
                    p.disconnect();
                };
            }

            fd_idx += 1;
        }
    }

    fn handleMessage(self: *Session, p: *peer_mod.PeerConnection, msg: wire.Message) !void {
        switch (msg) {
            .choke => {
                p.peer_choking = true;
                self.releasePeerRequests(p);
            },
            .unchoke => {
                p.peer_choking = false;
                log.debug("peer unchoked us", .{});
            },
            .interested => {
                p.peer_interested = true;
            },
            .not_interested => {
                p.peer_interested = false;
            },
            .have => |index| {
                if (p.peer_bitfield) |*bf| {
                    if (index < bf.num_pieces) {
                        if (!bf.hasPiece(index)) {
                            bf.setPiece(index);
                            // Update availability
                            if (index < self.piece_availability.len) {
                                self.piece_availability[index] += 1;
                            }
                        }
                    }
                }
                // Re-evaluate interest
                if (self.mode == .download and !p.am_interested) {
                    if (!self.our_bitfield.hasPiece(index)) {
                        p.am_interested = true;
                        p.enqueueMessage(.interested) catch {};
                    }
                }
            },
            .bitfield => |data| {
                // Keep the raw bytes: a bitfield received during the magnet
                // metadata-only phase can't be parsed yet (piece count unknown),
                // and the peer won't resend it. onMetadataComplete re-parses it.
                if (p.raw_bitfield) |old| self.allocator.free(old);
                p.raw_bitfield = self.allocator.dupe(u8, data) catch null;

                if (p.peer_bitfield) |*bf| {
                    // Remove old availability counts
                    self.removeAvailability(bf);
                    bf.deinit(self.allocator);
                    p.peer_bitfield = null;
                }
                if (self.num_pieces > 0) {
                    p.peer_bitfield = piece_mod.Bitfield.fromRaw(self.allocator, data, self.num_pieces) catch null;
                    if (p.peer_bitfield) |*bf| {
                        self.addAvailability(bf);
                        log.debug("peer bitfield: {d}/{d} pieces", .{ bf.count(), self.num_pieces });
                    }
                }

                if (self.mode == .download and !p.am_interested) {
                    if (self.peerHasNeededPieces(p)) {
                        p.am_interested = true;
                        p.enqueueMessage(.interested) catch {};
                    }
                }
            },
            .piece => |pd| {
                try self.onBlockReceived(p, pd);
            },
            .request => |req| {
                try self.handleBlockRequest(p, req);
            },
            .cancel => {},
            .keep_alive => {},
            .extended => |ext_data| {
                self.handleExtension(p, ext_data) catch {};
            },
        }
    }

    fn onBlockReceived(self: *Session, p: *peer_mod.PeerConnection, pd: wire.Message.PieceData) !void {
        p.completePendingRequest(pd.index, pd.begin);
        p.bytes_downloaded += pd.block.len;
        self.block_bytes_in += pd.block.len;

        const pp_ptr = self.active_pieces.get(pd.index) orelse return;
        const complete = pp_ptr.addBlock(pd.begin, pd.block);

        if (complete) {
            log.info("piece {d} complete ({d} bytes received, {d} KiB in), verifying...", .{ pd.index, pp_ptr.piece_len, self.block_bytes_in / 1024 });
            const hash = piece_mod.pieceHash(self.meta.pieces, pd.index) orelse return;

            if (piece_mod.verifyPiece(pp_ptr.data, hash)) {
                log.info("piece {d} VERIFIED + written to disk", .{pd.index});
                self.store.writePiece(pd.index, pp_ptr.data) catch {
                    // Write failed (disk full, I/O error) -- don't mark as complete.
                    // Reset the piece so it can be re-downloaded.
                    pp_ptr.reset();
                    return;
                };
                self.our_bitfield.setPiece(pd.index);
                self.downloaded += pp_ptr.piece_len;
                self.have_pieces.store(self.our_bitfield.count(), .monotonic);

                self.printProgress() catch {};

                for (self.peers.items) |peer| {
                    if (peer.state == .active) {
                        peer.enqueueMessage(.{ .have = pd.index }) catch {};
                        cancelPieceRequests(peer, pd.index);
                    }
                }
            } else {
                log.warn("piece {d} hash mismatch, resetting", .{pd.index});
                pp_ptr.reset();
                return;
            }

            pp_ptr.deinit(self.allocator);
            self.allocator.destroy(pp_ptr);
            _ = self.active_pieces.remove(pd.index);
        }
    }

    fn handleBlockRequest(self: *Session, p: *peer_mod.PeerConnection, req: wire.Message.BlockRequest) !void {
        if (p.am_choking) return;
        if (!self.our_bitfield.hasPiece(req.index)) return;
        if (req.length > piece_mod.block_size) return;

        const plen = piece_mod.pieceLength(req.index, self.piece_len, self.total_length);
        // Non-wrapping bounds check: both fields are attacker-controlled u32s,
        // and `begin + length` could overflow — a panic in ReleaseSafe (remote
        // DoS) or a wrap past the guard in ReleaseFast.
        if (req.length == 0) return;
        if (req.begin >= plen or req.length > plen - req.begin) return;

        const block = self.store.readRange(self.allocator, req.index, req.begin, req.length) catch return;
        defer self.allocator.free(block);

        p.enqueueMessage(.{ .piece = .{
            .index = req.index,
            .begin = req.begin,
            .block = block,
        } }) catch {};

        self.uploaded += req.length;
        p.bytes_uploaded += req.length;
    }

    // --- BEP 10/9 Extension handling ---

    fn handleExtension(self: *Session, p: *peer_mod.PeerConnection, ext_data: []const u8) !void {
        if (ext_data.len < 1) return;

        if (ext_data[0] == extension.handshake_ext_id) {
            // Extension handshake
            var hs = extension.parseExtensionHandshake(self.allocator, ext_data) catch return;
            defer hs.deinit(self.allocator);

            p.peer_ut_metadata_id = hs.ut_metadata_id;
            p.peer_metadata_size = hs.metadata_size;

            if (hs.client_name) |name| {
                log.debug("peer extension handshake: {s}", .{name});
            }

            // If we're in metadata download mode, set size and request pieces
            if (self.metadata_download) |*md| {
                if (hs.metadata_size) |ms| {
                    md.setSize(ms) catch return;
                    self.meta_total.store(md.num_pieces, .monotonic);
                    log.info("metadata size: {d} bytes ({d} pieces)", .{ ms, md.num_pieces });
                    self.requestMetadataPieces(p) catch {};
                }
            }
        } else {
            // Check if this is a ut_metadata message (our assigned ID is 1)
            if (ext_data[0] == 1) {
                self.handleMetadataMessage(p, ext_data) catch {};
            }
        }
    }

    fn handleMetadataMessage(self: *Session, p: *peer_mod.PeerConnection, ext_data: []const u8) !void {
        var msg = extension.parseMetadataMessage(self.allocator, ext_data) catch return;
        defer msg.deinit(self.allocator);

        switch (msg.msg_type) {
            .data => {
                // Only meaningful while we're fetching metadata. A seeder that
                // already has the info dict has no metadata_download and just
                // ignores stray data messages.
                var md = &(self.metadata_download orelse return);
                if (msg.data) |data| {
                    if (msg.total_size) |ts| {
                        md.setSize(ts) catch return;
                        // Publish the total here too: a peer can send `.data`
                        // before any extended handshake set the size, and we must
                        // never expose have>0 with total==0 (a "5/0" display and
                        // a divide-by-zero for any percentage the UI computes).
                        self.meta_total.store(md.num_pieces, .monotonic);
                    }

                    const complete = md.addPiece(msg.piece, data) catch return;
                    // Count metadata bytes toward the download rate so the
                    // metadata-fetch phase shows real speed (piece `downloaded`
                    // is still 0 here), and publish progress for the snapshot.
                    self.meta_bytes_in += data.len;
                    self.meta_have.store(md.received_count, .monotonic);
                    log.info("metadata piece {d}/{d}", .{ md.received_count, md.num_pieces });

                    if (!complete) {
                        // Request more pieces from this peer
                        self.requestMetadataPieces(p) catch {};
                    } else if (complete) {
                        log.info("all metadata pieces received, verifying...", .{});
                        if (md.assemble() catch null) |raw_info| {
                            // onMetadataComplete dupes what it keeps, so the
                            // assembled buffer is ours to free either way.
                            defer self.allocator.free(raw_info);
                            log.info("metadata verified! parsing torrent info...", .{});
                            self.onMetadataComplete(raw_info) catch {};
                        } else {
                            log.warn("metadata hash mismatch, retrying...", .{});
                            // Reset and try again. `metadata_download` is private
                            // to the session thread (the snapshot reads the
                            // `meta_have`/`meta_total` atomics, not the tracker),
                            // so no lock is needed — just restate progress as 0.
                            md.deinit();
                            self.metadata_download = extension.MetadataDownload.init(self.allocator, self.info_hash);
                            self.meta_have.store(0, .monotonic);
                            self.meta_total.store(0, .monotonic);
                        }
                    }
                }
            },
            .reject => {
                log.debug("metadata piece {d} rejected by peer", .{msg.piece});
            },
            .request => {
                // Serve our metadata if we have it
                if (self.meta.raw_info.len > 0) {
                    self.serveMetadataPiece(p, msg.piece) catch {};
                }
            },
        }
    }

    fn requestMetadataPieces(self: *Session, p: *peer_mod.PeerConnection) !void {
        const md = &(self.metadata_download orelse return);
        const peer_id = p.peer_ut_metadata_id orelse return;

        // Request up to 5 pieces at a time to avoid flooding
        var requested: u32 = 0;
        for (0..md.num_pieces) |i| {
            const idx: u32 = @intCast(i);
            if (md.pieces.len > idx and md.pieces[idx] != null) continue; // already have it

            const req_payload = extension.buildMetadataRequest(self.allocator, peer_id, idx) catch return;
            defer self.allocator.free(req_payload);
            p.enqueueMessage(.{ .extended = req_payload }) catch return;

            requested += 1;
            if (requested >= 5) break;
        }
    }

    fn serveMetadataPiece(self: *Session, p: *peer_mod.PeerConnection, piece_idx: u32) !void {
        const peer_id = p.peer_ut_metadata_id orelse return;
        if (self.meta.raw_info.len == 0) return;

        const mps = extension.metadata_piece_size;
        const start: usize = @as(usize, piece_idx) * mps;
        if (start >= self.meta.raw_info.len) return;

        const end = @min(start + mps, self.meta.raw_info.len);
        const piece_data = self.meta.raw_info[start..end];
        const total_size: u32 = std.math.cast(u32, self.meta.raw_info.len) orelse return;

        const payload = extension.buildMetadataData(
            self.allocator,
            peer_id,
            piece_idx,
            total_size,
            piece_data,
        ) catch return;
        defer self.allocator.free(payload);
        p.enqueueMessage(.{ .extended = payload }) catch {};
    }

    /// Deep-copy a BEP-12 announce-list (tiers of tracker URLs). Returns null
    /// for a null input. On failure, frees everything allocated so far.
    fn dupeAnnounceList(
        allocator: std.mem.Allocator,
        src: ?[]const []const []const u8,
    ) error{OutOfMemory}!?[]const []const []const u8 {
        const tiers = src orelse return null;
        const out = try allocator.alloc([]const []const u8, tiers.len);
        var done: usize = 0;
        errdefer {
            for (out[0..done]) |tier| {
                for (tier) |url| allocator.free(url);
                allocator.free(tier);
            }
            allocator.free(out);
        }
        for (tiers, 0..) |tier, i| {
            const out_tier = try allocator.alloc([]const u8, tier.len);
            var filled: usize = 0;
            errdefer {
                for (out_tier[0..filled]) |url| allocator.free(url);
                allocator.free(out_tier);
            }
            for (tier, 0..) |url, j| {
                out_tier[j] = try allocator.dupe(u8, url);
                filled = j + 1;
            }
            out[i] = out_tier;
            done = i + 1;
        }
        return out;
    }

    fn onMetadataComplete(self: *Session, raw_info: []const u8) !void {
        // Parse the info dict to build a Metainfo struct
        const info_val = bencode.decode(self.allocator, raw_info) catch return error.InvalidMetadata;
        defer info_val.deinit(self.allocator);

        // Extract fields from info dict
        const name_val = info_val.dictGet("name") orelse return error.InvalidMetadata;
        const name_str = name_val.asString() orelse return error.InvalidMetadata;

        const pl_val = info_val.dictGet("piece length") orelse return error.InvalidMetadata;
        const piece_length = std.math.cast(u64, pl_val.asInt() orelse return error.InvalidMetadata) orelse return error.InvalidMetadata;

        const pieces_val = info_val.dictGet("pieces") orelse return error.InvalidMetadata;
        const pieces_str = pieces_val.asString() orelse return error.InvalidMetadata;

        // Build file list (single-file or multi-file)
        const files = if (info_val.dictGet("files")) |files_val| blk: {
            const file_list = files_val.asList() orelse return error.InvalidMetadata;
            var files_arr: std.ArrayList(metainfo.FileInfo) = .empty;
            errdefer {
                for (files_arr.items) |fi| {
                    for (fi.path) |comp| self.allocator.free(comp);
                    self.allocator.free(fi.path);
                }
                files_arr.deinit(self.allocator);
            }
            for (file_list) |file_val| {
                const fl_val = file_val.dictGet("length") orelse continue;
                const fl: u64 = std.math.cast(u64, fl_val.asInt() orelse continue) orelse continue;
                const fp_val = file_val.dictGet("path") orelse continue;
                const fp_list = fp_val.asList() orelse continue;
                var path_arr: std.ArrayList([]const u8) = .empty;
                errdefer {
                    for (path_arr.items) |comp| self.allocator.free(comp);
                    path_arr.deinit(self.allocator);
                }
                for (fp_list) |comp_val| {
                    const cs = comp_val.asString() orelse continue;
                    const comp = self.allocator.dupe(u8, cs) catch return error.OutOfMemory;
                    path_arr.append(self.allocator, comp) catch {
                        self.allocator.free(comp);
                        return error.OutOfMemory;
                    };
                }
                if (path_arr.items.len == 0) {
                    path_arr.deinit(self.allocator);
                    continue;
                }
                const fi_path = path_arr.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
                files_arr.append(self.allocator, .{ .length = fl, .path = fi_path }) catch {
                    for (fi_path) |comp| self.allocator.free(comp);
                    self.allocator.free(fi_path);
                    return error.OutOfMemory;
                };
            }
            if (files_arr.items.len == 0) return error.InvalidMetadata;
            break :blk @as([]const metainfo.FileInfo, files_arr.toOwnedSlice(self.allocator) catch return error.OutOfMemory);
        } else blk: {
            const length_val = info_val.dictGet("length") orelse return error.InvalidMetadata;
            const length = std.math.cast(u64, length_val.asInt() orelse return error.InvalidMetadata) orelse return error.InvalidMetadata;

            const path_comp = self.allocator.dupe(u8, name_str) catch return error.OutOfMemory;
            const path = self.allocator.alloc([]const u8, 1) catch {
                self.allocator.free(path_comp);
                return error.OutOfMemory;
            };
            path[0] = path_comp;

            const file_slice = self.allocator.alloc(metainfo.FileInfo, 1) catch {
                self.allocator.free(path_comp);
                self.allocator.free(path);
                return error.OutOfMemory;
            };
            file_slice[0] = .{ .length = length, .path = path };
            break :blk @as([]const metainfo.FileInfo, file_slice);
        };

        const name = self.allocator.dupe(u8, name_str) catch return error.OutOfMemory;
        const pieces = self.allocator.dupe(u8, pieces_str) catch {
            self.allocator.free(name);
            return error.OutOfMemory;
        };
        const raw_info_dup = self.allocator.dupe(u8, raw_info) catch {
            self.allocator.free(name);
            self.allocator.free(pieces);
            return error.OutOfMemory;
        };

        // Dupe announce + announce_list so the replacement Metainfo owns every
        // field. The original `meta` (and its announce/announce_list) stays
        // owned by the caller; mixing the two would risk a double free.
        const announce_dup = self.allocator.dupe(u8, self.meta.announce) catch {
            self.allocator.free(name);
            self.allocator.free(pieces);
            self.allocator.free(raw_info_dup);
            return error.OutOfMemory;
        };
        const announce_list_dup = dupeAnnounceList(self.allocator, self.meta.announce_list) catch {
            self.allocator.free(name);
            self.allocator.free(pieces);
            self.allocator.free(raw_info_dup);
            self.allocator.free(announce_dup);
            return error.OutOfMemory;
        };

        // Update session with the new metadata. From here `meta` is fully owned
        // by the session and freed in deinit (see `meta_owned`).
        self.meta = .{
            .announce = announce_dup,
            .announce_list = announce_list_dup,
            .name = name,
            .piece_length = piece_length,
            .pieces = pieces,
            .files = files,
            .comment = null,
            .creation_date = null,
            .created_by = null,
            .raw_info = raw_info_dup,
            .url_list = null,
        };
        self.meta_owned = true;

        // Now initialize storage and piece tracking. Hold snapshot_mutex across
        // the geometry + bitfield swap so a concurrent `progressSnapshot` never
        // reads a freed `our_bitfield` (the daemon reads it from another thread).
        {
            self.snapshot_mutex.lock();
            defer self.snapshot_mutex.unlock();

            self.total_length = piece_mod.totalLength(self.meta.files);
            self.num_pieces = piece_mod.numPieces(self.total_length, piece_length);
            self.piece_len = piece_length;

            self.our_bitfield.deinit(self.allocator);
            self.our_bitfield = piece_mod.Bitfield.init(self.allocator, self.num_pieces) catch return error.OutOfMemory;
            // Fresh bitfield for a just-resolved magnet: we have nothing yet.
            self.have_pieces.store(0, .monotonic);

            self.allocator.free(self.piece_availability);
            self.piece_availability = self.allocator.alloc(u32, self.num_pieces) catch return error.OutOfMemory;
            @memset(self.piece_availability, 0);
        }

        // Reinitialize storage with the real metadata
        self.store.deinit();
        self.store = storage_mod.Storage.init(self.allocator, self.meta, self.output_dir, true) catch
            return error.StorageInitFailed;

        // Metadata is in; clear the fetch-progress atomics BEFORE flipping to
        // download mode, so a snapshot that observes `metadata_only == false`
        // never also sees a stale near-complete have/total.
        self.meta_have.store(0, .monotonic);
        self.meta_total.store(0, .monotonic);

        // Switch from metadata-only to download mode. `metadata_only` is read by
        // `progressSnapshot` from the daemon thread, so flip it under
        // snapshot_mutex; the tracker itself is session-private (the snapshot
        // reads the meta atomics, not the tracker).
        {
            self.snapshot_mutex.lock();
            defer self.snapshot_mutex.unlock();
            // Update the published tracker URL from the resolved metadata.
            if (self.src_tracker_url) |old| self.allocator.free(old);
            self.src_tracker_url = if (self.meta.announce.len > 0)
                self.allocator.dupe(u8, self.meta.announce) catch null
            else
                null;
            self.metadata_only = false;
        }
        if (self.metadata_download) |*md| md.deinit();
        self.metadata_download = null;

        // Capture the now-resolved .torrent so the daemon can persist it and
        // resume this torrent fully on restart. Built here where `meta` is
        // settled; published under snapshot_mutex for the reader thread.
        if (buildTorrentBytes(self.allocator, self.meta)) |blob| {
            self.snapshot_mutex.lock();
            self.torrent_blob = blob;
            self.snapshot_mutex.unlock();
        } else |_| {}

        // Re-parse any bitfields that arrived before we knew the piece count, so
        // peers connected during the metadata phase are usable for downloading
        // immediately (otherwise we'd think they have no pieces and stall).
        for (self.peers.items) |p| {
            if (p.state != .active) continue;
            if (p.raw_bitfield) |raw| {
                if (p.peer_bitfield) |*bf| {
                    self.removeAvailability(bf);
                    bf.deinit(self.allocator);
                    p.peer_bitfield = null;
                }
                p.peer_bitfield = piece_mod.Bitfield.fromRaw(self.allocator, raw, self.num_pieces) catch null;
                if (p.peer_bitfield) |*bf| self.addAvailability(bf);
            }
            // Peers that connected during the metadata phase never registered our
            // interest. Re-express interest so they unchoke us for the data phase.
            // Do NOT send a bitfield here — BEP 3 requires it only immediately
            // after the handshake; a delayed bitfield can cause strict peers to
            // reject the connection.
            p.am_interested = true;
            p.enqueueMessage(.interested) catch {};
        }

        log.info("metadata complete: '{s}', {d} pieces, {d} bytes", .{ name, self.num_pieces, self.total_length });
    }

    // --- Piece selection: rarest-first ---

    fn scheduleRequests(self: *Session) !void {
        if (self.mode != .download) return;

        for (self.peers.items) |p| {
            if (p.state != .active) continue;

            if (self.endgame_active) {
                self.scheduleEndgameRequests(p);
                continue;
            }

            outer: while (p.canRequest()) {
                const idx = self.pickRarestPiece(p) orelse break;

                const pp_ptr = self.active_pieces.get(idx) orelse blk: {
                    const plen = piece_mod.pieceLength(idx, self.piece_len, self.total_length);
                    const pp = self.allocator.create(piece_mod.PieceProgress) catch break;
                    pp.* = piece_mod.PieceProgress.init(self.allocator, idx, plen) catch {
                        self.allocator.destroy(pp);
                        break;
                    };
                    self.active_pieces.put(idx, pp) catch {
                        pp.deinit(self.allocator);
                        self.allocator.destroy(pp);
                        break;
                    };
                    break :blk pp;
                };

                // Fill the pipeline from this piece before picking another:
                // picking is O(num_pieces), the blocks within are O(1). Each
                // scheduled block is marked in flight so neither this loop nor
                // another peer re-requests it (the marks are released on
                // choke, disconnect, and timeout).
                while (p.canRequest()) {
                    const block_idx = pp_ptr.nextUnrequestedBlock() orelse continue :outer;
                    const spec = pp_ptr.blockSpec(block_idx);

                    const req = wire.Message.BlockRequest{
                        .index = idx,
                        .begin = spec.begin,
                        .length = spec.length,
                    };

                    p.enqueueMessage(.{ .request = req }) catch break :outer;
                    p.addPendingRequest(req) catch break :outer;
                    pp_ptr.markRequested(block_idx);
                }
            }
        }
    }

    /// Endgame: request every still-missing block from every peer that has
    /// it. Duplicates across peers are intentional (first response wins, the
    /// completion path cancels the rest), but a peer never duplicates a block
    /// within its own pipeline.
    fn scheduleEndgameRequests(self: *Session, p: *peer_mod.PeerConnection) void {
        for (0..self.num_pieces) |i| {
            if (!p.canRequest()) return;
            const idx: u32 = @intCast(i);
            if (self.our_bitfield.hasPiece(idx)) continue;
            if (!p.hasPiece(idx)) continue;
            const pp = self.active_pieces.get(idx) orelse continue;

            for (0..pp.num_blocks) |b| {
                if (!p.canRequest()) return;
                const block_idx: u32 = @intCast(b);
                if (pp.hasBlock(block_idx)) continue;
                const spec = pp.blockSpec(block_idx);
                if (p.hasPendingRequest(idx, spec.begin)) continue;

                const req = wire.Message.BlockRequest{
                    .index = idx,
                    .begin = spec.begin,
                    .length = spec.length,
                };
                p.enqueueMessage(.{ .request = req }) catch return;
                p.addPendingRequest(req) catch return;
                pp.markRequested(block_idx);
            }
        }
    }

    /// Release every in-flight request this peer holds back to the scheduler
    /// (clearing the per-piece `requested` marks) and drop them from the
    /// peer's pipeline. Used on choke and disconnect — a leaked mark would
    /// make its block permanently unschedulable.
    fn releasePeerRequests(self: *Session, p: *peer_mod.PeerConnection) void {
        for (p.pending_requests.items) |r| {
            if (self.active_pieces.get(r.index)) |pp| {
                pp.clearRequested(r.begin / piece_mod.block_size);
            }
        }
        p.clearPendingRequests();
    }

    /// Release (and cancel) requests the peer has sat on longer than
    /// `request_timeout_secs`, so a connected-but-unresponsive peer can't
    /// hold blocks hostage while other peers could fetch them.
    fn expireStaleRequests(self: *Session, p: *peer_mod.PeerConnection, now: i64) void {
        var i: usize = 0;
        while (i < p.pending_requests.items.len) {
            const r = p.pending_requests.items[i];
            if (now - r.requested_at > request_timeout_secs) {
                if (self.active_pieces.get(r.index)) |pp| {
                    pp.clearRequested(r.begin / piece_mod.block_size);
                }
                p.enqueueMessage(.{ .cancel = .{ .index = r.index, .begin = r.begin, .length = r.length } }) catch {};
                _ = p.pending_requests.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Cancel a peer's outstanding requests for a piece that just completed
    /// (endgame requests the same block from several peers; without a cancel
    /// every one of them answers with redundant data).
    fn cancelPieceRequests(p: *peer_mod.PeerConnection, index: u32) void {
        var i: usize = 0;
        while (i < p.pending_requests.items.len) {
            const r = p.pending_requests.items[i];
            if (r.index == index) {
                p.enqueueMessage(.{ .cancel = .{ .index = r.index, .begin = r.begin, .length = r.length } }) catch {};
                _ = p.pending_requests.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Rarest-first piece selection (BEP 3 recommended).
    fn pickRarestPiece(self: *Session, p: *peer_mod.PeerConnection) ?u32 {
        var best_idx: ?u32 = null;
        var best_avail: u32 = std.math.maxInt(u32);

        for (0..self.num_pieces) |i| {
            const idx: u32 = @intCast(i);
            if (self.our_bitfield.hasPiece(idx)) continue;
            if (!p.hasPiece(idx)) continue;

            // Skip if already active with every block received or in flight
            if (self.active_pieces.get(idx)) |pp| {
                if (pp.nextUnrequestedBlock() == null) continue;
            } else {
                // Piece concentration: don't start a new piece when we already
                // have max_concurrent_pieces in progress. Concentrating blocks
                // on fewer pieces lets them complete (verify + write + share)
                // instead of spreading thin across dozens that never finish.
                // Override: if NO existing active piece is requestable by this
                // peer (all supplied by disconnected peers), allow a new piece
                // so the download doesn't stall.
                if (self.active_pieces.count() >= max_concurrent_pieces) {
                    var any_requestable = false;
                    var it = self.active_pieces.iterator();
                    while (it.next()) |entry| {
                        if (p.hasPiece(entry.key_ptr.*) and entry.value_ptr.*.nextUnrequestedBlock() != null) {
                            any_requestable = true;
                            break;
                        }
                    }
                    if (!any_requestable) continue;
                }
            }

            const avail = if (idx < self.piece_availability.len) self.piece_availability[idx] else 0;
            if (avail < best_avail) {
                best_avail = avail;
                best_idx = idx;
            }
        }

        return best_idx;
    }

    // --- Endgame mode ---

    fn checkEndgame(self: *Session) void {
        // Enter endgame when all remaining pieces are already in active_pieces
        var missing: u32 = 0;
        var active: u32 = 0;
        for (0..self.num_pieces) |i| {
            const idx: u32 = @intCast(i);
            if (!self.our_bitfield.hasPiece(idx)) {
                missing += 1;
                if (self.active_pieces.contains(idx)) active += 1;
            }
        }
        if (missing > 0 and missing == active and missing <= 5) {
            self.endgame_active = true;
            const stderr = std.fs.File.stderr().deprecatedWriter();
            stderr.print("endgame mode: {d} pieces remaining\n", .{missing}) catch {};
        }
    }

    // --- Choking algorithm (BEP 3) ---

    fn runChokingAlgorithm(self: *Session) void {
        const now = std.time.timestamp();

        // Regular unchoke: every 10 seconds
        if (now - self.last_unchoke_time >= unchoke_interval_secs) {
            self.last_unchoke_time = now;
            self.regularUnchoke();
        }

        // Optimistic unchoke: every 30 seconds
        if (now - self.last_optimistic_time >= optimistic_interval_secs) {
            self.last_optimistic_time = now;
            self.optimisticUnchoke();
        }
    }

    fn regularUnchoke(self: *Session) void {
        // Sort interested peers by download rate (what they give us)
        // and unchoke the top `unchoke_slots`
        var interested_peers: [max_peers]*peer_mod.PeerConnection = undefined;
        var count: usize = 0;

        for (self.peers.items) |p| {
            if (p.state != .active) continue;
            if (!p.peer_interested) continue;
            if (count < interested_peers.len) {
                interested_peers[count] = p;
                count += 1;
            }
        }

        // Sort: tit-for-tat when downloading (prefer peers that upload to us the
        // most); when seeding, prefer peers that download from us fastest so we
        // maximize outbound throughput and distribution.
        const slice = interested_peers[0..count];
        const seeding = self.mode == .seed;
        std.mem.sort(*peer_mod.PeerConnection, slice, seeding, struct {
            fn cmp(s: bool, a: *peer_mod.PeerConnection, b: *peer_mod.PeerConnection) bool {
                if (s) return a.bytes_uploaded > b.bytes_uploaded;
                return a.bytes_downloaded > b.bytes_downloaded;
            }
        }.cmp);

        // Unchoke top N, choke the rest
        for (slice, 0..) |p, i| {
            if (i < unchoke_slots or p == self.optimistic_peer) {
                if (p.am_choking) {
                    p.am_choking = false;
                    p.enqueueMessage(.unchoke) catch {};
                }
            } else {
                if (!p.am_choking) {
                    p.am_choking = true;
                    p.enqueueMessage(.choke) catch {};
                }
            }
        }
    }

    fn optimisticUnchoke(self: *Session) void {
        // Pick a random choked interested peer
        var candidates: [max_peers]*peer_mod.PeerConnection = undefined;
        var count: usize = 0;

        for (self.peers.items) |p| {
            if (p.state != .active) continue;
            if (!p.peer_interested) continue;
            if (!p.am_choking) continue; // already unchoked
            if (count < candidates.len) {
                candidates[count] = p;
                count += 1;
            }
        }

        if (count > 0) {
            const idx = std.crypto.random.intRangeAtMost(usize, 0, count - 1);
            const p = candidates[idx];
            p.am_choking = false;
            p.enqueueMessage(.unchoke) catch {};
            self.optimistic_peer = p;
        }
    }

    // --- Availability tracking ---

    fn addAvailability(self: *Session, bf: *const piece_mod.Bitfield) void {
        for (0..self.num_pieces) |i| {
            const idx: u32 = @intCast(i);
            if (bf.hasPiece(idx) and idx < self.piece_availability.len) {
                self.piece_availability[idx] += 1;
            }
        }
    }

    fn removeAvailability(self: *Session, bf: *const piece_mod.Bitfield) void {
        for (0..self.num_pieces) |i| {
            const idx: u32 = @intCast(i);
            if (bf.hasPiece(idx) and idx < self.piece_availability.len) {
                if (self.piece_availability[idx] > 0) {
                    self.piece_availability[idx] -= 1;
                }
            }
        }
    }

    fn peerHasNeededPieces(self: *Session, p: *peer_mod.PeerConnection) bool {
        for (0..self.num_pieces) |i| {
            const idx: u32 = @intCast(i);
            if (!self.our_bitfield.hasPiece(idx) and p.hasPiece(idx)) return true;
        }
        return false;
    }

    // --- Connection management ---

    fn acceptIncoming(self: *Session) !void {
        var l = self.listener orelse return;
        const conn = l.accept() catch return;

        if (self.peers.items.len >= max_peers) {
            conn.stream.close();
            return;
        }

        const p = self.allocator.create(peer_mod.PeerConnection) catch {
            conn.stream.close();
            return;
        };
        p.* = peer_mod.PeerConnection.init(self.allocator, conn.address);
        p.stream = conn.stream;
        peer_mod.PeerConnection.setNoDelay(conn.stream);
        p.state = .handshaking;

        p.sendHandshake(self.info_hash, self.peer_id) catch {
            p.deinit();
            self.allocator.destroy(p);
            return;
        };

        self.peers.append(self.allocator, p) catch {
            p.deinit();
            self.allocator.destroy(p);
        };
    }

    fn maintenance(self: *Session) !void {
        const now = std.time.timestamp();

        // Resample the live transfer rate (≤ once a second; `now` is seconds).
        self.sampleRate(now);

        // Publish the live peer count for the daemon's cross-thread snapshot.
        // Refreshed each tick here (and just below after pruning) so the daemon
        // never reads `self.peers` directly. One tick of staleness is invisible
        // to the 1 Hz snapshot.
        self.peer_count.store(self.peers.items.len, .monotonic);

        // Remove disconnected peers and update availability
        var i: usize = 0;
        while (i < self.peers.items.len) {
            const p = self.peers.items[i];
            if (p.state == .disconnected) {
                if (p.peer_bitfield) |*bf| {
                    self.removeAvailability(bf);
                }
                self.releasePeerRequests(p);
                p.deinit();
                self.allocator.destroy(p);
                _ = self.peers.orderedRemove(i);
            } else {
                // A clearnet peer stuck in the non-blocking connect phase past
                // the connect timeout is a dead host — reclaim its poll slot so
                // it doesn't squat against the max_peers cap.
                if ((p.state == .connecting or p.state == .socks_connecting) and now - p.connect_started_at > peer_mod.PeerConnection.connect_timeout_secs) {
                    p.disconnect();
                    i += 1;
                    continue;
                }
                if (now - p.last_send_time > 60) {
                    p.enqueueMessage(.keep_alive) catch {};
                }
                if (now - p.last_recv_time > 120) {
                    p.disconnect();
                }
                i += 1;
            }
        }

        // Once a second: resize each peer's request pipeline from its
        // measured rate and release requests the peer has sat on too long.
        const peer_dt = now - self.peer_tick_last_s;
        if (peer_dt >= 1) {
            self.peer_tick_last_s = now;
            for (self.peers.items) |p| {
                if (p.state != .active) continue;
                p.updatePipelineLimit(peer_dt);
                self.expireStaleRequests(p, now);
            }
            // Publish per-file snapshot for the daemon's cross-thread reads.
            self.publishFileSnap();
            // Publish the DHT node count from the last completed lookup and
            // consume any peers it found (connects happen on this thread).
            if (self.dht_state) |st| {
                st.mutex.lock();
                const nodes = st.nodes;
                const peers = st.peers;
                st.peers = &.{};
                st.mutex.unlock();
                self.src_dht_nodes.store(nodes, .monotonic);
                if (peers.len > 0) {
                    log.info("DHT found {d} peers", .{peers.len});
                    self.connectToPeers(peers) catch {};
                    self.allocator.free(peers);
                }
            }
        }

        // Run choking algorithm
        self.runChokingAlgorithm();

        if (!self.tor_hidden) {
            // Re-announce to trackers at the tracker-provided interval
            const interval_secs = std.math.cast(i64, self.tracker_interval) orelse 1800;
            if (now - self.last_announce_time > interval_secs) {
                self.doMultiTrackerAnnounce(.none) catch {};
            }

            // DHT: retry more aggressively when we have zero peers
            if (self.peers.items.len == 0 and now - self.last_announce_time > 30) {
                self.tryDhtPeerDiscovery() catch {};
            }
        }

        // Peer replenishment: keep the pool topped up. In a mostly-NAT'd public
        // swarm most tracker peers are unreachable, so a single connect burst
        // leaves us with almost nothing. Cycle through the cached list (skipping
        // peers already connected) until the pool reaches a healthy count.
        if (self.mode == .download and self.peers.items.len < 30 and self.cached_peers.len > 0 and now - self.last_replenish_s >= 3) {
            self.last_replenish_s = now;
            self.connectToPeers(self.cached_peers) catch {};
        }

        // Nostr: while DOWNLOADING with zero peers, periodically re-query the
        // relays for fresh peer-announces — a seed may have appeared or come
        // back. Runs on this (the session) thread, so the callback adds peers
        // safely. Gated on download mode + zero peers so it never duplicates a
        // live connection, competes with an active download, or fires once the
        // transfer has completed and is only seeding (dialing out is pointless
        // then); rate-limited because relay queries are slow.
        if (self.peer_discovery) |pd| {
            if (self.mode == .download and self.peers.items.len == 0 and now - self.last_peer_discovery_s > peer_rediscovery_interval_secs) {
                self.last_peer_discovery_s = now;
                pd.run(pd.ctx);
            }
        }
    }

    // --- Multi-tracker announce (BEP 12 + BEP 15) ---

    fn doMultiTrackerAnnounce(self: *Session, event: tracker_mod.Event) !void {
        const req = tracker_mod.AnnounceRequest{
            .info_hash = self.info_hash,
            .peer_id = self.peer_id,
            .port = self.listen_port,
            .uploaded = self.uploaded,
            .downloaded = self.downloaded,
            .left = self.computeLeft(),
            .compact = true,
            .event = event,
        };

        // Terminal events (completed/stopped) just need one tracker ack;
        // discovery events (started/none) need actual peers.
        const wants_peers = event != .completed and event != .stopped;

        // Try announce-list tiers first (BEP 12).
        // Standard BEP 12 stops at the first successful response in a tier,
        // but a 0-peer response is useless for discovery — keep trying the
        // next tracker in the tier until peers appear.  Terminal events
        // return after any successful ack.
        if (self.meta.announce_list) |tiers| {
            for (tiers) |tier| {
                for (tier) |url| {
                    if (self.tryAnnounceUrl(url, req)) |resp| {
                        self.handleAnnounceResponse(resp);
                        if (!wants_peers or self.peers.items.len > 0) return;
                    }
                }
            }
        }

        // Fall back to primary announce URL
        if (self.peers.items.len == 0 and self.meta.announce.len > 0) {
            if (self.tryAnnounceUrl(self.meta.announce, req)) |resp| {
                self.handleAnnounceResponse(resp);
                if (!wants_peers or self.peers.items.len > 0) return;
            }
        }

        // Fall back to DHT (BEP 5) — only for discovery, not terminal events.
        // Discovery is asynchronous now: this only starts the walk, and
        // maintenance() connects whatever it finds a few ticks later. There is
        // deliberately no peers check here — it could only ever be false.
        if (wants_peers and self.peers.items.len == 0) {
            self.tryDhtPeerDiscovery() catch {};
        }

        return error.TrackerFailed;
    }

    /// Whether any announce URL can be used while proxied. HTTP/HTTPS
    /// trackers are tunneled directly; UDP trackers are rewritten to HTTP
    /// and tunneled (most public trackers serve both protocols).
    fn hasProxyUsableTracker(self: *Session) bool {
        if (self.meta.announce.len > 0) return true;
        if (self.meta.announce_list) |tiers| {
            for (tiers) |tier| {
                if (tier.len > 0) return true;
            }
        }
        return false;
    }

    fn tryAnnounceUrl(self: *Session, url: []const u8, req: tracker_mod.AnnounceRequest) ?tracker_mod.AnnounceResponse {
        // I2P (anonymized with no SOCKS/HTTP proxy) can't reach clearnet
        // trackers, and announcing over them directly would leak the real IP.
        // (I2P-native trackers are a follow-up.) Skip all clearnet trackers.
        if (self.anonymized() and self.proxy == null) return null;
        if (std.mem.startsWith(u8, url, "udp://")) {
            if (self.proxy != null) {
                // UDP can't be tunneled through SOCKS/Tor.  Most public
                // trackers serve both UDP and HTTP on the same host, so
                // rewrite udp://host:port → http://host:port/announce and
                // try through the proxy.
                return self.tryUdpAsHttp(url, req);
            }
            return udp_tracker.announce(self.allocator, url, req) catch |err| {
                log.warn("UDP tracker {s} failed: {}", .{ url, err });
                return null;
            };
        } else if (url.len > 0) {
            return tracker_mod.announce(self.allocator, url, req, self.proxy) catch |err| {
                log.warn("HTTP tracker {s} failed: {}", .{ url, err });
                return null;
            };
        } else {
            return null;
        }
    }

    /// Rewrite a udp:// tracker URL to http:// and try an HTTP announce
    /// through the proxy.  Many public trackers (opentrackr, openbittorrent,
    /// torrent.eu.org, …) serve both protocols on the same host:port.
    fn tryUdpAsHttp(self: *Session, udp_url: []const u8, req: tracker_mod.AnnounceRequest) ?tracker_mod.AnnounceResponse {
        // udp://host:port[/anything] → http://host:port/announce
        const host_start = "udp://".len;
        const rest = udp_url[host_start..];
        // Find end of host:port (first '/' or end of string)
        const slash_pos = std.mem.indexOfScalar(u8, rest, '/');
        const host_port = rest[0..(slash_pos orelse rest.len)];

        var buf: [256]u8 = undefined;
        const http_url = std.fmt.bufPrint(&buf, "http://{s}/announce", .{host_port}) catch return null;

        const resp = tracker_mod.announce(self.allocator, http_url, req, self.proxy) catch |err| {
            log.debug("HTTP rewrite of UDP tracker {s} failed: {}", .{ udp_url, err });
            return null;
        };
        log.info("proxied: rewriting {s} → {s}", .{ udp_url, http_url });
        return resp;
    }

    fn handleAnnounceResponse(self: *Session, resp: tracker_mod.AnnounceResponse) void {
        defer resp.deinit(self.allocator);

        if (resp.failure_reason) |reason| {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            stderr.print("tracker error: {s}\n", .{reason}) catch {};
            return;
        }

        self.tracker_interval = resp.interval;
        self.last_announce_time = std.time.timestamp();

        // Publish source snapshot data for cross-thread reads.
        self.src_tracker_state.store(1, .monotonic);
        self.src_seeders.store(@intCast(resp.complete orelse 0), .monotonic);
        self.src_leechers.store(@intCast(resp.incomplete orelse 0), .monotonic);
        self.src_announce_interval_s.store(@intCast(resp.interval), .monotonic);
        self.src_last_announce_s.store(self.last_announce_time, .monotonic);

        const stderr = std.fs.File.stderr().deprecatedWriter();
        stderr.print("tracker: {d} peers", .{resp.peers.len}) catch {};
        if (resp.complete) |c| stderr.print(", {d} seeders", .{c}) catch {};
        if (resp.incomplete) |ic| stderr.print(", {d} leechers", .{ic}) catch {};
        stderr.print("\n", .{}) catch {};

        // Cache the peer list so maintenance can replenish the pool as
        // unreachable peers are pruned (a single connect burst finds only the
        // reachable subset of a mostly-NAT'd swarm).
        if (resp.peers.len > 0) {
            if (self.cached_peers.len > 0) self.allocator.free(self.cached_peers);
            self.cached_peers = self.allocator.dupe(tracker_mod.Peer, resp.peers) catch &.{};
        }
        self.connectToPeers(resp.peers) catch {};
        // Update peer_count immediately so the API snapshot reflects the new
        // peers without waiting for the next maintenance() cycle (critical for
        // Tor where the announce blocks the loop for 10-30s before it starts).
        self.peer_count.store(self.peers.items.len, .monotonic);
    }

    fn computeLeft(self: *Session) u64 {
        // Before metadata is known (magnet link), report non-zero so trackers
        // treat us as a leecher and return all peer types.
        if (self.metadata_only and self.num_pieces == 0) return 16384;
        var remaining: u64 = 0;
        for (0..self.num_pieces) |i| {
            if (!self.our_bitfield.hasPiece(@intCast(i))) {
                remaining += piece_mod.pieceLength(@intCast(i), self.piece_len, self.total_length);
            }
        }
        return remaining;
    }

    fn connectToPeers(self: *Session, peer_list: []const tracker_mod.Peer) !void {
        // Each proxied connection attempt takes ~10s through Tor (SOCKS
        // handshake + circuit). Trying all 50 peers serially would block
        // the session thread for minutes. Cap attempts per call; the
        // tracker re-announce cycle gradually fills the peer pool.
        // Clearnet connects are now non-blocking (startConnect returns on
        // EINPROGRESS), so attempting the whole tracker response is cheap —
        // the peer-pool cap (max_peers) bounds how many sockets we hold. Proxied
        // connects still block per attempt, so keep that cap small.
        const max_attempts: usize = if (self.proxy != null) 10 else 200;
        var attempts: usize = 0;

        // Rotate start offset so repeated announces don't always retry
        // the same failing peers at the front of the list.
        const offset = if (peer_list.len > 0)
            std.crypto.random.intRangeAtMost(usize, 0, peer_list.len - 1)
        else
            0;

        for (0..peer_list.len) |i| {
            const tracker_peer = peer_list[(i + offset) % peer_list.len];
            if (self.peers.items.len >= max_peers) break;
            if (attempts >= max_attempts) break;

            const addr = std.net.Address.initIp4(tracker_peer.ip, tracker_peer.port);
            var already = false;
            for (self.peers.items) |existing| {
                if (std.mem.eql(u8, &std.mem.toBytes(existing.address), &std.mem.toBytes(addr))) {
                    already = true;
                    break;
                }
            }
            if (already) continue;

            attempts += 1;

            const p = self.allocator.create(peer_mod.PeerConnection) catch continue;
            p.* = peer_mod.PeerConnection.init(self.allocator, addr);
            p.proxy = self.proxy;

            // Non-blocking for clearnet: startConnect issues connect() and
            // returns on EINPROGRESS, so a swarm full of dead peers can't stall
            // the single event-loop thread. The poll loop completes each connect
            // via finishConnect on POLLOUT. Proxied/I2P connects still block
            // here (synchronous handshake) but are capped by max_attempts.
            p.startConnect(self.info_hash, self.peer_id) catch {
                p.deinit();
                self.allocator.destroy(p);
                continue;
            };

            self.peers.append(self.allocator, p) catch {
                p.deinit();
                self.allocator.destroy(p);
                continue;
            };
        }
    }

    /// Connect directly to a peer address, bypassing the tracker.
    /// Useful for testing and for manual peer addition.
    pub fn connectDirectPeer(self: *Session, addr: std.net.Address) !void {
        if (self.peers.items.len >= max_peers) return;
        // On the I2P transport there is no clearnet route (and no proxy to tunnel
        // through), so a clearnet IPv4 peer is unreachable and dialing it would
        // leak the real IP — skip it. I2P peers arrive via connectI2pPeer.
        if (self.i2p != null) return;

        const p = self.allocator.create(peer_mod.PeerConnection) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(p);
        p.* = peer_mod.PeerConnection.init(self.allocator, addr);
        errdefer p.deinit();
        p.proxy = self.proxy;

        try self.finishPeerConnect(p);
    }

    /// Connect to a Tor hidden service (or other hostname) via the session proxy.
    pub fn connectOnionPeer(self: *Session, host: []const u8, port: u16) !void {
        if (self.peers.items.len >= max_peers) return;
        const px = self.proxy orelse return error.ConnectionFailed;

        const p = self.allocator.create(peer_mod.PeerConnection) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(p);
        p.* = try peer_mod.PeerConnection.initOnion(self.allocator, host, port);
        errdefer p.deinit();
        p.proxy = px;
        try self.finishPeerConnect(p);
    }

    /// True when this transfer must not touch the clearnet — a proxy/Tor proxy
    /// is set, or it's on the native I2P transport. All clearnet peer-discovery
    /// and seeding machinery (inbound listener, DHT, UDP/HTTP trackers, web
    /// seeds, direct dials) is disabled when this is true, so the real IP never
    /// leaks regardless of which anonymity network is selected.
    pub fn anonymized(self: *const Session) bool {
        return self.proxy != null or self.i2p != null;
    }

    /// Connect to an I2P peer by `.b32.i2p` destination over the session's SAM
    /// transport. `port` is the peer's advertised I2CP destination port (passed
    /// to SAM as `TO_PORT`; 0 = default). Requires the `i2p` route (a live SAM
    /// session).
    pub fn connectI2pPeer(self: *Session, dest: []const u8, port: u16) !void {
        if (self.peers.items.len >= max_peers) return;
        const sam = self.i2p orelse return error.ConnectionFailed;

        const p = self.allocator.create(peer_mod.PeerConnection) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(p);
        p.* = try peer_mod.PeerConnection.initI2p(self.allocator, dest, port, sam);
        errdefer p.deinit();
        try self.finishPeerConnect(p);
    }

    /// Connect, handshake, and adopt `p` into the peer set. Single-owner
    /// contract: on any error `p` is left untouched (NOT freed) so the caller's
    /// errdefer frees it exactly once; on success ownership transfers to
    /// `self.peers`. Previously this freed `p` on error *and* the caller's
    /// errdefer (in connectOnionPeer) freed it too — a double free that aborted
    /// the daemon when a Tor peer dial failed.
    fn finishPeerConnect(self: *Session, p: *peer_mod.PeerConnection) !void {
        p.connect() catch return error.ConnectionFailed;
        p.sendHandshake(self.info_hash, self.peer_id) catch return error.OutOfMemory;
        try self.peers.append(self.allocator, p);
    }

    /// Run a single iteration of the event loop (for testing).
    pub fn tick(self: *Session) !void {
        if (self.mode == .download and !self.metadata_only and self.num_pieces > 0 and self.our_bitfield.isComplete()) {
            self.running = false;
            return;
        }

        var fds: [max_peers + 1]std.posix.pollfd = undefined;
        const nfds = self.buildPollFds(&fds);
        _ = std.posix.poll(fds[0..nfds], 50) catch 0;
        self.processPollResults(fds[0..nfds]) catch {};
        self.scheduleRequests() catch {};
        // Run choking + cleanup (needed for unchoking peers in tests)
        self.runChokingAlgorithm();
        // Clean up disconnected peers
        var i: usize = 0;
        while (i < self.peers.items.len) {
            if (self.peers.items[i].state == .disconnected) {
                const p = self.peers.items[i];
                if (p.peer_bitfield) |*bf| self.removeAvailability(bf);
                p.deinit();
                self.allocator.destroy(p);
                _ = self.peers.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    // --- BEP 5: DHT peer discovery ---

    fn tryDhtPeerDiscovery(self: *Session) !void {
        // DHT runs over clearnet UDP, which can't be tunneled. Disable it on any
        // anonymized transport (proxy/Tor/I2P) to avoid leaking the real IP.
        if (self.anonymized()) return;

        if (self.dht_state == null) {
            const st = self.allocator.create(DhtState) catch {
                log.warn("DHT disabled: out of memory allocating lookup state", .{});
                return;
            };
            st.* = .{};
            self.dht_state = st;
        }
        const st = self.dht_state.?;

        // Don't retry if DHT previously failed to start (e.g. port busy);
        // only one lookup in flight at a time; back off after a failed walk.
        const now = std.time.timestamp();
        {
            st.mutex.lock();
            defer st.mutex.unlock();
            if (st.failed) return;
            if (st.query_active) return;
            if (now < st.retry_after) return;
            st.query_active = true;
        }

        // The previous worker has finished (query_active was clear) but may
        // not have returned from its last free yet — reap it so its allocator
        // use is ordered before anything that could tear the allocator down.
        self.joinDhtWorker();

        if (!self.dht_node_id_set) {
            std.crypto.random.bytes(&self.dht_node_id);
            self.dht_node_id_set = true;
        }

        // The worker holds its own reference to the shared state so the state
        // outlives an early session teardown; the thread itself is joined.
        st.ref();
        log.info("DHT lookup starting (background)...", .{});
        const thread = std.Thread.spawn(.{}, dhtQueryWorker, .{
            self.allocator, st, self.listen_port + 1, self.info_hash, self.dht_node_id,
        }) catch |err| {
            log.warn("DHT thread spawn failed: {t}", .{err});
            st.mutex.lock();
            st.query_active = false;
            st.mutex.unlock();
            st.unref(self.allocator);
            return;
        };
        self.dht_thread = thread;
    }

    /// Reap a finished lookup thread. Called before starting the next one and
    /// from `stopDhtWorker`; joining an already-exited thread is cheap.
    fn joinDhtWorker(self: *Session) void {
        const t = self.dht_thread orelse return;
        self.dht_thread = null;
        t.join();
    }

    /// Stop DHT work and make sure no worker is still running. The worker
    /// allocates and frees through the session allocator, and callers destroy
    /// that allocator right after the session, so leaving a detached lookup
    /// running past this point is a use-after-free of the allocator itself.
    /// The cancel flag keeps the wait to about one socket timeout instead of
    /// the walk's full budget.
    fn stopDhtWorker(self: *Session) void {
        if (self.dht_state) |st| st.cancel.store(true, .monotonic);
        self.joinDhtWorker();
    }

    /// DHT lookup worker: owns its Dht for the duration of the query so the
    /// session loop never touches DHT state. Detached — it outlives the
    /// session safely by holding a reference to the shared state and never
    /// touching the Session itself. Posts found peers + routing-table size
    /// for maintenance() to consume.
    fn dhtQueryWorker(allocator: Allocator, st: *DhtState, port: u16, info_hash: [20]u8, node_id: [20]u8) void {
        defer st.unref(allocator);
        defer {
            st.mutex.lock();
            st.query_active = false;
            st.mutex.unlock();
        }

        var d = dht_mod.Dht.initWithId(allocator, port, node_id);
        defer d.deinit();
        d.start() catch {
            log.warn("DHT failed to start", .{});
            st.mutex.lock();
            st.failed = true;
            st.mutex.unlock();
            return;
        };

        const peers = d.getPeers(allocator, info_hash, &st.cancel) catch {
            // Don't cold-bootstrap again on the very next maintenance tick.
            st.mutex.lock();
            st.retry_after = std.time.timestamp() + dht_retry_backoff_secs;
            st.mutex.unlock();
            return;
        };

        var node_count: u32 = 0;
        for (&d.buckets) |*b| node_count += @intCast(b.items.len);

        st.mutex.lock();
        defer st.mutex.unlock();
        if (st.peers.len > 0) allocator.free(st.peers);
        st.peers = peers;
        st.nodes = node_count;
    }

    // --- BEP 19: Web seed downloads ---

    fn tryWebSeedDownload(self: *Session) !void {
        // Web seeds use std.http.Client directly (clearnet); disable on any
        // anonymized transport (a tunneled, Range-aware path is a follow-up).
        if (self.anonymized()) return;

        const urls = self.meta.url_list orelse return;
        if (urls.len == 0) return;
        if (self.num_pieces == 0) return;

        // Find a piece we need
        for (0..self.num_pieces) |i| {
            const idx: u32 = @intCast(i);
            if (self.our_bitfield.hasPiece(idx)) continue;
            if (self.active_pieces.contains(idx)) continue;

            // Try each web seed URL
            for (urls) |base_url| {
                if (self.downloadWebSeedPiece(base_url, idx) catch false) {
                    return;
                } else {
                    continue; // Try next URL
                }
            }
            return; // Don't try more pieces if all URLs failed
        }
    }

    fn downloadWebSeedPiece(self: *Session, base_url: []const u8, piece_idx: u32) !bool {
        const plen = piece_mod.pieceLength(piece_idx, self.piece_len, self.total_length);
        if (plen == 0) return false;

        const start = @as(u64, piece_idx) * self.piece_len;
        const end = start + plen - 1;

        // Build URL -- for single-file torrents, url-list points directly to the file
        // Append the filename if the URL ends with /
        var url_buf: [4096]u8 = undefined;
        var url_len: usize = 0;
        if (base_url.len > url_buf.len) return false;
        @memcpy(url_buf[0..base_url.len], base_url);
        url_len = base_url.len;

        if (base_url.len > 0 and base_url[base_url.len - 1] == '/') {
            // Append filename
            if (url_len + self.meta.name.len > url_buf.len) return false;
            @memcpy(url_buf[url_len .. url_len + self.meta.name.len], self.meta.name);
            url_len += self.meta.name.len;
        }

        const url = url_buf[0..url_len];

        // Build Range header value
        var range_buf: [64]u8 = undefined;
        const range_str = std.fmt.bufPrint(&range_buf, "bytes={d}-{d}", .{ start, end }) catch return false;

        // HTTP request with Range header
        var client: std.http.Client = .{ .allocator = self.allocator };
        defer client.deinit();

        var response_body: std.ArrayList(u8) = .empty;
        defer response_body.deinit(self.allocator);

        var adapt_buf: [4096]u8 = undefined;
        const deprecated_writer = response_body.writer(self.allocator);
        var adapter = deprecated_writer.adaptToNewApi(&adapt_buf);

        const extra_headers = [_]std.http.Header{
            .{ .name = "Range", .value = range_str },
        };

        const result = client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &adapter.new_interface,
            .extra_headers = &extra_headers,
        }) catch return false;

        // 206 Partial Content or 200 OK
        if (result.status != .partial_content and result.status != .ok) return false;

        // Flush remaining buffered data from the adapter
        const buffered = adapter.new_interface.buffered();
        if (buffered.len > 0) {
            response_body.appendSlice(self.allocator, buffered) catch return false;
        }

        const data = response_body.items;
        if (data.len != plen) return false;

        // Verify SHA-1
        const hash = piece_mod.pieceHash(self.meta.pieces, piece_idx) orelse return false;
        if (!piece_mod.verifyPiece(data, hash)) return false;

        // Write to disk
        self.store.writePiece(piece_idx, data) catch return false;
        self.our_bitfield.setPiece(piece_idx);
        self.downloaded += plen;
        self.block_bytes_in += plen;
        self.have_pieces.store(self.our_bitfield.count(), .monotonic);

        self.printProgress() catch {};

        // Broadcast have to all peers
        for (self.peers.items) |p| {
            if (p.state == .active) {
                p.enqueueMessage(.{ .have = piece_idx }) catch {};
            }
        }

        log.info("web seed: piece {d}/{d} from {s}", .{ piece_idx + 1, self.num_pieces, url });
        return true;
    }

    fn printProgress(self: *Session) !void {
        // Only render the \r progress bar to an interactive terminal. When
        // stdout is piped to a log file or another process, the carriage-return
        // redraws are noise -- and a reader that doesn't promptly drain stdout
        // could fill the pipe and block our single-threaded event loop.
        const stdout_file = std.fs.File.stdout();
        if (!std.posix.isatty(stdout_file.handle)) return;

        const stdout = stdout_file.deprecatedWriter();
        const now = std.time.timestamp();
        const have = self.our_bitfield.count();
        const pct = if (self.num_pieces > 0) (have * 100) / self.num_pieces else 0;

        const dt = now - self.last_progress_time;
        const speed: u64 = if (dt > 0)
            (self.downloaded - self.last_progress_bytes) / @as(u64, @intCast(dt))
        else
            0;
        self.last_progress_time = now;
        self.last_progress_bytes = self.downloaded;

        const remaining_bytes = self.total_length - @min(self.downloaded, self.total_length);
        const eta_secs: u64 = if (speed > 0) remaining_bytes / speed else 0;

        const active_peers = blk: {
            var n: u32 = 0;
            for (self.peers.items) |p| {
                if (p.state == .active) n += 1;
            }
            break :blk n;
        };

        if (speed > 1024 * 1024) {
            stdout.print("\r[{d}/{d}] {d}%  {d}.{d} MB/s  ETA {d}m{d}s  peers:{d}   ", .{
                have,                  self.num_pieces,                              pct,
                speed / (1024 * 1024), (speed % (1024 * 1024)) * 10 / (1024 * 1024), eta_secs / 60,
                eta_secs % 60,         active_peers,
            }) catch {};
        } else if (speed > 1024) {
            stdout.print("\r[{d}/{d}] {d}%  {d} KB/s  ETA {d}m{d}s  peers:{d}   ", .{
                have,         self.num_pieces, pct,
                speed / 1024, eta_secs / 60,   eta_secs % 60,
                active_peers,
            }) catch {};
        } else {
            stdout.print("\r[{d}/{d}] {d}%  {d} B/s  ETA {d}m{d}s  peers:{d}   ", .{
                have, self.num_pieces, pct, speed, eta_secs / 60, eta_secs % 60, active_peers,
            }) catch {};
        }
    }
};

// ---- Per-peer snapshot helpers ----

fn peerFlags(buf: []u8, p: *peer_mod.PeerConnection) []const u8 {
    var len: usize = 0;
    if (p.am_interested) {
        buf[len] = if (!p.peer_choking) 'D' else 'd';
        len += 1;
    }
    if (p.peer_interested) {
        buf[len] = if (!p.am_choking) 'U' else 'u';
        len += 1;
    }
    if (p.supports_extensions) {
        buf[len] = 'E';
        len += 1;
    }
    return buf[0..len];
}

fn decodeClientName(buf: []u8, peer_id: ?[20]u8) []const u8 {
    const id = peer_id orelse return "unknown";
    if (id[0] == '-' and id[7] == '-') {
        const name = clientNameFromCode(id[1..3]);
        const v = id[3..7];
        return std.fmt.bufPrint(buf, "{s} {c}.{c}.{c}", .{ name, v[0], v[1], v[2] }) catch name;
    }
    return "unknown";
}

fn clientNameFromCode(code: []const u8) []const u8 {
    return if (std.mem.eql(u8, code, "TR")) "Transmission" else if (std.mem.eql(u8, code, "qB")) "qBittorrent" else if (std.mem.eql(u8, code, "UT") or std.mem.eql(u8, code, "UM")) "µTorrent" else if (std.mem.eql(u8, code, "DE")) "Deluge" else if (std.mem.eql(u8, code, "AZ")) "Azureus" else if (std.mem.eql(u8, code, "LT") or std.mem.eql(u8, code, "lt")) "libtorrent" else if (std.mem.eql(u8, code, "BT")) "BitTorrent" else if (std.mem.eql(u8, code, "CA")) "carl" else if (std.mem.eql(u8, code, "BC")) "BitComet" else if (std.mem.eql(u8, code, "FL")) "Folx" else if (std.mem.eql(u8, code, "SZ")) "Shareaza" else if (std.mem.eql(u8, code, "TL")) "Tribler" else if (std.mem.eql(u8, code, "XL") or std.mem.eql(u8, code, "XD")) "Xunlei" else "unknown";
}

/// Compute per-file completion percentage, weighted by byte overlap for
/// boundary pieces. Returns 100 for zero-length files (no pieces needed).
fn computeFilePct(
    bf: piece_mod.Bitfield,
    fstart: u64,
    flen: u64,
    piece_len: u64,
    num_pieces: u32,
) u8 {
    if (flen == 0) return 100;
    const first_p: u32 = @intCast(fstart / piece_len);
    const fend = fstart + flen;
    const last_p_raw = (fend - 1) / piece_len;
    const last_p: u32 = @intCast(@min(last_p_raw, @as(u64, num_pieces) -| 1));

    var have_bytes: u64 = 0;
    for (first_p..last_p + 1) |p_idx| {
        if (!bf.hasPiece(@intCast(p_idx))) continue;
        const piece_start = @as(u64, p_idx) * piece_len;
        const piece_end = piece_start + piece_len;
        const overlap_start = @max(piece_start, fstart);
        const overlap_end = @min(piece_end, fend);
        if (overlap_end > overlap_start) have_bytes += overlap_end - overlap_start;
    }
    return @intCast(@min(have_bytes * 100 / flen, 100));
}

test "sampleRate counts block bytes as progress before a piece verifies" {
    // Regression: on a slow link (single I2P peer) a piece can take far longer
    // than the stall threshold to complete. Blocks received mid-piece must
    // stamp `last_progress_s`, or the status flaps downloading <-> stalled.
    var s: Session = undefined;
    s.downloaded = 0; // no piece verified yet
    s.meta_bytes_in = 0;
    s.block_bytes_in = 0;
    s.uploaded = 0;
    s.rate_last_s = 100;
    s.rate_last_in = 0;
    s.rate_last_out = 0;
    s.down_rate = std.atomic.Value(u64).init(0);
    s.up_rate = std.atomic.Value(u64).init(0);
    s.last_progress_s = std.atomic.Value(i64).init(100);

    // Two 16 KiB blocks arrived off the wire; the piece is still incomplete.
    s.block_bytes_in = 32 * 1024;
    s.sampleRate(104);

    try std.testing.expectEqual(@as(i64, 104), s.last_progress_s.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 32 * 1024 / 4 / 4), s.down_rate.load(.monotonic));

    // No new bytes: the progress stamp must not advance.
    s.sampleRate(110);
    try std.testing.expectEqual(@as(i64, 104), s.last_progress_s.load(.monotonic));
}

/// Re-encode a resolved Metainfo into full `.torrent` bytes: a top-level dict
/// `{ "announce", "info" }`. The info dict is decoded from `raw_info` and
/// re-encoded canonically, so the info-hash is preserved. Caller owns the result.
/// Public so the manager can checkpoint created seeds into the seeds shelf.
pub fn buildTorrentBytes(a: Allocator, meta: metainfo.Metainfo) ![]u8 {
    const info_val = try bencode.decode(a, meta.raw_info);
    defer info_val.deinit(a);
    const entries = [_]bencode.Value.DictEntry{
        .{ .key = "announce", .value = .{ .string = meta.announce } },
        .{ .key = "info", .value = info_val },
    };
    return bencode.encode(a, .{ .dict = &entries });
}
