//! TorrentManager: a long-lived owner of many concurrent `Session`s, the piece
//! the daemon hangs off of.
//!
//! `Session` is single-threaded with a blocking `run()` loop, so each transfer
//! runs on its own OS thread. The manager itself only touches the list of
//! transfers (under a mutex); snapshots read each session's *race-safe* state —
//! scalar counters and the fixed-size `our_bitfield` (allocated once, never
//! reallocated). It deliberately does NOT iterate a session's live `peers`
//! ArrayList or `active_pieces` map across threads: those are mutated by the
//! session thread and reading them concurrently is unsound. Exposing full
//! per-peer rows requires the session to publish a locked snapshot — tracked as
//! a follow-up; see docs/daemon-api.md.
//!
//! Scope of this first cut: the download path (magnet / .torrent / HTTP URL),
//! routed direct or through a SOCKS proxy (proxy/tor). Creating a torrent from
//! a local file ("Seed a file") and Tor hidden-service generation are follow-up
//! work; `seeds()` therefore reflects transfers that are currently seeding.

const std = @import("std");
const Allocator = std.mem.Allocator;

const session_mod = @import("session.zig");
const metainfo = @import("metainfo.zig");
const magnet_mod = @import("magnet.zig");
const proxy_mod = @import("proxy.zig");
const i2p_sam = @import("i2p_sam.zig");
const i2p_seed = @import("i2p_seed.zig");
const extension = @import("extension.zig");
const relay_mod = @import("relay.zig");
const nip35 = @import("nip35.zig");
const peer_announce = @import("peer_announce.zig");
const seeding = @import("seeding.zig");
const tor_control = @import("tor_control.zig");
const state_mod = @import("state.zig");
const workdir = @import("workdir.zig");
const follow_mod = @import("follow.zig");
const drive_mod = @import("drive.zig");
const nostr_config = @import("nostr_config.zig");
const nostr_mod = @import("nostr.zig");
const secp = @import("secp.zig");
const nip19 = @import("nip19.zig");
const api = @import("api.zig");

const log = std.log.scoped(.manager);

pub const Error = error{
    InvalidMagnet,
    InvalidTorrent,
    HttpFailed,
    BadProxy,
    SessionInitFailed,
    /// The requested operation has no I2P-routed implementation yet, so doing it
    /// would either leak over clearnet or produce an unreachable transfer. We
    /// fail closed rather than silently fall back. Covers HTTP `.torrent`
    /// fetches and seeding on the `i2p` route (see #35 P2/P3 follow-ups).
    UnsupportedOnI2p,
    /// Failed to stand up the Tor hidden service for a `.tor` seed (Tor
    /// ControlPort unreachable, cookie auth failed, etc.). Fails closed rather
    /// than creating a seed nobody can reach.
    TorControlFailed,
    NotFound,
    /// A follow request was invalid: a malformed pubkey, an unsupported route
    /// (follows run on `direct` or `i2p`), or the publisher is already followed.
    InvalidFollow,
    /// A drive request was invalid: a bad role, an empty dir/name, a
    /// subscriber without a valid author npub/hex (or an invalid `also`
    /// writer), an unsupported route (drives run on `direct` or `i2p`), a
    /// publisher with no local Nostr identity, or the same drive (role,
    /// author, name, dir) is already running.
    InvalidDrive,
} || Allocator.Error;

/// Daemon-level configuration mirrored to the Settings screen. String fields
/// are owned; setters free and re-dup.
pub const Config = struct {
    route: api.Route = .direct,
    /// True when `route` came from an explicit `--route` flag. `restore` then
    /// keeps it instead of applying the persisted (GUI-set) route: silently
    /// downgrading e.g. `--route i2p`/`tor` to a stale persisted `direct` would
    /// put a daemon the user asked to anonymize on the clearnet.
    route_explicit: bool = false,
    socks: []const u8 = "",
    /// I2P SAM bridge address for the `i2p` route (e.g. `127.0.0.1:7656`).
    i2p_sam: []const u8 = "",
    download_dir: []const u8 = "",
    /// True when `download_dir` came from a source that outranks the persisted
    /// setting (an explicit --download-dir flag or $CARL_DIR), so `restore`
    /// must not replace it with the stale DB value — otherwise the daemon and
    /// the CLI (which honors $CARL_DIR first) would diverge on the work dir.
    download_dir_pinned: bool = false,
    listen_port: u16 = 6881,
    /// False turns `persist` into a no-op. Tests set this: a Manager built
    /// with config defaults otherwise writes the *real* `<config>/carl.db`
    /// (route + download dir + an empty transfer list) on any state change,
    /// silently wiping the running daemon's saved transfers — which is how
    /// `zig build test` on a developer machine destroyed live GUI state.
    persist: bool = true,
    max_active: u32 = 8,
    peer_limit: u32 = 60,
    publish_nip35: bool = true,
    /// Tor ControlPort `host:port` for creating hidden services when seeding on
    /// the `tor` route (so a UI-created Tor seed is reachable). Default 9051.
    tor_control: []const u8 = "",
    /// Path to the Tor control cookie; empty = default (`~/.tor/control_auth_cookie`).
    tor_cookie: []const u8 = "",
    /// Virtual port exposed on the seed's `.onion`.
    tor_onion_port: u16 = 80,
};

