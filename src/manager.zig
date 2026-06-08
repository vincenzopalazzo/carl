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
const extension = @import("extension.zig");
const relay_mod = @import("relay.zig");
const peer_announce = @import("peer_announce.zig");
const seeding = @import("seeding.zig");
const tor_control = @import("tor_control.zig");
const state_mod = @import("state.zig");
const nostr_config = @import("nostr_config.zig");
const nostr_mod = @import("nostr.zig");
const secp = @import("secp.zig");
const api = @import("api.zig");

const log = std.log.scoped(.manager);

pub const Error = error{
    InvalidMagnet,
    InvalidTorrent,
    HttpFailed,
    BadProxy,
    SessionInitFailed,
    /// Failed to stand up the Tor hidden service for a `.tor` seed (Tor
    /// ControlPort unreachable, cookie auth failed, etc.). Fails closed rather
    /// than creating a seed nobody can reach.
    TorControlFailed,
    NotFound,
} || Allocator.Error;

/// Daemon-level configuration mirrored to the Settings screen. String fields
/// are owned; setters free and re-dup.
pub const Config = struct {
    route: api.Route = .direct,
    socks: []const u8 = "",
    download_dir: []const u8 = "",
    listen_port: u16 = 6881,
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
    has_http_tracker: bool,
    /// Owned copy of the socks URL the proxy slices borrow from.
    socks_owned: ?[]u8,
    proxy: ?proxy_mod.Proxy,
    /// Tor hidden service backing a `.tor` seed (the onion leechers dial).
    /// Owned; torn down (DEL_ONION) in `destroy` after the session stops.
    hidden: ?tor_control.HiddenService,
    session: *session_mod.Session,
    meta: metainfo.Metainfo,
    thread: ?std.Thread,
    added_ms: i64,

    // Rate sampling (guarded by Manager.mutex).
    last_down: u64 = 0,
    last_up: u64 = 0,
    last_ms: i64 = 0,
    rate_down: u64 = 0,
    rate_up: u64 = 0,
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
        if (self.socks_owned) |s| self.allocator.free(s);
        self.allocator.free(self.id);
        self.allocator.free(self.name);
        self.allocator.free(self.magnet);
        self.allocator.free(self.source);
        self.allocator.destroy(self);
    }
};