/// One running transfer: its session, the thread driving it, and the metadata
/// the manager owns for the session's lifetime.
const ManagedTransfer = struct {
    allocator: Allocator,
    id: []u8,
    name: []u8,
    magnet: []u8,
    /// Owned recipe to re-create this transfer on restart: the original source
    /// (magnet/url/.torrent path for a download, file path for a seed).
    source: []u8,
    hash_hex: [40]u8,
    info_hash: [20]u8,
    route: api.Route,
    want_nostr: bool,
    /// True for torrents we created and seed (vs. ones we download).
    is_seed: bool,
    /// Tracker availability captured at add time (from the initial metainfo), so
    /// snapshots needn't read the session's `meta` across threads — which the
    /// magnet path replaces on metadata completion.
    has_tracker: bool,
    /// Owned copy of the socks URL the proxy slices borrow from.
    socks_owned: ?[]u8,
    proxy: ?proxy_mod.Proxy,
    /// Owned SAM session for the `i2p` route (the session borrows it). Torn down
    /// in `destroy` after the session thread has stopped.
    i2p_session: ?*i2p_sam.Session,
    /// Tor hidden service backing a `.tor` seed (the onion leechers dial).
    /// Owned; torn down (DEL_ONION) in `destroy` after the session stops.
    hidden: ?tor_control.HiddenService,
    /// `.b32.i2p` address of an I2P seed (what we publish + dial). Owned; freed
    /// in `destroy`. Null for non-i2p transfers and i2p downloads.
    i2p_host: ?[]u8,
    session: *session_mod.Session,
    meta: metainfo.Metainfo,
    thread: ?std.Thread,
    added_ms: i64,

    /// True once a resolved magnet's .torrent has been written and `source`
    /// repointed at it, so the checkpoint doesn't redo it.
    resolved: bool = false,

    fn stop(self: *ManagedTransfer) void {
        // Signal the session loop to exit; it re-checks `running` every poll
        // tick (~1s). Joining waits for the final stopped-announce.
        self.session.running = false;
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn destroy(self: *ManagedTransfer) void {
        // Order matters: stop+join the thread, deinit the session, THEN free the
        // metadata the session borrowed (the magnet path frees its own replaced
        // copy; the original placeholder is ours).
        self.stop();
        self.session.deinit();
        self.allocator.destroy(self.session);
        // Tear down the onion after the session (and its loopback listener) is
        // gone, so we DEL_ONION only once nothing is forwarding to it.
        if (self.hidden) |*h| h.deinit();
        self.meta.deinit(self.allocator);
        // The session (now stopped) borrowed this SAM session; tear it down last
        // (closing it also cancels the inbound STREAM FORWARD for an i2p seed).
        if (self.i2p_session) |s| {
            s.deinit();
            self.allocator.destroy(s);
        }
        if (self.i2p_host) |h| self.allocator.free(h);
        if (self.socks_owned) |s| self.allocator.free(s);
        self.allocator.free(self.id);
        self.allocator.free(self.name);
        self.allocator.free(self.magnet);
        self.allocator.free(self.source);
        self.allocator.destroy(self);
    }
};

/// One followed publisher: the embedded mirror worker plus the metadata the
/// daemon needs to list and persist it.
const FollowHandle = struct {
    allocator: Allocator,
    id: []u8,
    pubkey: [32]u8,
    pk_hex: [64]u8,
    npub: []u8,
    route: api.Route,
    dir: []u8,
    mirror: *follow_mod.Mirror,

    /// Stop the mirror (joins its threads — can block on in-flight relay
    /// queries) and free everything. Call without holding the manager mutex.
    fn destroy(self: *FollowHandle) void {
        self.mirror.destroy();
        self.allocator.free(self.id);
        self.allocator.free(self.npub);
        self.allocator.free(self.dir);
        self.allocator.destroy(self);
    }
};

/// One shared drive: the drive worker plus the metadata the daemon needs to
/// list and persist it.
const DriveHandle = struct {
    allocator: Allocator,
    id: []u8,
    role: drive_mod.Role,
    dir: []u8,
    name: []u8,
    /// Subscriber: the followed author's pubkey; null for a publisher.
    author: ?[32]u8,
    /// Extra writer pubkeys (multi-writer subscriptions); owned slice.
    also: []const [32]u8,
    route: api.Route,
    drive: *drive_mod.Drive,

    /// Stop the drive (joins its loop thread — can block on in-flight relay
    /// queries) and free everything. Call without holding the manager mutex.
    fn destroy(self: *DriveHandle) void {
        self.drive.destroy();
        self.allocator.free(self.id);
        self.allocator.free(self.dir);
        self.allocator.free(self.name);
        self.allocator.free(self.also);
        self.allocator.destroy(self);
    }
};

pub const Manager = struct {
    allocator: Allocator,
    mutex: std.Thread.Mutex = .{},
    transfers: std.ArrayList(*ManagedTransfer) = .empty,
    next_id: usize = 1,
    /// Followed publishers (mirror workers). Guarded by `mutex` like
    /// `transfers`; handles are destroyed outside the lock (joins threads).
    follows: std.ArrayList(*FollowHandle) = .empty,
    next_follow_id: usize = 1,
    /// Shared drives (drive workers). Guarded by `mutex` like `follows`;
    /// handles are destroyed outside the lock (joins the drive loop thread).
    drives: std.ArrayList(*DriveHandle) = .empty,
    next_drive_id: usize = 1,
    cfg: Config,
    /// While replaying persisted state on startup, suppress per-add persistence
    /// (we write once at the end of `restore`).
    /// True while `restoreTransfers` is replaying persisted state. Atomic because
    /// restore now runs on a background thread (so the daemon serves while it
    /// replays slow anonymized re-adds) and `persist` reads it from the serving
    /// threads. `persist` no-ops while set, so each re-add doesn't rewrite the DB
    /// — restore writes it once at the end.
    restoring: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// The user's persisted downloadDir, kept aside while a pinned override
    /// ($CARL_DIR / --download-dir) is active: `persist` re-saves this instead
    /// of the override, so an ephemeral override never clobbers the setting on
    /// disk. Cleared when the user picks a new dir via `setDownloadDir`. Owned.
    saved_download_dir: ?[]u8 = null,
    /// Persisted transfer specs that failed to re-add on `restore` (the SAM
    /// bridge / I2P router or Tor still starting, a proxy down, a seed file on
    /// a not-yet-mounted disk). They aren't live (no session), but `persist`
    /// re-includes them so a failure at startup never deletes a user's saved
    /// transfers — the next restart retries them. Sources are owned by
    /// `allocator`.
    retained_specs: std.ArrayList(state_mod.TransferSpec) = .empty,

    pub fn init(allocator: Allocator, cfg: Config) Allocator.Error!Manager {
        return .{
            .allocator = allocator,
            .cfg = .{
                .route = cfg.route,
                .route_explicit = cfg.route_explicit,
                .socks = try allocator.dupe(u8, if (cfg.socks.len > 0) cfg.socks else "socks5h://127.0.0.1:9050"),
                .i2p_sam = try allocator.dupe(u8, if (cfg.i2p_sam.len > 0) cfg.i2p_sam else "127.0.0.1:7656"),
                .download_dir = try allocator.dupe(u8, if (cfg.download_dir.len > 0) cfg.download_dir else "."),
                .download_dir_pinned = cfg.download_dir_pinned,
                .listen_port = cfg.listen_port,
                .persist = cfg.persist,
                .max_active = cfg.max_active,
                .peer_limit = cfg.peer_limit,
                .publish_nip35 = cfg.publish_nip35,
                .tor_control = try allocator.dupe(u8, if (cfg.tor_control.len > 0) cfg.tor_control else "127.0.0.1:9051"),
                .tor_cookie = try allocator.dupe(u8, cfg.tor_cookie),
                .tor_onion_port = if (cfg.tor_onion_port > 0) cfg.tor_onion_port else 80,
            },
        };
    }

    pub fn deinit(self: *Manager) void {
        // No lock: deinit happens after the server loop has stopped.
        for (self.follows.items) |f| f.destroy();
        self.follows.deinit(self.allocator);
        for (self.drives.items) |d| d.destroy();
        self.drives.deinit(self.allocator);
        for (self.transfers.items) |mt| mt.destroy();
        self.transfers.deinit(self.allocator);
        for (self.retained_specs.items) |s| self.allocator.free(s.source);
        self.retained_specs.deinit(self.allocator);
        self.allocator.free(self.cfg.socks);
        self.allocator.free(self.cfg.i2p_sam);
        self.allocator.free(self.cfg.download_dir);
        if (self.saved_download_dir) |d| self.allocator.free(d);
        self.allocator.free(self.cfg.tor_control);
        self.allocator.free(self.cfg.tor_cookie);
    }

    // -----------------------------------------------------------------------
    // Mutations
    // -----------------------------------------------------------------------

    /// Add a transfer from a magnet URI, .torrent path, or HTTP(S) URL on the
    /// given route. Spawns the session thread. Returns the new transfer id
    /// (owned by the caller).
    /// Open a SAM session for the `i2p` route (the per-transfer transport,
    /// analogous to resolving a proxy). Caller owns the returned session.
    fn resolveI2p(self: *Manager) Error!*i2p_sam.Session {
        const bridge = i2p_sam.parseUrl(self.cfg.i2p_sam) catch return error.BadProxy;
        const sam = self.allocator.create(i2p_sam.Session) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(sam);
        sam.* = i2p_sam.Session.create(self.allocator, bridge, "carl") catch return error.SessionInitFailed;
        return sam;
    }

    /// The per-transfer transport resolved from a route: a proxy (with its owned
    /// socks URL) for proxy/Tor, a SAM session for I2P, or nothing for direct.
    const Transport = struct {
        socks_owned: ?[]u8 = null,
        proxy: ?proxy_mod.Proxy = null,
        i2p: ?*i2p_sam.Session = null,
    };

    /// Resolve the transport for `route`. Each transfer owns its transport so a
    /// later config change can't dangle a running one. On error nothing leaks.
    fn resolveTransport(self: *Manager, route: api.Route) Error!Transport {
        if (route == .i2p) return .{ .i2p = try self.resolveI2p() };
        if (route == .direct) return .{};
        const dup = try self.allocator.dupe(u8, self.cfg.socks);
        const proxy = proxy_mod.parseUrl(dup) catch {
            self.allocator.free(dup);
            return error.BadProxy;
        };
        return .{ .socks_owned = dup, .proxy = proxy };
    }

    /// Free a resolved transport on a pre-`register` error path (after `register`
    /// succeeds, the ManagedTransfer owns it). Idempotent over the null fields.
    fn freeTransport(self: *Manager, t: Transport) void {
        if (t.socks_owned) |s| self.allocator.free(s);
        if (t.i2p) |s| {
            s.deinit();
            self.allocator.destroy(s);
        }
    }

    pub fn addTransfer(self: *Manager, source: []const u8, route: api.Route, want_nostr: bool) Error![]u8 {
        const t = try self.resolveTransport(route);

        std.fs.cwd().makePath(self.cfg.download_dir) catch {};

        const built = self.buildSession(source, t.proxy, t.i2p) catch |err| {
            self.freeTransport(t);
            return err;
        };
        const magnet = if (std.mem.startsWith(u8, source, "magnet:")) source else "";
        // Pin a local `.torrent` source onto the seeds shelf: the picked file
        // can live anywhere (a file-picker temp path, a folder the user later
        // cleans), and the restart replay would silently fail once it's gone.
        // Persist the recipe as `<download_dir>/seeds/<infohash>.torrent`
        // instead. Best-effort: on any failure the original source is kept.
        var pinned: ?[]u8 = null;
        defer if (pinned) |p| self.allocator.free(p);
        if (magnet.len == 0 and
            !std.mem.startsWith(u8, source, "http://") and
            !std.mem.startsWith(u8, source, "https://"))
        {
            pinned = self.pinTorrentSource(source, built.info_hash);
        }
        return self.register(built, route, t.proxy, t.socks_owned, t.i2p, null, null, want_nostr, false, magnet, pinned orelse source);
    }

    /// Ensure the seeds shelf (`<dir>/seeds`) exists and return its path, or
    /// null when it can't be created. Caller owns the slice.
    fn ensureSeedsDir(self: *Manager, dir: []const u8) ?[]u8 {
        const sdir = workdir.seedsDir(self.allocator, dir) catch return null;
        std.fs.cwd().makePath(sdir) catch {
            self.allocator.free(sdir);
            return null;
        };
        return sdir;
    }

    /// Copy a local `.torrent` recipe onto the seeds shelf, named by
    /// info-hash. Returns the owned shelf path, or null when the copy isn't
    /// possible (the original path is then persisted unchanged). A source that
    /// already is the shelf file — a restart replaying the persisted spec —
    /// is returned as-is without rewriting it onto itself.
    fn pinTorrentSource(self: *Manager, source: []const u8, info_hash: [20]u8) ?[]u8 {
        var hex: [40]u8 = undefined;
        secp.toHex(&info_hash, &hex);
        const sdir = self.ensureSeedsDir(self.cfg.download_dir) orelse return null;
        defer self.allocator.free(sdir);
        const dest = std.fmt.allocPrint(self.allocator, "{s}/{s}.torrent", .{ sdir, &hex }) catch return null;
        if (std.mem.eql(u8, dest, source)) return dest;

        const data = std.fs.cwd().readFileAlloc(self.allocator, source, 10 * 1024 * 1024) catch {
            self.allocator.free(dest);
            return null;
        };
        defer self.allocator.free(data);
        var f = std.fs.cwd().createFile(dest, .{ .truncate = true }) catch {
            self.allocator.free(dest);
            return null;
        };
        defer f.close();
        f.writeAll(data) catch {
            self.allocator.free(dest);
            return null;
        };
        return dest;
    }

    /// Bind a throwaway loopback socket to discover a free port. Each `.tor`
    /// seed needs its own listener port: every seed otherwise reuses
    /// `cfg.listen_port`, but only one Session can bind a given port, so a second
    /// concurrent tor seed would silently fail to listen and be unreachable
    /// behind its onion. There's a tiny TOCTOU window before the Session
    /// re-binds; on the rare loss the Session's listener is null and `addSeed`
    /// warns. Returns null if even the probe bind fails (caller falls back).
    fn pickLoopbackPort(self: *Manager) ?u16 {
        _ = self;
        var server = (std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0).listen(.{ .reuse_address = true })) catch return null;
        defer server.deinit();
        return server.listen_address.getPort();
    }

    /// Create a torrent from a local file (or archive) and start seeding it. The
    /// file is hashed in-process — carl needs no external torrent tool. With
    /// `want_nostr`, a NIP-35 torrent event is published so it's discoverable.
    /// Open a SAM session for an I2P **seed**, reusing a persisted destination so
    /// the seed keeps its `.b32.i2p` address across restarts (a fresh transient
    /// one each time would invalidate every published peer-announce). On a first
    /// run the transient key the router returns is persisted for next time.
    /// Caller owns the returned session.
    fn resolveI2pSeed(self: *Manager, info_hash_hex: []const u8) Error!*i2p_sam.Session {
        const bridge = i2p_sam.parseUrl(self.cfg.i2p_sam) catch return error.BadProxy;
        const sam = self.allocator.create(i2p_sam.Session) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(sam);

        const persisted = i2p_seed.load(self.allocator, info_hash_hex) catch null;
        defer if (persisted) |p| self.allocator.free(p);
        const dest: i2p_sam.Session.Dest = if (persisted) |p| .{ .priv = p } else .transient;

        sam.* = i2p_sam.Session.createWithDest(self.allocator, bridge, "carl-seed", dest) catch
            return error.SessionInitFailed;
        // First run (no persisted key): the SESSION CREATE reply carries the full
        // private key — save it so the address is stable next time.
        if (persisted == null) i2p_seed.save(self.allocator, info_hash_hex, sam.destination);
        return sam;
    }

    /// Create a torrent from a local file (or archive) and start seeding it. The
    /// file is hashed in-process — carl needs no external torrent tool. With
    /// `want_nostr`, a NIP-35 torrent event is published so it's discoverable.
    pub fn addSeed(self: *Manager, path: []const u8, route: api.Route, want_nostr: bool) Error![]u8 {
        // Non-i2p transport resolves up front. The i2p route resolves its SAM
        // session below, after the info-hash is known (its persisted seed
        // destination is keyed by info-hash). One consolidated errdefer frees
        // whatever's been built so far; it's disarmed (`committed = true`) right
        // before `register`, which then owns cleanup on its own error path.
        var t: Transport = if (route == .i2p) .{} else try self.resolveTransport(route);
        var mi_opt: ?metainfo.Metainfo = null;
        var session_opt: ?*session_mod.Session = null;
        var hidden: ?tor_control.HiddenService = null;
        var i2p_host: ?[]u8 = null;
        var committed = false;
        errdefer if (!committed) {
            // Order mirrors ManagedTransfer.destroy: session (stops borrowing
            // the SAM session) before the transport frees it.
            if (session_opt) |s| {
                s.deinit();
                self.allocator.destroy(s);
            }
            if (mi_opt) |m| m.deinit(self.allocator);
            if (hidden) |*h| h.deinit();
            if (i2p_host) |h| self.allocator.free(h);
            self.freeTransport(t);
        };

        const mi = metainfo.createSingleFile(self.allocator, path, metainfo.default_piece_length) catch |e| {
            return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidTorrent,
            };
        };
        mi_opt = mi;
        // Seed from the file's own directory so storage resolves it by name.
        const data_dir = std.fs.path.dirname(path) orelse ".";

        var hex: [40]u8 = undefined;
        secp.toHex(&metainfo.infoHash(mi.raw_info), &hex);

        // Checkpoint the created torrent onto the seeds shelf
        // (`<download_dir>/seeds/<infohash>.torrent`): a stable artifact other
        // tooling (e.g. the `carl follow` mirror flow) can pick up, independent
        // of where the data file lives. Best-effort — the seed itself restores
        // by re-hashing its data file at the persisted path.
        self.writeSeedTorrent(&hex, mi);

        // Per-route seed wiring. Tor stands up a v3 hidden service; I2P opens a
        // SAM session with a stable destination and (after the listener is up)
        // registers an inbound STREAM FORWARD. Both run the session as a loopback
        // seed with clearnet discovery suppressed — the anonymity network is the
        // public face.
        var session_proxy = t.proxy;
        var listen_bind: session_mod.ListenBind = .any;
        var tor_hidden = false;
        var i2p_hidden = false;
        var seed_port = self.cfg.listen_port;
        switch (route) {
            .tor => {
                // Give each tor seed its own loopback port so concurrent tor
                // seeds don't collide on cfg.listen_port. The onion forwards here.
                seed_port = self.pickLoopbackPort() orelse self.cfg.listen_port;
                hidden = tor_control.addOnion(self.allocator, .{
                    .control_addr = self.cfg.tor_control,
                    .cookie_path = if (self.cfg.tor_cookie.len > 0) self.cfg.tor_cookie else null,
                    .local_port = seed_port,
                    .onion_port = self.cfg.tor_onion_port,
                }) catch return error.TorControlFailed;
                session_proxy = null;
                listen_bind = .loopback;
                tor_hidden = true;
            },
            .i2p => {
                // Own loopback port per seed; the SAM forward delivers inbound
                // peer streams here.
                seed_port = self.pickLoopbackPort() orelse self.cfg.listen_port;
                t.i2p = try self.resolveI2pSeed(&hex);
                i2p_host = i2p_sam.b32Address(self.allocator, t.i2p.?.destination) catch
                    return error.SessionInitFailed;
                listen_bind = .loopback;
                i2p_hidden = true;
            },
            else => {},
        }

        const session = self.allocator.create(session_mod.Session) catch return error.OutOfMemory;
        session.* = session_mod.Session.init(self.allocator, mi, data_dir, .seed, seed_port, session_proxy, listen_bind, tor_hidden, t.i2p, i2p_hidden) catch {
            self.allocator.destroy(session);
            return error.SessionInitFailed;
        };
        session_opt = session; // now initialized; the errdefer will tear it down
        // A hidden-service / forwarded seed whose loopback listener didn't bind
        // is unreachable behind its address — surface it rather than half-seed.
        if ((route == .tor or route == .i2p) and session.listener == null) {
            log.warn("{s} seed: listener failed to bind 127.0.0.1:{d}; the address will be unreachable", .{ @tagName(route), seed_port });
        }
        // I2P: register inbound forwarding now that the listener exists. Fail
        // closed — a seed that can't accept inbound streams is a dead address.
        if (route == .i2p) {
            t.i2p.?.forward(seed_port) catch {
                log.warn("i2p seed: STREAM FORWARD to 127.0.0.1:{d} failed; the .b32.i2p address would be unreachable", .{seed_port});
                return error.SessionInitFailed;
            };
            log.info("i2p seed: forwarding {s} -> 127.0.0.1:{d}", .{ i2p_host.?, seed_port });
        }
        const built = Built{ .session = session, .meta = mi, .info_hash = session.info_hash, .name = mi.name };

        const magnet = std.fmt.allocPrint(self.allocator, "magnet:?xt=urn:btih:{s}&dn={s}", .{ hex, mi.name }) catch
            return error.OutOfMemory;
        defer self.allocator.free(magnet);

        committed = true; // register owns cleanup-on-error from here
        return self.register(built, route, t.proxy, t.socks_owned, t.i2p, hidden, i2p_host, want_nostr, true, magnet, path);
    }

    /// Register a built session as a managed transfer and spawn its thread.
    /// Shared by addTransfer (download) and addSeed (seed). On success takes
    /// ownership of `built.session`, `built.meta`, and `socks_owned`; on any
    /// error it frees them (the `mt_owned` flag gates that handoff so we never
    /// double-free once `mt` owns everything).
    fn register(
        self: *Manager,
        built: Built,
        route: api.Route,
        resolved_proxy: ?proxy_mod.Proxy,
        socks_owned: ?[]u8,
        i2p_session: ?*i2p_sam.Session,
        hidden: ?tor_control.HiddenService,
        i2p_host: ?[]u8,
        want_nostr: bool,
        is_seed: bool,
        magnet_src: []const u8,
        source_src: []const u8,
    ) Error![]u8 {
        var mt_owned = false;
        errdefer if (!mt_owned) {
            built.session.deinit();
            self.allocator.destroy(built.session);
            if (hidden) |h| {
                var hh = h;
                hh.deinit();
            }
            built.meta.deinit(self.allocator);
            if (socks_owned) |s| self.allocator.free(s);
            if (i2p_session) |s| {
                s.deinit();
                self.allocator.destroy(s);
            }
            if (i2p_host) |h| self.allocator.free(h);
        };

        const mt = try self.allocator.create(ManagedTransfer);
        errdefer if (!mt_owned) self.allocator.destroy(mt);

        self.mutex.lock();
        const id_num = self.next_id;
        self.next_id += 1;
        self.mutex.unlock();

        const id = try std.fmt.allocPrint(self.allocator, "t{d}", .{id_num});
        errdefer if (!mt_owned) self.allocator.free(id);
        const name = try self.allocator.dupe(u8, built.name);
        errdefer if (!mt_owned) self.allocator.free(name);
        const magnet = try self.allocator.dupe(u8, magnet_src);
        errdefer if (!mt_owned) self.allocator.free(magnet);
        const source = try self.allocator.dupe(u8, source_src);
        errdefer if (!mt_owned) self.allocator.free(source);

        mt.* = .{
            .allocator = self.allocator,
            .id = id,
            .name = name,
            .magnet = magnet,
            .source = source,
            .hash_hex = undefined,
            .info_hash = built.info_hash,
            .route = route,
            .want_nostr = want_nostr,
            .is_seed = is_seed,
            .has_tracker = built.meta.announce.len > 0 or built.meta.announce_list != null,
            .socks_owned = socks_owned,
            .proxy = resolved_proxy,
            .i2p_session = i2p_session,
            .i2p_host = i2p_host,
            .hidden = hidden,
            .session = built.session,
            .meta = built.meta,
            .thread = null,
            .added_ms = std.time.milliTimestamp(),
        };
        secp.toHex(&built.info_hash, &mt.hash_hex);
        mt_owned = true; // mt now owns session, meta, socks, id, name, magnet

        self.mutex.lock();
        self.transfers.append(self.allocator, mt) catch |err| {
            self.mutex.unlock();
            mt.destroy();
            return err;
        };
        // Spawn after publishing so a snapshot taken mid-spawn sees the row.
        // (spawn doesn't block on the child, and we never join under the lock,
        // so holding the mutex across it is safe.)
        mt.thread = std.Thread.spawn(.{}, runThread, .{mt}) catch {
            // Roll back: remove from the list and destroy (frees `id` too, so we
            // must not touch it afterward on this path).
            self.mutex.unlock();
            _ = self.removeTransfer(id) catch {};
            return error.SessionInitFailed;
        };

        // The spec is live for real (spawn succeeded): drop any retained copy of
        // the same source so `persist` doesn't write it twice (a duplicate would
        // re-add the transfer twice on the next restart — two sessions on the
        // same files). Only after the spawn: dropping earlier would let the
        // failed-spawn rollback persist state with the saved spec already gone.
        self.dropRetained(source_src);
        self.mutex.unlock();

        self.persist();
        return self.allocator.dupe(u8, id);
    }

    /// Stop and remove the transfer with `id`. Returns true if found.
    pub fn removeTransfer(self: *Manager, id: []const u8) Error!bool {
        self.mutex.lock();
        var found: ?*ManagedTransfer = null;
        var idx: usize = 0;
        for (self.transfers.items, 0..) |mt, i| {
            if (std.mem.eql(u8, mt.id, id)) {
                found = mt;
                idx = i;
                break;
            }
        }
        if (found) |_| _ = self.transfers.orderedRemove(idx);
        self.mutex.unlock();

        if (found) |mt| {
            mt.destroy(); // joins the thread outside the lock
            self.persist();
            return true;
        }
        return false;
    }

    // -----------------------------------------------------------------------
    // Follows (mirror a Nostr publisher)
    // -----------------------------------------------------------------------

    /// Follow a publisher: spawn a mirror worker that downloads + reseeds
    /// everything `pubkey_str` (npub or 64-char hex) announces via NIP-35.
    /// Follows run on `direct` or `i2p`. Returns the new follow id (owned by
    /// the caller).
    pub fn addFollow(self: *Manager, pubkey_str: []const u8, route: api.Route) Error![]u8 {
        const pubkey = follow_mod.parsePubkeyArg(pubkey_str) catch return error.InvalidFollow;
        if (route != .direct and route != .i2p) return error.InvalidFollow;

        var pk_hex: [64]u8 = undefined;
        secp.toHex(&pubkey, &pk_hex);

        self.mutex.lock();
        for (self.follows.items) |f| {
            if (std.mem.eql(u8, &f.pubkey, &pubkey)) {
                self.mutex.unlock();
                return error.InvalidFollow; // already following
            }
        }
        const id_num = self.next_follow_id;
        self.next_follow_id += 1;
        // Mirror data lives beside regular downloads, namespaced by publisher.
        const dir = std.fmt.allocPrint(self.allocator, "{s}/follow-{s}", .{ self.cfg.download_dir, pk_hex[0..12] }) catch {
            self.mutex.unlock();
            return error.OutOfMemory;
        };
        const sam = self.allocator.dupe(u8, self.cfg.i2p_sam) catch {
            self.mutex.unlock();
            self.allocator.free(dir);
            return error.OutOfMemory;
        };
        self.mutex.unlock();
        defer self.allocator.free(sam);

        // Once the handle owns these, its `destroy` frees them; the errdefers
        // below are disarmed so a later failure can't double-free.
        var handle_owned = false;
        errdefer if (!handle_owned) self.allocator.free(dir);

        const id = std.fmt.allocPrint(self.allocator, "f{d}", .{id_num}) catch return error.OutOfMemory;
        errdefer if (!handle_owned) self.allocator.free(id);
        const npub = nip19.encode32(self.allocator, .npub, pubkey) catch return error.OutOfMemory;
        errdefer if (!handle_owned) self.allocator.free(npub);

        const mirror = follow_mod.Mirror.create(self.allocator, .{
            .pubkey = pubkey,
            .route = route,
            .dir = dir,
            .i2p_sam = sam,
        }) catch return error.OutOfMemory;
        errdefer if (!handle_owned) mirror.destroy();
        mirror.start() catch return error.SessionInitFailed;

        const handle = self.allocator.create(FollowHandle) catch return error.OutOfMemory;
        handle.* = .{
            .allocator = self.allocator,
            .id = id,
            .pubkey = pubkey,
            .pk_hex = pk_hex,
            .npub = npub,
            .route = route,
            .dir = dir,
            .mirror = mirror,
        };
        handle_owned = true;

        self.mutex.lock();
        self.follows.append(self.allocator, handle) catch {
            self.mutex.unlock();
            handle.destroy(); // frees id/npub/dir + stops the mirror
            return error.OutOfMemory;
        };
        self.mutex.unlock();

        self.persist();
        return self.allocator.dupe(u8, id);
    }

    /// Stop and remove the follow with `id`. Returns true if found. Joins the
    /// mirror's threads, so this can block on an in-flight relay query.
    pub fn removeFollow(self: *Manager, id: []const u8) Error!bool {
        self.mutex.lock();
        var found: ?*FollowHandle = null;
        var idx: usize = 0;
        for (self.follows.items, 0..) |f, i| {
            if (std.mem.eql(u8, f.id, id)) {
                found = f;
                idx = i;
                break;
            }
        }
        if (found) |_| _ = self.follows.orderedRemove(idx);
        self.mutex.unlock();

        if (found) |f| {
            f.destroy(); // joins threads outside the lock
            self.persist();
            return true;
        }
        return false;
    }

    /// Snapshot all follows (with their mirrored torrents) into `arena`.
    pub fn followsSnapshot(self: *Manager, arena: Allocator) Allocator.Error![]api.Follow {
        self.mutex.lock();
        defer self.mutex.unlock();

        const out = try arena.alloc(api.Follow, self.follows.items.len);
        for (self.follows.items, 0..) |f, i| {
            const infos = try f.mirror.torrentsSnapshot(arena);
            const torrents = try arena.alloc(api.FollowTorrent, infos.len);
            var seeding_n: u32 = 0;
            var downloading_n: u32 = 0;
            var failed_n: u32 = 0;
            for (infos, 0..) |info, k| {
                switch (info.phase) {
                    .seeding => seeding_n += 1,
                    .downloading, .starting => downloading_n += 1,
                    .failed => failed_n += 1,
                }
                torrents[k] = .{
                    .name = info.name,
                    .hash = try arena.dupe(u8, &info.hash_hex),
                    .state = info.phase.jsonName(),
                    .pct = info.pct,
                    .peers = info.peers,
                    .down = info.down,
                    .up = info.up,
                };
            }
            out[i] = .{
                .id = try arena.dupe(u8, f.id),
                .npub = try arena.dupe(u8, f.npub),
                .route = f.route,
                .dir = try arena.dupe(u8, f.dir),
                .seeding = seeding_n,
                .downloading = downloading_n,
                .failed = failed_n,
                .torrents = torrents,
            };
        }
        return out;
    }

    // -----------------------------------------------------------------------
    // Drives (shared folders over Nostr)
    // -----------------------------------------------------------------------

    /// Add a shared drive: `role_str` is "publisher" (watch `dir` and publish
    /// every file as its own torrent) or "subscriber" (mirror the author's
    /// published drive index into `dir`). `author_str` (npub or 64-char hex)
    /// is required for a subscriber and ignored for a publisher; `also_strs`
    /// are extra writer pubkeys for a multi-writer subscription. Drives run on
    /// `direct` or `i2p`. Returns the new drive id (owned by the caller).
    pub fn addDrive(
        self: *Manager,
        role_str: []const u8,
        dir_arg: []const u8,
        name: []const u8,
        author_str: ?[]const u8,
        also_strs: []const []const u8,
        route: api.Route,
    ) Error![]u8 {
        const role = std.meta.stringToEnum(drive_mod.Role, role_str) orelse return error.InvalidDrive;
        if (dir_arg.len == 0 or name.len == 0) return error.InvalidDrive;
        if (route != .direct and route != .i2p) return error.InvalidDrive;

        var author: ?[32]u8 = null;
        if (role == .subscriber) {
            const s = author_str orelse return error.InvalidDrive;
            author = follow_mod.parsePubkeyArg(s) catch return error.InvalidDrive;
        }
        var also_list: std.ArrayList([32]u8) = .empty;
        defer also_list.deinit(self.allocator);
        for (also_strs) |s| {
            const pk = follow_mod.parsePubkeyArg(s) catch return error.InvalidDrive;
            also_list.append(self.allocator, pk) catch return error.OutOfMemory;
        }

        self.mutex.lock();
        for (self.drives.items) |d| {
            if (d.role == role and std.meta.eql(d.author, author) and
                std.mem.eql(u8, d.name, name) and std.mem.eql(u8, d.dir, dir_arg))
            {
                self.mutex.unlock();
                return error.InvalidDrive; // already added
            }
        }
        const id_num = self.next_drive_id;
        self.next_drive_id += 1;
        self.mutex.unlock();

        // Once the handle owns these, its `destroy` frees them; the errdefers
        // below are disarmed so a later failure can't double-free.
        var handle_owned = false;
        const id = std.fmt.allocPrint(self.allocator, "d{d}", .{id_num}) catch return error.OutOfMemory;
        errdefer if (!handle_owned) self.allocator.free(id);
        const dir = self.allocator.dupe(u8, dir_arg) catch return error.OutOfMemory;
        errdefer if (!handle_owned) self.allocator.free(dir);
        const name_owned = self.allocator.dupe(u8, name) catch return error.OutOfMemory;
        errdefer if (!handle_owned) self.allocator.free(name_owned);
        const also = also_list.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
        errdefer if (!handle_owned) self.allocator.free(also);

        const drv = drive_mod.Drive.create(self.allocator, .{
            .role = role,
            .dir = dir_arg,
            .drive = name,
            .author = author,
            .also = also,
            .route = route,
        }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            // NoKey (a publisher with no local Nostr identity), InvalidOptions
            // and UnsupportedRoute are all caller-fixable request problems.
            else => return error.InvalidDrive,
        };
        errdefer if (!handle_owned) drv.destroy();
        drv.start() catch return error.SessionInitFailed;

        const handle = self.allocator.create(DriveHandle) catch return error.OutOfMemory;
        handle.* = .{
            .allocator = self.allocator,
            .id = id,
            .role = role,
            .dir = dir,
            .name = name_owned,
            .author = author,
            .also = also,
            .route = route,
            .drive = drv,
        };
        handle_owned = true;

        self.mutex.lock();
        self.drives.append(self.allocator, handle) catch {
            self.mutex.unlock();
            handle.destroy(); // frees id/dir/name/also + stops the drive
            return error.OutOfMemory;
        };
        self.mutex.unlock();

        self.persist();
        return self.allocator.dupe(u8, id);
    }

    /// Stop and remove the drive with `id`. Returns true if found. Joins the
    /// drive loop thread, so this can block on an in-flight relay query.
    pub fn removeDrive(self: *Manager, id: []const u8) Error!bool {
        self.mutex.lock();
        var found: ?*DriveHandle = null;
        var idx: usize = 0;
        for (self.drives.items, 0..) |d, i| {
            if (std.mem.eql(u8, d.id, id)) {
                found = d;
                idx = i;
                break;
            }
        }
        if (found) |_| _ = self.drives.orderedRemove(idx);
        self.mutex.unlock();

        if (found) |d| {
            d.destroy(); // joins threads outside the lock
            self.persist();
            return true;
        }
        return false;
    }

    /// Snapshot all drives (with their file tables) into `arena`.
    pub fn drivesSnapshot(self: *Manager, arena: Allocator) Allocator.Error![]api.Drive {
        self.mutex.lock();
        defer self.mutex.unlock();

        const out = try arena.alloc(api.Drive, self.drives.items.len);
        for (self.drives.items, 0..) |d, i| {
            const infos = try d.drive.filesSnapshot(arena);
            const files = try arena.alloc(api.DriveFile, infos.len);
            for (infos, 0..) |info, k| {
                files[k] = .{
                    .path = info.path,
                    .size = info.size,
                    .phase = info.phase.jsonName(),
                    .info_hash = try arena.dupe(u8, &info.info_hash_hex),
                };
            }
            const author: ?[]const u8 = if (d.author) |pk|
                nip19.encode32(arena, .npub, pk) catch null
            else
                null;
            const also = try arena.alloc([]const u8, d.also.len);
            for (d.also, 0..) |pk, k| also[k] = nip19.encode32(arena, .npub, pk) catch "";
            out[i] = .{
                .id = try arena.dupe(u8, d.id),
                .role = @tagName(d.role),
                .name = try arena.dupe(u8, d.name),
                .dir = try arena.dupe(u8, d.dir),
                .route = d.route,
                .author = author,
                .also = also,
                .files = files,
                .file_count = files.len,
            };
        }
        return out;
    }

    // -----------------------------------------------------------------------
    // Snapshots
    // -----------------------------------------------------------------------

    /// Build a snapshot of all transfers into `arena`. Caller owns nothing
    /// individually — freeing the arena frees everything.
    pub fn snapshot(self: *Manager, arena: Allocator) Allocator.Error![]api.Transfer {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.milliTimestamp();
        var out = try arena.alloc(api.Transfer, self.transfers.items.len);
        for (self.transfers.items, 0..) |mt, i| {
            out[i] = try snapshotTransfer(mt, arena, now);
        }
        return out;
    }

    /// Seeds = transfers currently in the seeding state.
    pub fn seeds(self: *Manager, arena: Allocator) Allocator.Error![]api.Seed {
        self.mutex.lock();
        defer self.mutex.unlock();

        var list: std.ArrayList(api.Seed) = .empty;
        for (self.transfers.items) |mt| {
            const p = mt.session.progressSnapshot();
            const complete = p.num_pieces > 0 and p.have >= p.num_pieces;
            const is_seeding = p.mode == .seed or complete;
            if (!is_seeding) continue;
            const ratio: f64 = if (p.downloaded > 0)
                @as(f64, @floatFromInt(p.uploaded)) / @as(f64, @floatFromInt(p.downloaded))
            else
                0;
            try list.append(arena, .{
                .id = mt.id,
                .name = mt.name,
                .visibility = mt.route,
                // `onion` carries the seed's reachable hidden address: the
                // `.onion` for a tor seed, the `.b32.i2p` for an i2p seed.
                .onion = if (mt.hidden) |h|
                    try arena.dupe(u8, h.onion_host)
                else if (mt.i2p_host) |host|
                    try arena.dupe(u8, host)
                else
                    null,
                .size = p.total_length,
                .up_total = p.uploaded,
                .up = p.up_rate,
                // Peers connected to a seed are leechers pulling from us. Was
                // hardcoded 0, so the UI never reflected active downloaders.
                .leechers = p.peers,
                .ratio = ratio,
                .relays = 0,
            });
        }
        return list.toOwnedSlice(arena);
    }

    pub fn settings(self: *Manager, relays: []const []const u8) api.Settings {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .route = self.cfg.route,
            .socks = self.cfg.socks,
            .relays = relays,
            .download_dir = self.cfg.download_dir,
            .listen_port = self.cfg.listen_port,
            .max_active = self.cfg.max_active,
            .peer_limit = self.cfg.peer_limit,
            .publish_nip35 = self.cfg.publish_nip35,
        };
    }

    pub fn setRoute(self: *Manager, route: api.Route) void {
        self.mutex.lock();
        self.cfg.route = route;
        self.mutex.unlock();
        self.persist();
    }

    /// A locked copy of the current download dir (for callers that need to build
    /// a path without racing `setDownloadDir`).
    pub fn downloadDirDup(self: *Manager, a: Allocator) Allocator.Error![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return a.dupe(u8, self.cfg.download_dir);
    }

    /// Change the directory new transfers download into. Existing transfers keep
    /// their original directory; this affects subsequently added ones.
    pub fn setDownloadDir(self: *Manager, dir: []const u8) Allocator.Error!void {
        const dup = try self.allocator.dupe(u8, dir);
        self.mutex.lock();
        self.allocator.free(self.cfg.download_dir);
        self.cfg.download_dir = dup;
        // An explicit user choice replaces any kept-aside persisted value:
        // from here on `persist` saves the live dir again.
        if (self.saved_download_dir) |old| {
            self.allocator.free(old);
            self.saved_download_dir = null;
        }
        self.mutex.unlock();
        std.fs.cwd().makePath(dup) catch {};
        self.persist();
    }

    // -----------------------------------------------------------------------
    // Persistence — restore the full set of transfers/seeds + settings on
    // restart so nothing is lost. (Relays persist separately via nostr_config.)
    // -----------------------------------------------------------------------

    /// Write the current transfers + settings to the state file. Best-effort;
    /// a no-op while `restore` is replaying. Snapshots under the lock, then does
    /// file I/O unlocked.
    pub fn persist(self: *Manager) void {
        if (!self.cfg.persist) return;
        if (self.restoring.load(.acquire)) return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        self.mutex.lock();
        const route = self.cfg.route;
        const dir = aa.dupe(u8, self.saved_download_dir orelse self.cfg.download_dir) catch {
            self.mutex.unlock();
            return;
        };
        var specs: std.ArrayList(state_mod.TransferSpec) = .empty;
        for (self.transfers.items) |mt| {
            const src = aa.dupe(u8, mt.source) catch break;
            specs.append(aa, .{
                .kind = if (mt.is_seed) .seed else .download,
                .source = src,
                .route = mt.route,
                .nostr = mt.want_nostr,
            }) catch break;
        }
        // Re-include transfers whose transport was unavailable at restore so a
        // transient outage doesn't erase them on the next persist (which any
        // add/remove triggers). They carry no live session, just the saved spec.
        for (self.retained_specs.items) |s| {
            const src = aa.dupe(u8, s.source) catch break;
            specs.append(aa, .{
                .kind = s.kind,
                .source = src,
                .route = s.route,
                .nostr = s.nostr,
            }) catch break;
        }
        var follow_specs: std.ArrayList(state_mod.FollowSpec) = .empty;
        for (self.follows.items) |f| {
            const pk = aa.dupe(u8, &f.pk_hex) catch break;
            follow_specs.append(aa, .{ .pubkey = pk, .route = f.route }) catch break;
        }
        var drive_specs: std.ArrayList(state_mod.DriveSpec) = .empty;
        for (self.drives.items) |d| {
            const id = aa.dupe(u8, d.id) catch break;
            const ddir = aa.dupe(u8, d.dir) catch break;
            const dname = aa.dupe(u8, d.name) catch break;
            var author_hex: []const u8 = "";
            if (d.author) |pk| {
                var hex: [64]u8 = undefined;
                secp.toHex(&pk, &hex);
                author_hex = aa.dupe(u8, &hex) catch break;
            }
            var also_buf: std.ArrayList(u8) = .empty;
            for (d.also, 0..) |pk, k| {
                if (k > 0) also_buf.append(aa, ',') catch break;
                var hex: [64]u8 = undefined;
                secp.toHex(&pk, &hex);
                also_buf.appendSlice(aa, &hex) catch break;
            }
            drive_specs.append(aa, .{
                .id = id,
                .role = switch (d.role) {
                    .publisher => .publisher,
                    .subscriber => .subscriber,
                },
                .dir = ddir,
                .name = dname,
                .author = author_hex,
                .also = also_buf.items,
                .route = d.route,
            }) catch break;
        }
        self.mutex.unlock();

        state_mod.save(self.allocator, route, dir, specs.items, follow_specs.items, drive_specs.items) catch |e| {
            log.warn("failed to persist daemon state: {}", .{e});
        };
    }

    /// Apply persisted settings (route, download dir) synchronously. Cheap and
    /// non-blocking, so the daemon's first snapshot already reflects them. Call
    /// before serving; the slow transfer replay (`restoreTransfers`) runs after.
    pub fn restoreSettings(self: *Manager) void {
        const st = (state_mod.load(self.allocator) catch |e| {
            log.warn("failed to load daemon state: {}", .{e});
            return;
        }) orelse return;
        defer st.deinit(self.allocator);

        self.mutex.lock();
        // An explicit --route wins over the persisted (GUI-set) route; the
        // persisted one only fills in when the user didn't ask for anything.
        if (!self.cfg.route_explicit) self.cfg.route = st.route;
        // Apply the persisted downloadDir only when it doesn't get outranked:
        // a pinned dir (explicit --download-dir or $CARL_DIR) wins over the DB
        // value so the daemon matches the CLI's `$CARL_DIR > setting > default`
        // order, and placeholder values ("", ".", the retired desktop default
        // ~/Downloads/carl-download) are stale pre-unification state, not a
        // user choice. When pinned, keep the DB value aside so `persist`
        // re-saves it — the override is ephemeral and must not clobber it.
        if (!workdir.isPlaceholder(self.allocator, st.download_dir)) {
            if (self.allocator.dupe(u8, st.download_dir)) |d| {
                if (self.cfg.download_dir_pinned) {
                    if (self.saved_download_dir) |old| self.allocator.free(old);
                    self.saved_download_dir = d;
                } else {
                    self.allocator.free(self.cfg.download_dir);
                    self.cfg.download_dir = d;
                }
            } else |_| {}
        }
        self.mutex.unlock();
        std.fs.cwd().makePath(self.cfg.download_dir) catch {};
    }

    /// Re-add every persisted transfer/seed. Downloads resume from on-disk
    /// pieces; seeds re-hash their file. SLOW for anonymized routes (each i2p
    /// SAM SESSION CREATE / Tor hidden service blocks), so the daemon runs this
    /// on a background thread (see main.zig) — it's mutex-safe against the
    /// serving handlers, and `persist` no-ops (atomic `restoring`) until the end
    /// so a partial replay can never rewrite the DB with fewer transfers.
    pub fn restoreTransfers(self: *Manager) void {
        const st = (state_mod.load(self.allocator) catch |e| {
            log.warn("failed to load daemon state: {}", .{e});
            return;
        }) orelse return;
        defer st.deinit(self.allocator);

        self.restoring.store(true, .release);
        var restored: usize = 0;
        var retained: usize = 0;
        for (st.transfers) |t| {
            const res = switch (t.kind) {
                .download => self.addTransfer(t.source, t.route, t.nostr),
                .seed => self.addSeed(t.source, t.route, t.nostr),
            };
            if (res) |id| {
                self.allocator.free(id);
                restored += 1;
            } else |e| {
                // Never drop a saved spec on a failed re-add: the cause is often
                // transient (the SAM bridge / I2P router or Tor still starting, a
                // proxy down, a seed file on a not-yet-mounted disk). Keep it in
                // `retained_specs` so every `persist` — at the end of restore AND
                // any later add/remove — re-includes it, and the next restart
                // retries instead of silently deleting the user's transfer.
                // (Genuinely-invalid specs cost a warning per startup; that beats
                // data loss.) Only an OOM on the copy can drop one.
                if (self.retainSpec(t)) {
                    retained += 1;
                    log.warn("restore: could not re-add '{s}' ({}); keeping it for retry", .{ t.source, e });
                } else {
                    log.warn("restore: dropping '{s}': {} (out of memory)", .{ t.source, e });
                }
            }
        }
        // Re-spawn persisted follows. A failed re-add (bad key, OOM) is logged
        // and dropped — unlike transfers there's no transient transport setup
        // here; the mirror itself retries its relays/peers forever once spawned.
        var followed: usize = 0;
        for (st.follows) |f| {
            if (self.addFollow(f.pubkey, f.route)) |id| {
                self.allocator.free(id);
                followed += 1;
            } else |e| {
                log.warn("restore: could not re-follow '{s}': {}", .{ f.pubkey, e });
            }
        }
        // Re-spawn persisted drives. Like follows, a failed re-add (bad key,
        // missing identity, OOM) is logged and dropped; the drive loop itself
        // retries its relays/peers forever once spawned.
        var drives_n: usize = 0;
        for (st.drives) |ds| {
            const author_opt: ?[]const u8 = if (ds.author.len > 0) ds.author else null;
            var also_strs: std.ArrayList([]const u8) = .empty;
            defer also_strs.deinit(self.allocator);
            var it = std.mem.splitScalar(u8, ds.also, ',');
            while (it.next()) |part| {
                if (part.len == 0) continue;
                also_strs.append(self.allocator, part) catch break;
            }
            if (self.addDrive(@tagName(ds.role), ds.dir, ds.name, author_opt, also_strs.items, ds.route)) |id| {
                self.allocator.free(id);
                drives_n += 1;
            } else |e| {
                log.warn("restore: could not re-add drive '{s}' at '{s}': {}", .{ ds.name, ds.dir, e });
            }
        }
        self.restoring.store(false, .release);
        // Persisting here is safe even after failures: every failed spec was just
        // retained, and `persist` re-includes `retained_specs` alongside the live
        // set, so nothing is erased.
        self.persist();
        if (restored > 0) log.info("restored {d} transfer(s) from saved state", .{restored});
        if (followed > 0) log.info("restored {d} follow(s) from saved state", .{followed});
        if (drives_n > 0) log.info("restored {d} drive(s) from saved state", .{drives_n});
        if (retained > 0) log.info("kept {d} saved transfer(s) that could not be re-added", .{retained});
    }

    /// Full synchronous restore (settings + transfers). Kept for tests and the
    /// inline fallback when the background restore thread can't be spawned.
    pub fn restore(self: *Manager) void {
        self.restoreSettings();
        self.restoreTransfers();
    }

    /// Best-effort write of a seed's `.torrent` onto the seeds shelf; a failure
    /// only costs the artifact (the seed still restores by re-hashing its data
    /// file at the persisted path).
    fn writeSeedTorrent(self: *Manager, hex: *const [40]u8, mi: metainfo.Metainfo) void {
        const blob = session_mod.buildTorrentBytes(self.allocator, mi) catch return;
        defer self.allocator.free(blob);
        const sdir = self.ensureSeedsDir(self.cfg.download_dir) orelse return;
        defer self.allocator.free(sdir);
        const path = std.fmt.allocPrint(self.allocator, "{s}/{s}.torrent", .{ sdir, hex }) catch return;
        defer self.allocator.free(path);
        var f = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
        defer f.close();
        f.writeAll(blob) catch {};
    }

    /// Retry every retained spec — a persisted transfer whose re-add failed at
    /// restore (the I2P router / SAM bridge or Tor still starting, a proxy
    /// down, a file on a not-yet-mounted disk). Called periodically by the
    /// daemon's health loop, so a seed lost to a slow-starting router comes
    /// back within one tick (~30s) instead of "after the next restart" — until
    /// then the transfer existed only as an invisible DB row, which to the user
    /// reads as "I restarted and my seed is gone". A successful re-add drops
    /// the retained copy via `register`; failures stay retained for the next
    /// tick (and the next restart) and are logged at debug to avoid a warning
    /// every 30s for a genuinely-dead spec.
    pub fn retryRetained(self: *Manager) void {
        if (self.restoring.load(.acquire)) return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        self.mutex.lock();
        var specs: std.ArrayList(state_mod.TransferSpec) = .empty;
        for (self.retained_specs.items) |s| {
            const src = aa.dupe(u8, s.source) catch break;
            specs.append(aa, .{ .kind = s.kind, .source = src, .route = s.route, .nostr = s.nostr }) catch break;
        }
        self.mutex.unlock();

        for (specs.items) |t| {
            const res = switch (t.kind) {
                .download => self.addTransfer(t.source, t.route, t.nostr),
                .seed => self.addSeed(t.source, t.route, t.nostr),
            };
            if (res) |id| {
                self.allocator.free(id);
                log.info("retry: restored '{s}'", .{t.source});
            } else |e| {
                log.debug("retry: '{s}' still unavailable: {}", .{ t.source, e });
            }
        }
    }

    /// Remove every retained spec whose source matches (the spec became live
    /// again, or the caller is discarding it). Caller must hold `mutex` when the
    /// manager is serving (restore runs single-threaded before that).
    fn dropRetained(self: *Manager, source: []const u8) void {
        var i: usize = 0;
        while (i < self.retained_specs.items.len) {
            if (std.mem.eql(u8, self.retained_specs.items[i].source, source)) {
                self.allocator.free(self.retained_specs.items[i].source);
                _ = self.retained_specs.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Copy a persisted spec into `retained_specs` so `persist` re-includes it.
    /// Returns false if the (owned) source copy can't be allocated, in which case
    /// the caller drops the spec — there's no safe way to retain it.
    fn retainSpec(self: *Manager, t: state_mod.TransferSpec) bool {
        const src = self.allocator.dupe(u8, t.source) catch return false;
        // `restoreTransfers` now runs on a background thread while the daemon
        // serves, so this can race a concurrent add's `dropRetained` (and
        // `persist`'s read) — all of which touch `retained_specs` under the
        // mutex. Take the lock here too.
        self.mutex.lock();
        defer self.mutex.unlock();
        self.retained_specs.append(self.allocator, .{
            .kind = t.kind,
            .source = src,
            .route = t.route,
            .nostr = t.nostr,
        }) catch {
            self.allocator.free(src);
            return false;
        };
        return true;
    }

    /// Capture any download whose (magnet) metadata has resolved: write the real
    /// `.torrent` next to the data, repoint the persisted source at it, and
    /// re-persist. A subsequent restart then resumes the torrent fully —
    /// verifying on-disk pieces — instead of re-bootstrapping the magnet. Called
    /// periodically by the daemon; idempotent (the `resolved` flag).
    pub fn checkpoint(self: *Manager) void {
        var changed = false;
        self.mutex.lock();
        for (self.transfers.items) |mt| {
            if (mt.is_seed or mt.resolved) continue;
            const blob = mt.session.copyTorrent(self.allocator) orelse continue;
            defer self.allocator.free(blob);
            // Name the file by info-hash (safe; the display name may contain /),
            // on the seeds shelf so every restart recipe lives in one place.
            const sdir = self.ensureSeedsDir(self.cfg.download_dir) orelse continue;
            defer self.allocator.free(sdir);
            const path = std.fmt.allocPrint(self.allocator, "{s}/{s}.torrent", .{ sdir, &mt.hash_hex }) catch continue;
            var wrote = true;
            {
                var f = std.fs.cwd().createFile(path, .{ .truncate = true }) catch {
                    self.allocator.free(path);
                    continue;
                };
                defer f.close();
                f.writeAll(blob) catch {
                    wrote = false;
                };
            }
            if (!wrote) {
                self.allocator.free(path);
                continue;
            }
            // Repoint the persisted recipe at the resolved .torrent (ownership of
            // `path` moves to mt.source).
            self.allocator.free(mt.source);
            mt.source = path;
            mt.resolved = true;
            changed = true;
        }
        self.mutex.unlock();
        if (changed) self.persist();
    }

    // -----------------------------------------------------------------------
    // Session construction
    // -----------------------------------------------------------------------

    const Built = struct {
        session: *session_mod.Session,
        meta: metainfo.Metainfo,
        info_hash: [20]u8,
        name: []const u8, // borrows from meta
    };

    fn buildSession(self: *Manager, source: []const u8, proxy: ?proxy_mod.Proxy, i2p: ?*i2p_sam.Session) Error!Built {
        if (std.mem.startsWith(u8, source, "magnet:")) return self.buildMagnet(source, proxy, i2p);
        if (std.mem.startsWith(u8, source, "http://") or std.mem.startsWith(u8, source, "https://"))
            return self.buildHttp(source, proxy, i2p);
        return self.buildFile(source, proxy, i2p);
    }

    fn buildFile(self: *Manager, path: []const u8, proxy: ?proxy_mod.Proxy, i2p: ?*i2p_sam.Session) Error!Built {
        const data = std.fs.cwd().readFileAlloc(self.allocator, path, 10 * 1024 * 1024) catch return error.InvalidTorrent;
        defer self.allocator.free(data);
        const mi = metainfo.parse(self.allocator, data) catch return error.InvalidTorrent;
        return self.fromMetainfo(mi, proxy, i2p);
    }

    fn buildHttp(self: *Manager, url: []const u8, proxy: ?proxy_mod.Proxy, i2p: ?*i2p_sam.Session) Error!Built {
        // The i2p route has no clearnet-tunneled fetch path: `fetchUrl` would
        // dial the `.torrent` host directly (proxy is null on this route),
        // leaking the real IP despite the route being documented as fail-closed.
        // HTTP-over-SAM is P3 follow-up work (#35); until then, reject.
        if (i2p != null) return error.UnsupportedOnI2p;
        const data = fetchUrl(self.allocator, url, proxy) catch return error.HttpFailed;
        defer self.allocator.free(data);
        const mi = metainfo.parse(self.allocator, data) catch return error.InvalidTorrent;
        return self.fromMetainfo(mi, proxy, i2p);
    }

    fn fromMetainfo(self: *Manager, mi: metainfo.Metainfo, proxy: ?proxy_mod.Proxy, i2p: ?*i2p_sam.Session) Error!Built {
        // On a failed Session.init the metainfo is ours to free (it only becomes
        // the session's on success); mirrors the magnet path's errdefer.
        errdefer mi.deinit(self.allocator);
        const session = self.allocator.create(session_mod.Session) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(session);
        session.* = session_mod.Session.init(self.allocator, mi, self.cfg.download_dir, .download, self.cfg.listen_port, proxy, .any, false, i2p, false) catch {
            return error.SessionInitFailed;
        };
        // Daemon downloads keep seeding once complete — the GUI lists them
        // under Seeds, and anything in the work dir stays reseedable. The
        // session downgrades its file handles to read-only at that point.
        session.seed_after_complete = true;
        return .{ .session = session, .meta = mi, .info_hash = session.info_hash, .name = mi.name };
    }

    /// Build a metadata-only session from a magnet link (BEP 9 bootstrap),
    /// mirroring the CLI's magnet path minus the optional NIP-35 enrichment.
    fn buildMagnet(self: *Manager, uri: []const u8, proxy: ?proxy_mod.Proxy, i2p: ?*i2p_sam.Session) Error!Built {
        const ml = magnet_mod.parse(self.allocator, uri) catch return error.InvalidMagnet;
        defer ml.deinit(self.allocator);
        const a = self.allocator;

        const mi = try buildMagnetMetainfo(a, ml);
        errdefer mi.deinit(a);

        const session = a.create(session_mod.Session) catch return error.OutOfMemory;
        errdefer a.destroy(session);
        session.* = session_mod.Session.init(a, mi, self.cfg.download_dir, .download, self.cfg.listen_port, proxy, .any, false, i2p, false) catch {
            return error.SessionInitFailed;
        };
        session.info_hash = ml.info_hash; // use the magnet's hash, not SHA1("")
        session.metadata_download = extension.MetadataDownload.init(a, ml.info_hash);
        session.metadata_only = true;
        // Same as the .torrent path: keep seeding after the download completes.
        session.seed_after_complete = true;
        return .{ .session = session, .meta = mi, .info_hash = ml.info_hash, .name = session.meta.name };
    }
};

/// Construct a fully-owned placeholder `Metainfo` from a magnet link. On any
/// failure all partial allocations are freed; on success ownership transfers to
/// the returned value (free it via `Metainfo.deinit`). Kept free-standing so
/// its errdefers never overlap a caller's `mi.deinit` (which would double-free).
fn buildMagnetMetainfo(a: Allocator, ml: magnet_mod.MagnetLink) Allocator.Error!metainfo.Metainfo {
    const name = try a.dupe(u8, ml.name orelse "unknown");
    errdefer a.free(name);

    const path0 = try a.alloc([]const u8, 1);
    errdefer a.free(path0);
    path0[0] = try a.dupe(u8, name);
    errdefer a.free(path0[0]);

    const files = try a.alloc(metainfo.FileInfo, 1);
    errdefer a.free(files);
    files[0] = .{ .length = 0, .path = path0 };

    var announce_list: ?[]const []const []const u8 = null;
    errdefer if (announce_list) |tiers| {
        for (tiers) |tier| {
            for (tier) |t| a.free(t);
            a.free(tier);
        }
        a.free(tiers);
    };
    if (ml.trackers.len > 0) {
        const tier = try a.alloc([]const u8, ml.trackers.len);
        // Scoped to this block: covers the window before `announce_list` (and
        // its function-scope errdefer) takes ownership.
        var filled: usize = 0;
        errdefer {
            for (tier[0..filled]) |t| a.free(t);
            a.free(tier);
        }
        while (filled < ml.trackers.len) : (filled += 1) {
            tier[filled] = try a.dupe(u8, ml.trackers[filled]);
        }
        const tiers = try a.alloc([]const []const u8, 1);
        tiers[0] = tier;
        announce_list = tiers;
    }

    const announce = try a.dupe(u8, if (ml.trackers.len > 0) ml.trackers[0] else "");
    errdefer a.free(announce);

    return metainfo.Metainfo{
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

// ---------------------------------------------------------------------------
// Per-transfer snapshot (called with Manager.mutex held)
// ---------------------------------------------------------------------------

// Build one transfer's snapshot from race-safe session state. Called with
// Manager.mutex held.
/// Grace period (ms) before a peerless transfer is reported as `no_peers`
/// rather than `connecting` — long enough to cover proxy/DHT/Nostr bootstrap.
const peer_grace_ms: i64 = 20_000;
/// Seconds without a byte of progress before an otherwise-active transfer is
/// reported `stalled` instead of `downloading`.
const idle_stall_secs: i64 = 5;

fn snapshotTransfer(mt: *ManagedTransfer, arena: Allocator, now: i64) Allocator.Error!api.Transfer {
    const p = mt.session.progressSnapshot();

    // The session owns rate sampling now (see Session.sampleRate); the manager
    // just reads the smoothed value, so multiple snapshot callers can't corrupt
    // it the way the old per-snapshot delta did.
    const grace_elapsed = (now - mt.added_ms) > peer_grace_ms;
    const flowing = p.idle_secs <= idle_stall_secs;
    const status = deriveStatus(p.metadata_only, p.num_pieces, p.have, p.mode == .seed, p.peers, flowing, grace_elapsed);
    const pct = pctFromCounts(p.have, p.num_pieces);

    var src_buf: [3]api.SourceKind = undefined;
    const src = deriveSources(&src_buf, mt.route, mt.has_tracker, mt.want_nostr);
    const sources = try arena.dupe(api.SourceKind, src);

    // Per-file rows from the session's published file snapshot.
    const file_infos = mt.session.fileSnapshot(arena) catch &.{};
    const file_rows = try arena.alloc(api.FileEntry, file_infos.len);
    for (file_infos, 0..) |fi, i| {
        file_rows[i] = .{
            .name = fi.name,
            .size = fi.size,
            .pct = fi.pct,
        };
    }

    // Per-peer rows from the session's published snapshot (1 Hz, race-safe).
    const peer_infos = mt.session.peerSnapshot(arena) catch &.{};
    const peer_rows = try arena.alloc(api.Peer, peer_infos.len);
    for (peer_infos, 0..) |pi, i| {
        peer_rows[i] = .{
            .addr = pi.addr,
            .port = pi.port,
            .client = pi.client,
            .down = pi.down,
            .up = pi.up,
            .pct = pi.pct,
            .flags = pi.flags,
            .onion = pi.onion,
        };
    }
    // Per-source rows with real detail (tracker seed/leecher counts, DHT
    // node count, announce interval) from the session's Progress snapshot.
    const source_rows = try buildSourceRows(arena, p, mt, now);

    var eta_buf: [24]u8 = undefined;
    const remaining: u64 = if (p.total_length > 0 and pct < 100)
        p.total_length - (p.total_length * pct / 100)
    else
        0;
    const eta = try arena.dupe(u8, formatEta(&eta_buf, status, remaining, p.down_rate));

    const ratio: ?f64 = if (p.downloaded > 0)
        @as(f64, @floatFromInt(p.uploaded)) / @as(f64, @floatFromInt(p.downloaded))
    else
        null;

    return .{
        .id = try arena.dupe(u8, mt.id),
        .name = try arena.dupe(u8, mt.name),
        .hash = try arena.dupe(u8, &mt.hash_hex),
        .magnet = try arena.dupe(u8, mt.magnet),
        .status = status,
        .route = mt.route,
        .sources = sources,
        .pct = pct,
        .size = if (p.total_length > 0) p.total_length else null,
        // Show the live down rate only while bytes are actually flowing; once
        // idle the EWMA still has a decaying tail that would contradict a
        // "stalled"/"no peers" pill. Up rate keeps its own decay (seeds upload
        // without download progress, so `flowing` doesn't apply to it).
        .down = if (flowing) p.down_rate else 0,
        .up = p.up_rate,
        .eta = eta,
        .peers = p.peers,
        .seeds = 0,
        .meta_have = p.meta_have,
        .meta_total = p.meta_total,
        .ratio = if (status == .seeding or status == .complete) ratio else null,
        .onion = null,
        .file_rows = file_rows,
        .peer_rows = peer_rows,
        .source_rows = source_rows,
    };
}

// ===========================================================================
// Pure derivation helpers (unit-tested)
// ===========================================================================

pub fn pctFromCounts(have: u32, num_pieces: u32) u8 {
    if (num_pieces == 0) return 0;
    const p = @as(u64, have) * 100 / num_pieces;
    return @intCast(@min(p, 100));
}

/// Derive the lifecycle/status pill for a transfer.
///
/// `flowing` is true when a byte of real progress (piece or metadata) arrived
/// recently; `grace_elapsed` is true once enough time has passed that "0 peers"
/// means "found none" rather than "still bootstrapping". The order matters:
/// terminal states (seeding/complete) win, then the peerless states explain a
/// stall (`connecting` early, `no_peers` after the grace window), then the
/// active phases (`metadata` while fetching the info dict, else
/// `downloading`/`stalled`).
pub fn deriveStatus(
    metadata_only: bool,
    num_pieces: u32,
    have: u32,
    mode_is_seed: bool,
    peers: u32,
    flowing: bool,
    grace_elapsed: bool,
) api.Status {
    if (mode_is_seed) return .seeding;
    if (num_pieces > 0 and have >= num_pieces) return .complete;

    // No peers: say why instead of a misleading "metadata"/"stalled".
    if (peers == 0) return if (grace_elapsed) .no_peers else .connecting;

    // Have peers but still fetching the info dict (magnet bootstrap).
    if (metadata_only and num_pieces == 0) return .metadata;

    // Have metadata and peers: downloading if bytes are flowing, else stalled.
    return if (flowing) .downloading else .stalled;
}

/// Fill `out` with the sources for a route and return the used slice.
pub fn deriveSources(
    out: *[3]api.SourceKind,
    route: api.Route,
    has_tracker: bool,
    want_nostr: bool,
) []api.SourceKind {
    var n: usize = 0;
    switch (route) {
        .direct => {
            if (has_tracker) {
                out[n] = .tracker;
                n += 1;
            }
            out[n] = .dht; // DHT only available on the clear net
            n += 1;
            if (want_nostr) {
                out[n] = .nostr;
                n += 1;
            }
        },
        .proxy, .tor => {
            // Tunneled via SOCKS: UDP trackers are rewritten to HTTP and
            // tunneled through the proxy, so trackers are always usable.
            if (has_tracker) {
                out[n] = .tracker;
                n += 1;
            }
            if (want_nostr or n == 0) {
                out[n] = .nostr;
                n += 1;
            }
        },
        .i2p => {
            // I2P can't reach clearnet trackers/DHT and has no I2P-native
            // trackers yet, so `Session.tryAnnounceUrl` skips every announce
            // (even HTTP ones). Reporting `tracker` here would imply peer
            // discovery that never happens — Nostr `.b32.i2p` announces are the
            // only real source, and only when the user opted into Nostr.
            if (want_nostr) {
                out[n] = .nostr;
                n += 1;
            }
        },
    }
    return out[0..n];
}

/// Build `api.Source` rows from the session's Progress snapshot and the
/// transfer's route config. Mirrors `deriveSources` for which sources appear,
/// but enriches each row with real tracker/DHT/Nostr detail.
fn buildSourceRows(
    arena: Allocator,
    p: session_mod.Session.Progress,
    mt: *ManagedTransfer,
    now_ms: i64,
) Allocator.Error![]api.Source {
    var rows: std.ArrayList(api.Source) = .empty;
    const now_s = @divTrunc(now_ms, 1000);

    var src_buf: [3]api.SourceKind = undefined;
    const kinds = deriveSources(&src_buf, mt.route, mt.has_tracker, mt.want_nostr);

    for (kinds) |kind| {
        switch (kind) {
            .tracker => {
                const label = if (p.tracker_url.len > 0) p.tracker_url else "tracker";
                const state = if (p.tracker_state == 1) "working" else "connecting";
                var detail_buf: [128]u8 = undefined;
                const detail = if (p.tracker_state == 1)
                    std.fmt.bufPrint(&detail_buf, "{d} seeds · {d} leechers", .{ p.seeders, p.leechers }) catch ""
                else
                    "";
                var interval_buf: [24]u8 = undefined;
                const interval: []const u8 = if (p.tracker_state == 1) blk: {
                    const elapsed = now_s - p.last_announce_s;
                    const remaining = p.announce_interval_s - elapsed;
                    if (remaining > 60) {
                        break :blk std.fmt.bufPrint(&interval_buf, "next in {d}m", .{@divTrunc(remaining, 60)}) catch "—";
                    } else if (remaining > 0) {
                        break :blk std.fmt.bufPrint(&interval_buf, "next in {d}s", .{remaining}) catch "—";
                    }
                    break :blk "due now";
                } else "—";
                try rows.append(arena, .{
                    .kind = .tracker,
                    .label = try arena.dupe(u8, label),
                    .state = try arena.dupe(u8, state),
                    .detail = try arena.dupe(u8, detail),
                    .interval = try arena.dupe(u8, interval),
                });
            },
            .dht => {
                var detail_buf: [64]u8 = undefined;
                const detail = if (p.dht_nodes > 0)
                    std.fmt.bufPrint(&detail_buf, "{d} nodes", .{p.dht_nodes}) catch ""
                else
                    "bootstrapping…";
                try rows.append(arena, .{
                    .kind = .dht,
                    .label = "Distributed Hash Table",
                    .state = if (p.dht_nodes > 0) "working" else "connecting",
                    .detail = try arena.dupe(u8, detail),
                });
            },
            .nostr => {
                try rows.append(arena, .{
                    .kind = .nostr,
                    .label = "Nostr peer-announce (NIP-35)",
                    .state = "working",
                    .detail = "peer-announce active",
                });
            },
        }
    }

    return rows.toOwnedSlice(arena);
}

/// Format a human ETA into `buf`. Returns "—" when stalled/idle/complete.
pub fn formatEta(buf: []u8, status: api.Status, remaining_bytes: u64, rate_bps: u64) []const u8 {
    if (status == .stalled) return "stalled";
    if (status == .complete or status == .seeding) return "—";
    if (rate_bps == 0 or remaining_bytes == 0) return "—";
    const secs = remaining_bytes / rate_bps;
    if (secs >= 3600) {
        const h = secs / 3600;
        const m = (secs % 3600) / 60;
        return std.fmt.bufPrint(buf, "{d}h {d}m", .{ h, m }) catch "—";
    } else if (secs >= 60) {
        return std.fmt.bufPrint(buf, "{d}m {d}s", .{ secs / 60, secs % 60 }) catch "—";
    }
    return std.fmt.bufPrint(buf, "{d}s", .{secs}) catch "—";
}

// ---------------------------------------------------------------------------
// Transfer thread + nostr peer discovery
// ---------------------------------------------------------------------------

fn runThread(mt: *ManagedTransfer) void {
    if (mt.want_nostr) {
        if (mt.is_seed) {
            publishSeedNostr(mt);
        } else {
            mt.session.setPeerDiscovery(mt, rediscoverPeersCb);
            mt.session.setOnComplete(mt, onDownloadCompleteCb);
            collectNostrPeers(mt);
        }
    }
    mt.session.run() catch |err| {
        log.err("transfer {s}: session error: {}", .{ mt.id, err });
    };
}

/// `Session.OnComplete` callback: broadcast the completed torrent on Nostr
/// (NIP-35 kind-2003) if no event for this info-hash exists on the configured
/// relays yet. Runs on the session thread after all pieces are verified.
fn onDownloadCompleteCb(ctx: *anyopaque) void {
    const mt: *ManagedTransfer = @ptrCast(@alignCast(ctx));
    broadcastIfNew(mt);
}

/// Query relays for existing kind-2003 events matching this info-hash. If none
/// are found, publish a new NIP-35 torrent event so the Nostr collection grows
/// organically as users complete downloads.
fn broadcastIfNew(mt: *ManagedTransfer) void {
    const a = mt.allocator;
    const relay_urls = nostr_config.readRelays(a) catch return;
    defer nostr_config.freeRelays(a, relay_urls);

    var ih_hex: [40]u8 = undefined;
    secp.toHex(&mt.info_hash, &ih_hex);

    const filter: nostr_mod.Filter = .{
        .kinds = &.{nip35.kind_torrent},
        .tags = &.{.{ .letter = 'x', .values = &.{&ih_hex} }},
        .limit = 1,
    };

    for (relay_urls) |url| {
        var r = relay_mod.Relay.connect(a, url, mt.proxy) catch continue;
        defer r.deinit();
        const events = relay_mod.subscribeAndCollect(a, &r, filter, .{
            .timeout_ms = 8_000,
            .max_events = 1,
        }) catch continue;
        defer {
            for (events) |e| e.deinit(a);
            a.free(events);
        }
        if (events.len > 0) {
            log.info("transfer {s}: torrent already on nostr, skipping broadcast", .{mt.id});
            return;
        }
    }

    log.info("transfer {s}: broadcasting torrent to nostr (NIP-35)", .{mt.id});
    const ann: seeding.Announce = if (mt.hidden) |h|
        .{ .onion = .{ .host = h.onion_host, .port = h.onion_port } }
    else if (mt.i2p_host) |host|
        .{ .i2p = .{ .host = host, .port = 0 } }
    else
        .none;
    seeding.publish(a, mt.meta, mt.info_hash, ann, "", mt.proxy) catch |err| {
        log.warn("transfer {s}: nostr broadcast failed: {}", .{ mt.id, err });
    };
}

/// `Session.PeerDiscovery` callback: re-run Nostr peer discovery for `ctx`
/// (a `*ManagedTransfer`). Invoked on the session thread by the run loop.
fn rediscoverPeersCb(ctx: *anyopaque) void {
    const mt: *ManagedTransfer = @ptrCast(@alignCast(ctx));
    log.info("transfer {s}: no peers, re-querying nostr for peers", .{mt.id});
    collectNostrPeers(mt);
}

/// Publish a seed's Nostr events via the shared `seeding.publish` (the same path
/// the CLI `carl seed` uses). A `.tor` seed has a hidden service, so it also
/// publishes a kind-30078 onion peer-announce — what a Tor leecher needs to dial
/// it — over Tor (via `mt.proxy`). Other seeds publish only NIP-35 discovery
/// metadata (no routable endpoint to announce). Best-effort.
fn publishSeedNostr(mt: *ManagedTransfer) void {
    const ann: seeding.Announce = if (mt.hidden) |h|
        .{ .onion = .{ .host = h.onion_host, .port = h.onion_port } }
    else if (mt.i2p_host) |host|
        // Port 0 = the destination's default I2CP port; our STREAM FORWARD
        // delivers every inbound stream for the session regardless of TO_PORT.
        .{ .i2p = .{ .host = host, .port = 0 } }
    else
        .none;
    seeding.publish(mt.allocator, mt.meta, mt.info_hash, ann, "", mt.proxy) catch |err| {
        log.warn("seed {s}: nostr publish failed: {}", .{ mt.id, err });
    };
}

/// Pull peer-announce (kind-30078) endpoints for this info-hash off the
/// configured relays and feed them to the session. Mirrors the CLI's
/// collectNostrPeers, trimmed. Best-effort: failures are logged, not fatal.
fn collectNostrPeers(mt: *ManagedTransfer) void {
    const a = mt.allocator;
    var ih_hex: [40]u8 = undefined;
    secp.toHex(&mt.info_hash, &ih_hex);

    const relay_urls = nostr_config.readRelays(a) catch return;
    defer nostr_config.freeRelays(a, relay_urls);

    var values = [_][]const u8{&ih_hex};
    var tag_filters = [_]nostr_mod.Filter.TagFilter{.{ .letter = 'd', .values = &values }};
    const filter: nostr_mod.Filter = .{
        .kinds = &[_]u32{peer_announce.kind_peer_announce},
        .tags = &tag_filters,
        .limit = 200,
    };

    var added: usize = 0;
    for (relay_urls) |url| {
        if (!mt.session.running) return;
        var r = relay_mod.Relay.connect(a, url, mt.proxy) catch continue;
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
            // Other clients' announces may not parse (different schema); that's
            // not an error, just skip them (debug-only so it can't spam).
            const ann = peer_announce.parse(ev) catch |e| {
                log.debug("nostr discovery {s}: skipping unparsable announce: {}", .{ url, e });
                continue;
            };
            if (!std.mem.eql(u8, &ann.info_hash, &mt.info_hash)) continue;
            if (added >= 50) break;
            switch (ann.endpoint) {
                .ipv4 => |ep| {
                    // On the I2P transport a clearnet IPv4 peer is unreachable
                    // (connectDirectPeer skips it to avoid leaking the real IP).
                    // Skip it here too so clearnet announces don't silently count
                    // against the discovery budget and starve later `.b32.i2p`
                    // announces. (proxy/Tor dial IPv4 through the proxy, so they
                    // still count.)
                    if (mt.session.i2p != null) continue;
                    const addr = std.net.Address.initIp4(ep.ip, ep.port);
                    mt.session.connectDirectPeer(addr) catch continue;
                    added += 1;
                },
                .onion => |ep| {
                    if (mt.session.proxy == null) continue;
                    mt.session.connectOnionPeer(ep.host, ep.port) catch continue;
                    added += 1;
                },
                .i2p => |ep| {
                    if (mt.session.i2p == null) continue; // needs an I2P route
                    mt.session.connectI2pPeer(ep.host, ep.port) catch continue;
                    added += 1;
                },
            }
        }
    }
    if (added > 0) log.info("transfer {s}: added {d} peers from nostr", .{ mt.id, added });
}

// fetchUrl: download a .torrent over HTTP(S), optionally via proxy. Ported from
// the CLI so the manager doesn't depend on main.zig.
fn fetchUrl(allocator: Allocator, url: []const u8, proxy: ?proxy_mod.Proxy) ![]u8 {
    if (proxy) |px| {
        return proxy_mod.httpGet(allocator, px, url, null) catch return error.HttpFailed;
    }
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    var adapt_buf: [4096]u8 = undefined;
    const dw = body.writer(allocator);
    var adapter = dw.adaptToNewApi(&adapt_buf);
    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &adapter.new_interface,
    }) catch return error.HttpFailed;
    const buffered = adapter.new_interface.buffered();
    if (buffered.len > 0) body.appendSlice(allocator, buffered) catch return error.HttpFailed;
    if (result.status != .ok or body.items.len == 0) return error.HttpFailed;
    return body.toOwnedSlice(allocator);
}

// ===========================================================================
// Tests (pure helpers only — the threaded session path is exercised at runtime)
// ===========================================================================

const testing = std.testing;

test "pctFromCounts" {
    try testing.expectEqual(@as(u8, 0), pctFromCounts(0, 0));
    try testing.expectEqual(@as(u8, 0), pctFromCounts(0, 100));
    try testing.expectEqual(@as(u8, 50), pctFromCounts(50, 100));
    try testing.expectEqual(@as(u8, 100), pctFromCounts(100, 100));
    try testing.expectEqual(@as(u8, 63), pctFromCounts(230, 360)); // truncates (63.8)
    try testing.expectEqual(@as(u8, 100), pctFromCounts(400, 360)); // clamps over-count
}

test "deriveStatus" {
    // deriveStatus(metadata_only, num_pieces, have, mode_is_seed, peers, flowing, grace_elapsed)
    const S = api.Status;
    // Terminal states win regardless of peers/flow.
    try testing.expectEqual(S.seeding, deriveStatus(false, 100, 40, true, 0, false, true));
    try testing.expectEqual(S.complete, deriveStatus(false, 100, 100, false, 0, false, true));
    // Peerless: connecting before the grace window, no_peers after.
    try testing.expectEqual(S.connecting, deriveStatus(true, 0, 0, false, 0, false, false));
    try testing.expectEqual(S.no_peers, deriveStatus(true, 0, 0, false, 0, false, true));
    try testing.expectEqual(S.no_peers, deriveStatus(false, 100, 40, false, 0, false, true));
    // Fetching metadata with peers connected.
    try testing.expectEqual(S.metadata, deriveStatus(true, 0, 0, false, 3, false, true));
    // Have metadata + peers: flowing => downloading, idle => stalled.
    try testing.expectEqual(S.downloading, deriveStatus(false, 100, 40, false, 3, true, true));
    try testing.expectEqual(S.stalled, deriveStatus(false, 100, 40, false, 3, false, true));
}

test "deriveSources: direct uses tracker+dht+nostr" {
    var buf: [3]api.SourceKind = undefined;
    const s = deriveSources(&buf, .direct, true, true);
    try testing.expectEqual(@as(usize, 3), s.len);
    try testing.expectEqual(api.SourceKind.tracker, s[0]);
    try testing.expectEqual(api.SourceKind.dht, s[1]);
    try testing.expectEqual(api.SourceKind.nostr, s[2]);
}

test "deriveSources: direct without tracker drops tracker" {
    var buf: [3]api.SourceKind = undefined;
    const s = deriveSources(&buf, .direct, false, false);
    try testing.expectEqual(@as(usize, 1), s.len);
    try testing.expectEqual(api.SourceKind.dht, s[0]);
}

test "deriveSources: tor with udp-only trackers still shows tracker" {
    var buf: [3]api.SourceKind = undefined;
    const s = deriveSources(&buf, .tor, true, false);
    // UDP trackers are rewritten to HTTP through the proxy, so tracker
    // is a valid source even without explicit HTTP tracker URLs.
    try testing.expectEqual(@as(usize, 1), s.len);
    try testing.expectEqual(api.SourceKind.tracker, s[0]);
}

test "deriveSources: proxy with tracker keeps tracker + nostr" {
    var buf: [3]api.SourceKind = undefined;
    const s = deriveSources(&buf, .proxy, true, true);
    try testing.expectEqual(@as(usize, 2), s.len);
    try testing.expectEqual(api.SourceKind.tracker, s[0]);
    try testing.expectEqual(api.SourceKind.nostr, s[1]);
}

test "deriveSources: i2p reports nostr only when opted in (never tracker)" {
    var buf: [3]api.SourceKind = undefined;
    // HTTP tracker present but never contacted on i2p, and nostr opted in:
    // report nostr only, not tracker.
    const with_nostr = deriveSources(&buf, .i2p, true, true);
    try testing.expectEqual(@as(usize, 1), with_nostr.len);
    try testing.expectEqual(api.SourceKind.nostr, with_nostr[0]);

    // Without nostr there is no peer discovery at all on i2p: report nothing
    // rather than implying a tracker is being used.
    const no_nostr = deriveSources(&buf, .i2p, true, false);
    try testing.expectEqual(@as(usize, 0), no_nostr.len);
}

test "formatEta" {
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("stalled", formatEta(&buf, .stalled, 100, 0));
    try testing.expectEqualStrings("—", formatEta(&buf, .complete, 0, 0));
    try testing.expectEqualStrings("—", formatEta(&buf, .seeding, 0, 5));
    try testing.expectEqualStrings("—", formatEta(&buf, .downloading, 100, 0));
    try testing.expectEqualStrings("10s", formatEta(&buf, .downloading, 1000, 100));
    try testing.expectEqualStrings("1m 40s", formatEta(&buf, .downloading, 10000, 100));
    try testing.expectEqualStrings("2h 46m", formatEta(&buf, .downloading, 1_000_000, 100));
}

test "Manager: dropRetained removes a re-added source so persist can't duplicate it" {
    const allocator = testing.allocator;
    var m = try Manager.init(allocator, .{ .persist = false });
    defer m.deinit();

    try testing.expect(m.retainSpec(.{ .kind = .download, .source = "magnet:?xt=urn:btih:aa", .route = .i2p, .nostr = true }));
    try testing.expect(m.retainSpec(.{ .kind = .seed, .source = "/data/file.bin", .route = .tor, .nostr = false }));
    try testing.expectEqual(@as(usize, 2), m.retained_specs.items.len);

    // The magnet came back (user re-added it / transport recovered): its
    // retained copy must go away or persist() would write it twice and the
    // next restart would run two sessions on the same files.
    m.dropRetained("magnet:?xt=urn:btih:aa");
    try testing.expectEqual(@as(usize, 1), m.retained_specs.items.len);
    try testing.expectEqualStrings("/data/file.bin", m.retained_specs.items[0].source);

    // Unrelated source is a no-op.
    m.dropRetained("magnet:?xt=urn:btih:bb");
    try testing.expectEqual(@as(usize, 1), m.retained_specs.items.len);
}

test "Manager: init/deinit with config defaults" {
    const allocator = testing.allocator;
    // persist=false: setRoute below must not rewrite the real carl.db.
    var m = try Manager.init(allocator, .{ .persist = false });
    defer m.deinit();
    try testing.expectEqualStrings("socks5h://127.0.0.1:9050", m.cfg.socks);
    try testing.expectEqualStrings(".", m.cfg.download_dir);
    try testing.expectEqual(api.Route.direct, m.cfg.route);

    // Empty snapshot under arena.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const snap = try m.snapshot(arena.allocator());
    try testing.expectEqual(@as(usize, 0), snap.len);
    m.setRoute(.tor);
    try testing.expectEqual(api.Route.tor, m.cfg.route);
}