pub const Manager = struct {
    allocator: Allocator,
    mutex: std.Thread.Mutex = .{},
    transfers: std.ArrayList(*ManagedTransfer) = .empty,
    next_id: usize = 1,
    cfg: Config,
    /// While replaying persisted state on startup, suppress per-add persistence
    /// (we write once at the end of `restore`).
    restoring: bool = false,

    pub fn init(allocator: Allocator, cfg: Config) Allocator.Error!Manager {
        return .{
            .allocator = allocator,
            .cfg = .{
                .route = cfg.route,
                .socks = try allocator.dupe(u8, if (cfg.socks.len > 0) cfg.socks else "socks5h://127.0.0.1:9050"),
                .download_dir = try allocator.dupe(u8, if (cfg.download_dir.len > 0) cfg.download_dir else "."),
                .listen_port = cfg.listen_port,
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
        for (self.transfers.items) |mt| mt.destroy();
        self.transfers.deinit(self.allocator);
        self.allocator.free(self.cfg.socks);
        self.allocator.free(self.cfg.download_dir);
        self.allocator.free(self.cfg.tor_control);
        self.allocator.free(self.cfg.tor_cookie);
    }

    // -----------------------------------------------------------------------
    // Mutations
    // -----------------------------------------------------------------------

    /// Add a transfer from a magnet URI, .torrent path, or HTTP(S) URL on the
    /// given route. Spawns the session thread. Returns the new transfer id
    /// (owned by the caller).
    pub fn addTransfer(self: *Manager, source: []const u8, route: api.Route, want_nostr: bool) Error![]u8 {
        // Each transfer owns the socks URL its Proxy slices borrow from, so a
        // later `setRoute`/config change can't dangle a running transfer.
        var socks_owned: ?[]u8 = null;
        var resolved_proxy: ?proxy_mod.Proxy = null;
        if (route != .direct) {
            const dup = try self.allocator.dupe(u8, self.cfg.socks);
            socks_owned = dup;
            resolved_proxy = proxy_mod.parseUrl(dup) catch {
                self.allocator.free(dup);
                return error.BadProxy;
            };
        }

        std.fs.cwd().makePath(self.cfg.download_dir) catch {};

        const built = self.buildSession(source, resolved_proxy) catch |err| {
            if (socks_owned) |s| self.allocator.free(s);
            return err;
        };
        const magnet = if (std.mem.startsWith(u8, source, "magnet:")) source else "";
        return self.register(built, route, resolved_proxy, socks_owned, null, want_nostr, false, magnet, source);
    }

    /// Create a torrent from a local file (or archive) and start seeding it. The
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

    /// file is hashed in-process — carl needs no external torrent tool. With
    /// `want_nostr`, a NIP-35 torrent event is published so it's discoverable.
    pub fn addSeed(self: *Manager, path: []const u8, route: api.Route, want_nostr: bool) Error![]u8 {
        var socks_owned: ?[]u8 = null;
        var resolved_proxy: ?proxy_mod.Proxy = null;
        if (route != .direct) {
            const dup = try self.allocator.dupe(u8, self.cfg.socks);
            socks_owned = dup;
            resolved_proxy = proxy_mod.parseUrl(dup) catch {
                self.allocator.free(dup);
                return error.BadProxy;
            };
        }

        const mi = metainfo.createSingleFile(self.allocator, path, metainfo.default_piece_length) catch |e| {
            if (socks_owned) |s| self.allocator.free(s);
            return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidTorrent,
            };
        };
        // Seed from the file's own directory so storage resolves it by name.
        const data_dir = std.fs.path.dirname(path) orelse ".";

        // Tor route: stand up a v3 hidden service so leechers can actually reach
        // this seed, and run the session as a loopback hidden-service seed (no
        // outbound proxy, tracker/DHT suppressed) — the same wiring as the CLI's
        // `carl seed --tor-seed`. The resolved SOCKS proxy stays as the
        // transfer's `proxy` so `publishSeedNostr` publishes the onion announce
        // over Tor; the session itself takes no proxy (inbound-only via the onion).
        // Fails closed (`TorControlFailed`) rather than creating an unreachable seed.
        var hidden: ?tor_control.HiddenService = null;
        var session_proxy = resolved_proxy;
        var listen_bind: session_mod.ListenBind = .any;
        var tor_hidden = false;
        var seed_port = self.cfg.listen_port;
        if (route == .tor) {
            // Give each tor seed its own loopback port so concurrent tor seeds
            // don't collide on cfg.listen_port. The onion forwards to this port.
            seed_port = self.pickLoopbackPort() orelse self.cfg.listen_port;
            hidden = tor_control.addOnion(self.allocator, .{
                .control_addr = self.cfg.tor_control,
                .cookie_path = if (self.cfg.tor_cookie.len > 0) self.cfg.tor_cookie else null,
                .local_port = seed_port,
                .onion_port = self.cfg.tor_onion_port,
            }) catch {
                if (socks_owned) |s| self.allocator.free(s);
                mi.deinit(self.allocator);
                return error.TorControlFailed;
            };
            session_proxy = null;
            listen_bind = .loopback;
            tor_hidden = true;
        }

        const session = self.allocator.create(session_mod.Session) catch {
            if (socks_owned) |s| self.allocator.free(s);
            if (hidden) |*h| h.deinit();
            mi.deinit(self.allocator);
            return error.OutOfMemory;
        };
        session.* = session_mod.Session.init(self.allocator, mi, data_dir, .seed, seed_port, session_proxy, listen_bind, tor_hidden) catch {
            if (socks_owned) |s| self.allocator.free(s);
            if (hidden) |*h| h.deinit();
            self.allocator.destroy(session);
            mi.deinit(self.allocator);
            return error.SessionInitFailed;
        };
        // A tor seed whose listener didn't bind is unreachable behind its onion
        // (e.g. a port race). Surface it rather than silently half-seeding.
        if (route == .tor and session.listener == null) {
            log.warn("tor seed: listener failed to bind 127.0.0.1:{d}; the onion will be unreachable", .{seed_port});
        }
        const built = Built{ .session = session, .meta = mi, .info_hash = session.info_hash, .name = mi.name };

        var hex: [40]u8 = undefined;
        secp.toHex(&session.info_hash, &hex);
        const magnet = std.fmt.allocPrint(self.allocator, "magnet:?xt=urn:btih:{s}&dn={s}", .{ hex, mi.name }) catch {
            if (socks_owned) |s| self.allocator.free(s);
            if (hidden) |*h| h.deinit();
            session.deinit();
            self.allocator.destroy(session);
            mi.deinit(self.allocator);
            return error.OutOfMemory;
        };
        defer self.allocator.free(magnet);

        return self.register(built, route, resolved_proxy, socks_owned, hidden, want_nostr, true, magnet, path);
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
        hidden: ?tor_control.HiddenService,
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
            .has_http_tracker = std.mem.startsWith(u8, built.meta.announce, "http"),
            .socks_owned = socks_owned,
            .proxy = resolved_proxy,
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
        self.mutex.unlock();

        // Spawn after publishing so a snapshot taken mid-spawn sees the row.
        mt.thread = std.Thread.spawn(.{}, runThread, .{mt}) catch {
            // Roll back: remove from the list and destroy (frees `id` too, so we
            // must not touch it afterward on this path).
            _ = self.removeTransfer(id) catch {};
            return error.SessionInitFailed;
        };

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
                .onion = if (mt.hidden) |h| try arena.dupe(u8, h.onion_host) else null,
                .size = p.total_length,
                .up_total = p.uploaded,
                .up = mt.rate_up,
                .leechers = 0,
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
        if (self.restoring) return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        self.mutex.lock();
        const route = self.cfg.route;
        const dir = aa.dupe(u8, self.cfg.download_dir) catch {
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
        self.mutex.unlock();

        state_mod.save(self.allocator, route, dir, specs.items) catch |e| {
            log.warn("failed to persist daemon state: {}", .{e});
        };
    }

    /// Replay persisted state on startup: apply settings and re-add every
    /// transfer/seed. Downloads resume from on-disk pieces; seeds re-hash their
    /// file. Call once, before serving. Blocking.
    pub fn restore(self: *Manager) void {
        const st = (state_mod.load(self.allocator) catch |e| {
            log.warn("failed to load daemon state: {}", .{e});
            return;
        }) orelse return;
        defer st.deinit(self.allocator);

        self.mutex.lock();
        self.cfg.route = st.route;
        // Treat "." (the bare placeholder default) as "unset" so a stale
        // persisted "." doesn't clobber an explicit --download-dir passed on
        // startup (e.g. the desktop shell's ~/Downloads/carl-download).
        if (st.download_dir.len > 0 and !std.mem.eql(u8, st.download_dir, ".")) {
            if (self.allocator.dupe(u8, st.download_dir)) |d| {
                self.allocator.free(self.cfg.download_dir);
                self.cfg.download_dir = d;
            } else |_| {}
        }
        self.mutex.unlock();
        std.fs.cwd().makePath(self.cfg.download_dir) catch {};

        self.restoring = true;
        var restored: usize = 0;
        var failed: usize = 0;
        for (st.transfers) |t| {
            const res = switch (t.kind) {
                .download => self.addTransfer(t.source, t.route, t.nostr),
                .seed => self.addSeed(t.source, t.route, t.nostr),
            };
            if (res) |id| {
                self.allocator.free(id);
                restored += 1;
            } else |e| {
                failed += 1;
                log.warn("restore: could not re-add '{s}': {} (keeping it on disk)", .{ t.source, e });
            }
        }
        self.restoring = false;
        // Only re-persist when every saved transfer came back. `persist` rewrites
        // the DB purely from the live set, so persisting after a failure would
        // permanently delete the dropped specs — e.g. a `tor` seed whose hidden
        // service couldn't be created because Tor wasn't up yet at restart. Leave
        // the on-disk state intact so the next restart retries them.
        if (failed == 0) {
            self.persist();
        } else {
            log.warn("restore: {d} transfer(s) didn't come back; leaving saved state intact for retry", .{failed});
        }
        if (restored > 0) log.info("restored {d} transfer(s) from saved state", .{restored});
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
            // Name the file by info-hash (safe; the display name may contain /).
            const path = std.fmt.allocPrint(self.allocator, "{s}/{s}.carl.torrent", .{ self.cfg.download_dir, &mt.hash_hex }) catch continue;
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

    fn buildSession(self: *Manager, source: []const u8, proxy: ?proxy_mod.Proxy) Error!Built {
        if (std.mem.startsWith(u8, source, "magnet:")) return self.buildMagnet(source, proxy);
        if (std.mem.startsWith(u8, source, "http://") or std.mem.startsWith(u8, source, "https://"))
            return self.buildHttp(source, proxy);
        return self.buildFile(source, proxy);
    }

    fn buildFile(self: *Manager, path: []const u8, proxy: ?proxy_mod.Proxy) Error!Built {
        const data = std.fs.cwd().readFileAlloc(self.allocator, path, 10 * 1024 * 1024) catch return error.InvalidTorrent;
        defer self.allocator.free(data);
        const mi = metainfo.parse(self.allocator, data) catch return error.InvalidTorrent;
        return self.fromMetainfo(mi, proxy);
    }

    fn buildHttp(self: *Manager, url: []const u8, proxy: ?proxy_mod.Proxy) Error!Built {
        const data = fetchUrl(self.allocator, url, proxy) catch return error.HttpFailed;
        defer self.allocator.free(data);
        const mi = metainfo.parse(self.allocator, data) catch return error.InvalidTorrent;
        return self.fromMetainfo(mi, proxy);
    }

    fn fromMetainfo(self: *Manager, mi: metainfo.Metainfo, proxy: ?proxy_mod.Proxy) Error!Built {
        // On a failed Session.init the metainfo is ours to free (it only becomes
        // the session's on success); mirrors the magnet path's errdefer.
        errdefer mi.deinit(self.allocator);
        const session = self.allocator.create(session_mod.Session) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(session);
        session.* = session_mod.Session.init(self.allocator, mi, self.cfg.download_dir, .download, self.cfg.listen_port, proxy, .any, false) catch {
            return error.SessionInitFailed;
        };
        return .{ .session = session, .meta = mi, .info_hash = session.info_hash, .name = mi.name };
    }

    /// Build a metadata-only session from a magnet link (BEP 9 bootstrap),
    /// mirroring the CLI's magnet path minus the optional NIP-35 enrichment.
    fn buildMagnet(self: *Manager, uri: []const u8, proxy: ?proxy_mod.Proxy) Error!Built {
        const ml = magnet_mod.parse(self.allocator, uri) catch return error.InvalidMagnet;
        defer ml.deinit(self.allocator);
        const a = self.allocator;

        const mi = try buildMagnetMetainfo(a, ml);
        errdefer mi.deinit(a);

        const session = a.create(session_mod.Session) catch return error.OutOfMemory;
        errdefer a.destroy(session);
        session.* = session_mod.Session.init(a, mi, self.cfg.download_dir, .download, self.cfg.listen_port, proxy, .any, false) catch {
            return error.SessionInitFailed;
        };
        session.info_hash = ml.info_hash; // use the magnet's hash, not SHA1("")
        session.metadata_download = extension.MetadataDownload.init(a, ml.info_hash);
        session.metadata_only = true;
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
fn snapshotTransfer(mt: *ManagedTransfer, arena: Allocator, now: i64) Allocator.Error!api.Transfer {
    const p = mt.session.progressSnapshot();

    // Rate sampling: bytes since the last snapshot over elapsed milliseconds.
    const dt = now - mt.last_ms;
    if (mt.last_ms != 0 and dt > 0) {
        const dd = p.downloaded -| mt.last_down;
        const du = p.uploaded -| mt.last_up;
        const dt_ms: u64 = @intCast(dt);
        mt.rate_down = @intCast(@as(u128, dd) * 1000 / dt_ms);
        mt.rate_up = @intCast(@as(u128, du) * 1000 / dt_ms);
    }
    mt.last_down = p.downloaded;
    mt.last_up = p.uploaded;
    mt.last_ms = now;

    const made_progress = mt.rate_down > 0;
    const status = deriveStatus(p.metadata_only, p.num_pieces, p.have, p.mode == .seed, made_progress);
    const pct = pctFromCounts(p.have, p.num_pieces);

    var src_buf: [3]api.SourceKind = undefined;
    const src = deriveSources(&src_buf, mt.route, mt.has_tracker, mt.has_http_tracker, mt.want_nostr);
    const sources = try arena.dupe(api.SourceKind, src);

    var eta_buf: [24]u8 = undefined;
    const remaining: u64 = if (p.total_length > 0 and pct < 100)
        p.total_length - (p.total_length * pct / 100)
    else
        0;
    const eta = try arena.dupe(u8, formatEta(&eta_buf, status, remaining, mt.rate_down));

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
        .down = mt.rate_down,
        .up = mt.rate_up,
        .eta = eta,
        .peers = p.peers,
        .seeds = 0,
        .ratio = if (status == .seeding or status == .complete) ratio else null,
        .onion = null,
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

pub fn deriveStatus(metadata_only: bool, num_pieces: u32, have: u32, mode_is_seed: bool, made_progress: bool) api.Status {
    if (metadata_only and num_pieces == 0) return .metadata;
    const complete = num_pieces > 0 and have >= num_pieces;
    if (mode_is_seed) return .seeding;
    if (complete) return .complete;
    if (!made_progress) return .stalled;
    return .downloading;
}

/// Fill `out` with the sources for a route and return the used slice.
pub fn deriveSources(
    out: *[3]api.SourceKind,
    route: api.Route,
    has_tracker: bool,
    has_http_tracker: bool,
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
            // Proxied: DHT and UDP trackers are disabled to avoid IP leaks.
            if (has_http_tracker) {
                out[n] = .tracker;
                n += 1;
            }
            if (want_nostr or n == 0) {
                out[n] = .nostr;
                n += 1;
            }
        },
    }
    return out[0..n];
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
        if (mt.is_seed) publishSeedNostr(mt) else collectNostrPeers(mt);
    }
    mt.session.run() catch |err| {
        log.err("transfer {s}: session error: {}", .{ mt.id, err });
    };
}

/// Publish a seed's Nostr events via the shared `seeding.publish` (the same path
/// the CLI `carl seed` uses). A `.tor` seed has a hidden service, so it also
/// publishes a kind-30078 onion peer-announce — what a Tor leecher needs to dial
/// it — over Tor (via `mt.proxy`). Other seeds publish only NIP-35 discovery
/// metadata (no routable endpoint to announce). Best-effort.
fn publishSeedNostr(mt: *ManagedTransfer) void {
    const ann: seeding.Announce = if (mt.hidden) |h|
        .{ .onion = .{ .host = h.onion_host, .port = h.onion_port } }
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
            const ann = peer_announce.parse(ev) catch continue;
            if (!std.mem.eql(u8, &ann.info_hash, &mt.info_hash)) continue;
            if (added >= 50) break;
            switch (ann.endpoint) {
                .ipv4 => |ep| {
                    const addr = std.net.Address.initIp4(ep.ip, ep.port);
                    mt.session.connectDirectPeer(addr) catch continue;
                    added += 1;
                },
                .onion => |ep| {
                    if (mt.session.proxy == null) continue;
                    mt.session.connectOnionPeer(ep.host, ep.port) catch continue;
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
    try testing.expectEqual(api.Status.metadata, deriveStatus(true, 0, 0, false, false));
    try testing.expectEqual(api.Status.complete, deriveStatus(false, 100, 100, false, false));
    try testing.expectEqual(api.Status.seeding, deriveStatus(false, 100, 100, true, false));
    try testing.expectEqual(api.Status.seeding, deriveStatus(false, 100, 40, true, false));
    try testing.expectEqual(api.Status.downloading, deriveStatus(false, 100, 40, false, true));
    try testing.expectEqual(api.Status.stalled, deriveStatus(false, 100, 40, false, false));
}

test "deriveSources: direct uses tracker+dht+nostr" {
    var buf: [3]api.SourceKind = undefined;
    const s = deriveSources(&buf, .direct, true, true, true);
    try testing.expectEqual(@as(usize, 3), s.len);
    try testing.expectEqual(api.SourceKind.tracker, s[0]);
    try testing.expectEqual(api.SourceKind.dht, s[1]);
    try testing.expectEqual(api.SourceKind.nostr, s[2]);
}

test "deriveSources: direct without tracker drops tracker" {
    var buf: [3]api.SourceKind = undefined;
    const s = deriveSources(&buf, .direct, false, false, false);
    try testing.expectEqual(@as(usize, 1), s.len);
    try testing.expectEqual(api.SourceKind.dht, s[0]);
}

test "deriveSources: tor falls back to nostr only" {
    var buf: [3]api.SourceKind = undefined;
    const s = deriveSources(&buf, .tor, true, false, false);
    // http tracker absent + want_nostr false => nostr fallback (n==0 branch)
    try testing.expectEqual(@as(usize, 1), s.len);
    try testing.expectEqual(api.SourceKind.nostr, s[0]);
}

test "deriveSources: proxy with http tracker keeps tracker + nostr" {
    var buf: [3]api.SourceKind = undefined;
    const s = deriveSources(&buf, .proxy, true, true, true);
    try testing.expectEqual(@as(usize, 2), s.len);
    try testing.expectEqual(api.SourceKind.tracker, s[0]);
    try testing.expectEqual(api.SourceKind.nostr, s[1]);
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

test "Manager: init/deinit with config defaults" {
    const allocator = testing.allocator;
    var m = try Manager.init(allocator, .{});
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
