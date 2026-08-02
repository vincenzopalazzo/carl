//! `carl drive` — shared folders over Nostr ("shared drives").
//!
//! A drive is a FLAT directory (v1: no subdirectories) whose contents are
//! published as one single-file torrent per file — path == filename == torrent
//! name — plus one kind-30035 drive-index event (see drive_index.zig, a NIP-33
//! parameterized replaceable event keyed on pubkey + `carl-drive:<name>`)
//! mapping every path to its torrent's infohash, size, and mtime.
//!
//! Two roles, both embedding ONE `follow.Mirror` for the per-torrent
//! download→seed lifecycle (checkpointing, kind-30078 announces, GUI snapshot
//! all come from there). The embedded mirror's own NIP-35 poll loop is NOT
//! started — the drive loop is the only caller of `startTransfer`/`evictTransfer`:
//!
//!   - publisher (`carl drive create`): scans the folder every
//!     `poll_interval_s`. A new/changed file must be stable across two
//!     consecutive scans, then is hashed with a stat-before/stat-after guard
//!     (a file that moves during hashing is discarded and retried next pass),
//!     checkpointed, seeded via the mirror, and the index is republished with
//!     `created_at = max(now, last + 1)` (persisted in state.json, so the
//!     NIP-33 monotonicity invariant survives restarts). Changed files evict
//!     the old torrent first; deleted files evict + drop their checkpoint.
//!     The user's data files are NEVER deleted by the publisher.
//!   - subscriber (`carl drive subscribe`): polls relays every
//!     `relay_interval_s` for the author's (+ each `--also` writer's) drive
//!     index, keeps only the newest `created_at` per author across all relays
//!     (rejecting regressions vs applied.json — replay defense), merges
//!     authors last-writer-wins per path (highest mtime), and applies
//!     `drive_index.diff`: added/changed → mirror the torrent; removed →
//!     evict + quarantine the local file into `.carl-drive/.trash/` (never
//!     unlink; publisher wins, but a locally-modified file is logged loudly);
//!     renamed → rename the local file and re-mirror under the new name.
//!
//! Restart-safety: per-torrent `.torrent` checkpoints live in
//! `<dir>/.carl-drive/<infohash>.follow.torrent` (the follow.Mirror suffix is
//! reused unchanged — only the subdir differs, via `Mirror.Options
//! .checkpoint_subdir` — so `carl follow`'s on-disk layout is byte-identical
//! to before). The publisher's `state.json` and the subscriber's
//! `applied.json` (both atomic tmp+rename writes) record the file table and
//! the last applied/published `created_at`; on startup each side re-seeds or
//! re-mirrors everything its state file still vouches for.
//!
//! Consumers: the blocking CLI entry (`run`, exits on SIGINT like
//! `follow.run`) and — later — the daemon, via `Drive.create/start/stop/
//! destroy` + `filesSnapshot` (same embedding pattern as follow.Mirror).

const std = @import("std");
const Allocator = std.mem.Allocator;

const api = @import("api.zig");
const drive_index = @import("drive_index.zig");
const follow = @import("follow.zig");
const metainfo_mod = @import("metainfo.zig");
const nostr = @import("nostr.zig");
const nostr_config = @import("nostr_config.zig");
const relay_mod = @import("relay.zig");
const secp = @import("secp.zig");
const session_mod = @import("session.zig");

const log = std.log.scoped(.drive);

pub const Error = error{
    InvalidOptions,
    NoKey,
    UnsupportedRoute,
    ThreadSpawnFailed,
    OutOfMemory,
};

/// Hidden per-drive state directory inside the watched/sync folder. Holds
/// state.json (publisher) / applied.json (subscriber), the `.trash/`
/// quarantine dir, and every per-torrent checkpoint.
pub const state_dirname = ".carl-drive";

/// Quarantine subdirectory for subscriber-side removals (never unlink).
const trash_dirname = ".trash";

pub const Role = enum { publisher, subscriber };

pub const Options = struct {
    role: Role,
    /// Watched folder (publisher) / sync folder (subscriber).
    dir: []const u8,
    /// Drive name (the `<name>` in the `carl-drive:<name>` d-tag).
    drive: []const u8,
    /// Subscriber: the publisher's pubkey (from the npub/hex CLI arg).
    author: ?[32]u8 = null,
    /// Subscriber: extra writer pubkeys (multi-writer, LWW per path).
    also: []const [32]u8 = &.{},
    /// Mirror transport: `direct` or `i2p` (same constraint as `carl follow`).
    route: api.Route = .direct,
    /// Publisher: routable IPv4 for direct-route peer-announces, threaded to
    /// the embedded mirror exactly like `carl follow --external-ip`. Without
    /// it a direct-route publisher still seeds but publishes no dialable
    /// announce, so subscribers can't find it.
    external_ip: ?[4]u8 = null,
    /// Publisher: seconds between folder scans.
    poll_interval_s: u64 = 5,
    /// Subscriber: seconds between relay index polls.
    relay_interval_s: u64 = 15,
    /// v1 cap on drive files (thread/port pressure).
    max_files: usize = 64,
};

/// A snapshot row for one drive file (strings live in the caller's arena).
pub const FileInfo = struct {
    path: []const u8,
    size: u64,
    phase: follow.Phase,
    info_hash_hex: [40]u8,
};

/// One known drive file (publisher's published table, or the subscriber's
/// applied/merged table). `path` is owned by the Drive.
const FileRecord = struct {
    path: []u8,
    info_hash: [20]u8,
    size: u64,
    mtime: i64,
};

/// Publisher-side stability candidate: a new/changed file must be observed
/// with an unchanged (size, mtime) on two consecutive scans before hashing.
const PendingFile = struct {
    path: []u8,
    size: u64,
    mtime: i64,
};

/// Subscriber-side per-author state: the newest applied index per writer.
const AuthorState = struct {
    pubkey: [32]u8,
    created_at: i64,
    files: std.ArrayList(FileRecord),
};

pub const Drive = struct {
    allocator: Allocator,
    /// Owned copies of the caller's option strings/slices (`dir`, `drive`,
    /// `also`), so an embedded drive survives the caller mutating its config.
    opts: Options,
    /// The embedded download→seed engine. `start` is deliberately NOT called
    /// on it: the drive loop replaces follow's NIP-35 poll loop.
    mirror: *follow.Mirror,
    /// Guards `files` (the loop thread writes; `filesSnapshot` reads).
    mutex: std.Thread.Mutex = .{},
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    loop_thread: ?std.Thread = null,
    /// Publisher: the local identity the index is signed with.
    sk: ?secp.SecretKey = null,
    /// Publisher: our pubkey; subscriber: the primary author (mirror label).
    pk: [32]u8 = .{0} ** 32,
    /// Publisher: last published index timestamp (persisted in state.json).
    last_created_at: i64 = 0,
    /// Publisher's published table / subscriber's merged applied table.
    files: std.ArrayList(FileRecord) = .empty,
    /// Publisher only (loop-thread-owned): stability candidates.
    pending: std.ArrayList(PendingFile) = .empty,
    /// Publisher only (loop-thread-owned): names already warned about.
    warned: std.ArrayList([]u8) = .empty,
    /// Subscriber only (loop-thread-owned): per-writer applied indexes.
    authors: std.ArrayList(AuthorState) = .empty,
    /// Subscriber: false until applied.json existed or the first diff landed,
    /// so the very first merge diffs against `null` (everything is `added`).
    has_applied: bool = false,

    /// Heap-allocate a drive with owned copies of the option strings. The
    /// publisher role reads the local Nostr identity up front (an index that
    /// can't be signed is useless), so `NoKey` surfaces before `start`.
    pub fn create(allocator: Allocator, opts: Options) Error!*Drive {
        if (opts.dir.len == 0 or opts.drive.len == 0) return error.InvalidOptions;
        if (opts.role == .subscriber and opts.author == null) return error.InvalidOptions;
        if (opts.route != .direct and opts.route != .i2p) return error.UnsupportedRoute;

        var sk: ?secp.SecretKey = null;
        var pk: [32]u8 = .{0} ** 32;
        switch (opts.role) {
            .publisher => {
                sk = nostr_config.readSecretKey(allocator) catch return error.NoKey;
                pk = secp.publicKeyFromSecret(sk.?) catch return error.NoKey;
            },
            .subscriber => pk = opts.author.?,
        }

        const dir = allocator.dupe(u8, opts.dir) catch return error.OutOfMemory;
        errdefer allocator.free(dir);
        const drive = allocator.dupe(u8, opts.drive) catch return error.OutOfMemory;
        errdefer allocator.free(drive);
        const also = allocator.dupe([32]u8, opts.also) catch return error.OutOfMemory;
        errdefer allocator.free(also);

        const self = allocator.create(Drive) catch return error.OutOfMemory;
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .opts = opts, .mirror = undefined };
        self.opts.dir = dir;
        self.opts.drive = drive;
        self.opts.also = also;
        self.sk = sk;
        self.pk = pk;

        self.mirror = follow.Mirror.create(allocator, .{
            .pubkey = pk,
            .route = opts.route,
            .dir = dir,
            .external_ip = opts.external_ip,
            .max_mirrors = opts.max_files,
            .checkpoint_subdir = state_dirname,
        }) catch return error.OutOfMemory;
        return self;
    }

    /// Start the role's loop on its own thread. Loads the persisted state
    /// first; the loop itself resumes every vouched-for file before scanning.
    pub fn start(self: *Drive) Error!void {
        std.fs.cwd().makePath(self.opts.dir) catch {};
        const state_dir = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.opts.dir, state_dirname }) catch
            return error.OutOfMemory;
        defer self.allocator.free(state_dir);
        std.fs.cwd().makePath(state_dir) catch {};
        if (self.opts.role == .subscriber) {
            const trash = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ state_dir, trash_dirname }) catch
                return error.OutOfMemory;
            defer self.allocator.free(trash);
            std.fs.cwd().makePath(trash) catch {};
        }

        log.info("drive '{s}' ({s}, route {s}) at {s}", .{
            self.opts.drive, @tagName(self.opts.role), @tagName(self.opts.route), self.opts.dir,
        });
        // The mirror publishes its own peer-announces; without a local
        // identity seeds still work but nobody can discover them.
        if (nostr_config.readSecretKey(self.allocator)) |_| {} else |_| {
            log.warn("no nostr identity found; drive seeds won't be announced. Run `carl nostr-keygen` first.", .{});
        }

        switch (self.opts.role) {
            .publisher => self.loadPublisherState(),
            .subscriber => self.loadAppliedState(),
        }

        self.loop_thread = switch (self.opts.role) {
            .publisher => std.Thread.spawn(.{}, publisherLoop, .{self}),
            .subscriber => std.Thread.spawn(.{}, subscriberLoop, .{self}),
        } catch return error.ThreadSpawnFailed;
    }

    /// Request stop and join every thread. The loop thread is joined BEFORE
    /// the mirror is stopped, which serializes `evictTransfer` (called only
    /// from the loop thread) against mirror shutdown. Can block for up to a
    /// relay timeout (~10s/relay) if a poll is mid-flight.
    pub fn stop(self: *Drive) void {
        self.stop_flag.store(true, .release);
        if (self.loop_thread) |t| {
            t.join();
            self.loop_thread = null;
        }
        self.mirror.stop();
    }

    /// Stop (if still running) and free everything.
    pub fn destroy(self: *Drive) void {
        self.stop();
        for (self.files.items) |rec| self.allocator.free(rec.path);
        self.files.deinit(self.allocator);
        for (self.pending.items) |p| self.allocator.free(p.path);
        self.pending.deinit(self.allocator);
        for (self.warned.items) |w| self.allocator.free(w);
        self.warned.deinit(self.allocator);
        for (self.authors.items) |*au| {
            for (au.files.items) |rec| self.allocator.free(rec.path);
            au.files.deinit(self.allocator);
        }
        self.authors.deinit(self.allocator);
        self.mirror.destroy();
        self.allocator.free(self.opts.dir);
        self.allocator.free(self.opts.drive);
        self.allocator.free(self.opts.also);
        self.allocator.destroy(self);
    }

    /// True when this drive (or the whole process) is shutting down.
    pub fn stopping(self: *Drive) bool {
        return self.stop_flag.load(.acquire) or
            session_mod.shutdown_requested.load(.acquire);
    }

    /// Snapshot every known drive file into `arena` (paths duped; phase read
    /// from the embedded mirror's transfer list when one is registered).
    pub fn filesSnapshot(self: *Drive, arena: Allocator) Allocator.Error![]FileInfo {
        const ts = try self.mirror.torrentsSnapshot(arena);
        self.mutex.lock();
        defer self.mutex.unlock();
        const out = try arena.alloc(FileInfo, self.files.items.len);
        for (self.files.items, 0..) |rec, i| {
            var info: FileInfo = .{
                .path = try arena.dupe(u8, rec.path),
                .size = rec.size,
                .phase = if (self.opts.role == .publisher) .seeding else .starting,
                .info_hash_hex = undefined,
            };
            secp.toHex(&rec.info_hash, &info.info_hash_hex);
            for (ts) |t| {
                if (std.mem.eql(u8, &t.hash_hex, &info.info_hash_hex)) {
                    info.phase = t.phase;
                    break;
                }
            }
            out[i] = info;
        }
        return out;
    }

    // ------------------------------------------------------------------
    // Record table (mutex-guarded)
    // ------------------------------------------------------------------

    fn findRecord(self: *Drive, path: []const u8) ?FileRecord {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.files.items) |rec| {
            if (std.mem.eql(u8, rec.path, path)) return rec; // copy; path borrowed
        }
        return null;
    }

    fn recordCount(self: *Drive) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.files.items.len;
    }

    fn upsertRecord(self: *Drive, path: []const u8, info_hash: [20]u8, size: u64, mtime: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.files.items) |*rec| {
            if (std.mem.eql(u8, rec.path, path)) {
                rec.info_hash = info_hash;
                rec.size = size;
                rec.mtime = mtime;
                return;
            }
        }
        const dup = self.allocator.dupe(u8, path) catch return;
        self.files.append(self.allocator, .{
            .path = dup,
            .info_hash = info_hash,
            .size = size,
            .mtime = mtime,
        }) catch self.allocator.free(dup);
    }

    // ------------------------------------------------------------------
    // Publisher-side pending table + warn-once (loop thread only)
    // ------------------------------------------------------------------

    fn pendingMatches(self: *Drive, name: []const u8, size: u64, mtime: i64) bool {
        for (self.pending.items) |p| {
            if (std.mem.eql(u8, p.path, name)) return p.size == size and p.mtime == mtime;
        }
        return false;
    }

    fn pendingSet(self: *Drive, name: []const u8, size: u64, mtime: i64) void {
        for (self.pending.items) |*p| {
            if (std.mem.eql(u8, p.path, name)) {
                p.size = size;
                p.mtime = mtime;
                return;
            }
        }
        const dup = self.allocator.dupe(u8, name) catch return;
        self.pending.append(self.allocator, .{ .path = dup, .size = size, .mtime = mtime }) catch
            self.allocator.free(dup);
    }

    fn pendingClear(self: *Drive, name: []const u8) void {
        for (self.pending.items, 0..) |p, i| {
            if (std.mem.eql(u8, p.path, name)) {
                self.allocator.free(p.path);
                _ = self.pending.orderedRemove(i);
                return;
            }
        }
    }

    fn warnOnce(self: *Drive, name: []const u8, reason: []const u8) void {
        for (self.warned.items) |w| {
            if (std.mem.eql(u8, w, name)) return;
        }
        const dup = self.allocator.dupe(u8, name) catch return;
        self.warned.append(self.allocator, dup) catch {
            self.allocator.free(dup);
            return;
        };
        log.warn("skipping {s}: {s}", .{ name, reason });
    }

    // ------------------------------------------------------------------
    // Checkpoint files (shared naming with the embedded follow.Mirror)
    // ------------------------------------------------------------------

    fn checkpointPath(self: *Drive, a: Allocator, hash: [20]u8) ![]u8 {
        var hex: [40]u8 = undefined;
        secp.toHex(&hash, &hex);
        return std.fmt.allocPrint(a, "{s}/{s}/{s}{s}", .{ self.opts.dir, state_dirname, &hex, follow.torrent_suffix });
    }

    fn checkpointExists(self: *Drive, hash: [20]u8) bool {
        const path = self.checkpointPath(self.allocator, hash) catch return false;
        defer self.allocator.free(path);
        _ = std.fs.cwd().statFile(path) catch return false;
        return true;
    }

    fn writeCheckpoint(self: *Drive, hash: [20]u8, data: []const u8) !void {
        const path = try self.checkpointPath(self.allocator, hash);
        defer self.allocator.free(path);
        try writeFileAtomic(path, data);
    }

    fn deleteCheckpoint(self: *Drive, hash: [20]u8) void {
        const path = self.checkpointPath(self.allocator, hash) catch return;
        defer self.allocator.free(path);
        std.fs.cwd().deleteFile(path) catch {};
    }

    // ------------------------------------------------------------------
    // Publisher
    // ------------------------------------------------------------------

    fn publisherLoop(self: *Drive) void {
        self.publisherResume();
        while (!self.stopping()) {
            self.publisherPass();
            self.sleepInterruptible(self.opts.poll_interval_s);
        }
    }

    /// Re-seed every file state.json still vouches for (same content on disk
    /// AND checkpoint present); anything else is dropped so the normal scan
    /// re-detects it as new/changed.
    fn publisherResume(self: *Drive) void {
        var dropped = false;
        self.mutex.lock();
        var i: usize = 0;
        while (i < self.files.items.len) {
            const rec = self.files.items[i];
            const full = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.opts.dir, rec.path }) catch {
                i += 1;
                continue;
            };
            defer self.allocator.free(full);
            const keep = blk: {
                const st = std.fs.cwd().statFile(full) catch break :blk false;
                if (st.kind != .file) break :blk false;
                if (st.size != rec.size or mtimeSecs(st) != rec.mtime) break :blk false;
                if (!self.checkpointExists(rec.info_hash)) break :blk false;
                break :blk true;
            };
            if (keep) {
                if (!self.mirror.hasInfoHash(rec.info_hash)) {
                    follow.startTransfer(self.mirror, rec.info_hash, rec.path, &.{}) catch |err| {
                        log.warn("could not resume seeding {s}: {}", .{ rec.path, err });
                    };
                }
                i += 1;
            } else {
                self.allocator.free(rec.path);
                _ = self.files.orderedRemove(i);
                dropped = true;
            }
        }
        self.mutex.unlock();
        if (dropped) {
            log.info("some published files changed or vanished while offline; re-detecting", .{});
            self.publishIndex();
        }
    }

    const ScannedFile = struct { name: []const u8, size: u64, mtime: i64 };

    /// Flat scan of the watched dir into `a`: regular files only, skipping
    /// dotfiles (incl. `.carl-drive`), subdirectories (warned once each), and
    /// names that can't be represented in a drive index.
    fn scanDir(self: *Drive, a: Allocator) ![]ScannedFile {
        var out: std.ArrayList(ScannedFile) = .empty;
        var dir = std.fs.cwd().openDir(self.opts.dir, .{ .iterate = true }) catch |err| {
            log.warn("cannot scan drive dir {s}: {}", .{ self.opts.dir, err });
            return err;
        };
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.name.len == 0) continue;
            if (entry.name[0] == '.') continue; // .carl-drive, dotfiles
            if (entry.kind == .directory) {
                self.warnOnce(entry.name, "subdirectory (v1 drives are flat)");
                continue;
            }
            if (entry.kind != .file) {
                self.warnOnce(entry.name, "not a regular file");
                continue;
            }
            drive_index.validatePath(entry.name) catch {
                self.warnOnce(entry.name, "filename cannot be represented in a drive index");
                continue;
            };
            const st = dir.statFile(entry.name) catch continue;
            const dup = a.dupe(u8, entry.name) catch continue;
            out.append(a, .{ .name = dup, .size = st.size, .mtime = mtimeSecs(st) }) catch {
                a.free(dup);
                continue;
            };
        }
        return out.toOwnedSlice(a);
    }

    fn publisherPass(self: *Drive) void {
        var arena_inst = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_inst.deinit();
        const a = arena_inst.allocator();

        const scanned = self.scanDir(a) catch return;

        var dirty = false;

        // Deletions: state records whose file vanished from the folder. The
        // torrent is evicted and its checkpoint dropped; the user's data file
        // is already gone (they deleted it) — we never delete data ourselves.
        {
            var removed: std.ArrayList(FileRecord) = .empty;
            self.mutex.lock();
            var i: usize = 0;
            while (i < self.files.items.len) {
                const rec = self.files.items[i];
                var present = false;
                for (scanned) |s| {
                    if (std.mem.eql(u8, s.name, rec.path)) {
                        present = true;
                        break;
                    }
                }
                if (present) {
                    i += 1;
                    continue;
                }
                removed.append(a, rec) catch {};
                _ = self.files.orderedRemove(i);
            }
            self.mutex.unlock();
            for (removed.items) |rec| {
                log.info("removed from drive: {s}", .{rec.path});
                self.mirror.evictTransfer(rec.info_hash);
                self.deleteCheckpoint(rec.info_hash);
                self.allocator.free(rec.path);
                dirty = true;
            }
        }

        // Additions / content changes.
        var state_dirty = false; // records changed without an index change
        for (scanned) |s| {
            if (self.stopping()) return;
            const existing = self.findRecord(s.name);
            if (existing) |rec| {
                if (rec.size == s.size and rec.mtime == s.mtime) {
                    self.pendingClear(s.name);
                    continue;
                }
            } else if (self.recordCount() >= self.opts.max_files) {
                self.warnOnce(s.name, "drive file cap reached; not publishing");
                continue;
            }

            // Stability check: unchanged across two consecutive scans before
            // we commit to hashing (catches files still being written).
            if (!self.pendingMatches(s.name, s.size, s.mtime)) {
                self.pendingSet(s.name, s.size, s.mtime);
                continue;
            }

            switch (self.hashAndPublish(s, existing != null)) {
                .unchanged => {},
                .touched => state_dirty = true,
                .published => dirty = true,
            }
        }

        if (dirty) {
            self.publishIndex();
        } else if (state_dirty) {
            self.savePublisherState();
        }
    }

    const HashOutcome = enum {
        /// Nothing changed (hash failed or file still unstable).
        unchanged,
        /// mtime-only touch: same infohash, record updated, no republication.
        touched,
        /// New or changed content published (index must be republished).
        published,
    };

    /// Hash one stable file into a torrent, checkpoint it, seed it through
    /// the mirror, and record it.
    fn hashAndPublish(self: *Drive, s: ScannedFile, replacing: bool) HashOutcome {
        const full = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.opts.dir, s.name }) catch return .unchanged;
        defer self.allocator.free(full);

        const st0 = std.fs.cwd().statFile(full) catch return .unchanged;
        const res = metainfo_mod.buildTorrent(self.allocator, full, .{
            .created_by = "carl",
            .creation_date = std.time.timestamp(),
        }) catch |err| {
            log.warn("could not build torrent for {s}: {}", .{ s.name, err });
            self.pendingClear(s.name);
            return .unchanged;
        };
        defer self.allocator.free(res.data);
        const st1 = std.fs.cwd().statFile(full) catch return .unchanged;
        if (st0.size != st1.size or mtimeSecs(st0) != mtimeSecs(st1)) {
            log.info("{s} changed while hashing; retrying next pass", .{s.name});
            self.pendingSet(s.name, st1.size, mtimeSecs(st1));
            return .unchanged;
        }

        var hash_hex: [40]u8 = undefined;
        secp.toHex(&res.info_hash, &hash_hex);

        if (replacing) {
            const old = self.findRecord(s.name).?;
            if (std.mem.eql(u8, &old.info_hash, &res.info_hash)) {
                // mtime-only touch: identical content (a `touch`, or our own
                // download session's storage `setEndPos` bumping the mtime at
                // startup). Adopting the new mtime WITHOUT evicting the
                // transfer is what breaks the feedback loop — evicting here
                // would restart the session, which would bump the mtime
                // again, forever.
                self.upsertRecord(s.name, res.info_hash, st0.size, mtimeSecs(st0));
                self.pendingClear(s.name);
                return .touched;
            }
            // Real content change: evict the old torrent FIRST (and drop its
            // checkpoint); the user's data file is theirs — never touched.
            self.mirror.evictTransfer(old.info_hash);
            self.deleteCheckpoint(old.info_hash);
        }

        self.writeCheckpoint(res.info_hash, res.data) catch |err| {
            log.warn("could not checkpoint torrent for {s}: {}", .{ s.name, err });
            return .unchanged;
        };

        follow.startTransfer(self.mirror, res.info_hash, s.name, &.{}) catch |err| {
            log.warn("could not start seeding {s}: {}", .{ s.name, err });
            return .unchanged;
        };
        self.upsertRecord(s.name, res.info_hash, st0.size, mtimeSecs(st0));
        self.pendingClear(s.name);
        log.info("publishing {s} ({s}, {d} bytes)", .{ s.name, &hash_hex, st0.size });
        return .published;
    }

    /// Arena-owned copy of the record table (null on OOM).
    fn snapshotRecords(self: *Drive, a: Allocator) ?[]FileRecord {
        self.mutex.lock();
        defer self.mutex.unlock();
        const recs = a.alloc(FileRecord, self.files.items.len) catch return null;
        for (self.files.items, 0..) |rec, i| {
            recs[i] = .{
                .path = a.dupe(u8, rec.path) catch return null,
                .info_hash = rec.info_hash,
                .size = rec.size,
                .mtime = rec.mtime,
            };
        }
        return recs;
    }

    /// Persist state.json without touching the index (mtime-only touches).
    fn savePublisherState(self: *Drive) void {
        var arena_inst = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_inst.deinit();
        const a = arena_inst.allocator();
        const recs = self.snapshotRecords(a) orelse return;
        const state_path = std.fmt.allocPrint(a, "{s}/{s}/state.json", .{ self.opts.dir, state_dirname }) catch return;
        writePublisherStateFile(a, state_path, self.last_created_at, recs) catch |err| {
            log.warn("could not save drive state: {}", .{err});
        };
    }

    /// Persist the file table and republish the kind-30035 index with a
    /// strictly-newer `created_at` (max of wall clock and last + 1, so the
    /// NIP-33 monotonicity invariant holds across restarts and clock skew).
    fn publishIndex(self: *Drive) void {
        var arena_inst = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_inst.deinit();
        const a = arena_inst.allocator();

        // Snapshot the record table BEFORE bumping created_at: if the snapshot
        // fails (OOM) we must not have advanced created_at in memory only,
        // which on crash would let a later publish go non-monotonic vs the
        // state file actually written.
        const recs = self.snapshotRecords(a) orelse return;
        self.mutex.lock();
        const created_at = @max(std.time.timestamp(), self.last_created_at + 1);
        self.last_created_at = created_at;
        self.mutex.unlock();

        // State first: even if every relay is down, the bumped created_at is
        // persisted so the next publish is still strictly newer.
        const state_path = std.fmt.allocPrint(a, "{s}/{s}/state.json", .{ self.opts.dir, state_dirname }) catch return;
        writePublisherStateFile(a, state_path, created_at, recs) catch |err| {
            log.warn("could not save drive state: {}", .{err});
        };

        const entries = a.alloc(drive_index.FileEntry, recs.len) catch return;
        for (recs, 0..) |rec, i| {
            entries[i] = .{ .path = rec.path, .info_hash = rec.info_hash, .size = rec.size, .mtime = rec.mtime };
        }
        var ev = drive_index.build(a, self.sk.?, self.pk, self.opts.drive, entries, created_at) catch |err| {
            log.err("could not build drive index: {}", .{err});
            return;
        };
        defer ev.deinit(a);

        const relay_urls = nostr_config.readRelays(a) catch return;
        var acks: usize = 0;
        for (relay_urls) |url| {
            if (self.stopping()) break;
            var r = relay_mod.Relay.connect(a, url, null) catch |err| {
                log.debug("relay {s}: {}", .{ url, err });
                continue;
            };
            defer r.deinit();
            if (relay_mod.publishAndWait(a, &r, ev, 5_000)) acks += 1;
        }
        log.info("index published: {d}/{d} relays", .{ acks, relay_urls.len });
    }

    fn loadPublisherState(self: *Drive) void {
        const a = self.allocator;
        const path = std.fmt.allocPrint(a, "{s}/{s}/state.json", .{ self.opts.dir, state_dirname }) catch return;
        defer a.free(path);
        const loaded = readPublisherStateFile(a, path) catch |err| {
            if (err != error.FileNotFound)
                log.warn("could not read {s}: {} (starting fresh)", .{ path, err });
            return;
        };
        defer a.free(loaded.files);
        for (loaded.files) |rec| {
            self.files.append(a, rec) catch {
                a.free(rec.path);
                continue;
            };
        }
        self.last_created_at = loaded.last_created_at;
        log.info("resumed drive state: {d} file(s), last_created_at {d}", .{ self.files.items.len, self.last_created_at });
    }

    // ------------------------------------------------------------------
    // Subscriber
    // ------------------------------------------------------------------

    fn subscriberLoop(self: *Drive) void {
        self.subscriberResume();
        while (!self.stopping()) {
            self.subscriberPass();
            self.sleepInterruptible(self.opts.relay_interval_s);
        }
    }

    /// Re-mirror everything applied.json vouches for (checkpointed torrents
    /// resume from disk; incomplete ones re-verify existing pieces).
    fn subscriberResume(self: *Drive) void {
        var arena_inst = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_inst.deinit();
        const a = arena_inst.allocator();

        const merged = mergeAuthorFiles(a, self.authors.items) catch return;
        for (merged) |rec| {
            if (self.mirror.hasInfoHash(rec.info_hash)) continue;
            follow.startTransfer(self.mirror, rec.info_hash, rec.path, &.{}) catch |err| {
                log.warn("could not resume mirroring {s}: {}", .{ rec.path, err });
            };
        }
        if (merged.len > 0) log.info("resumed {d} mirrored file(s)", .{merged.len});

        self.mutex.lock();
        for (merged) |rec| {
            const dup = self.allocator.dupe(u8, rec.path) catch continue;
            self.files.append(self.allocator, .{
                .path = dup,
                .info_hash = rec.info_hash,
                .size = rec.size,
                .mtime = rec.mtime,
            }) catch {
                self.allocator.free(dup);
                continue;
            };
        }
        self.has_applied = true;
        self.mutex.unlock();
    }

    /// One relay sweep per writer: collect every relay's copy of the author's
    /// drive index, keep only the newest `created_at` per author, reject
    /// regressions vs applied.json, then merge + apply.
    fn subscriberPass(self: *Drive) void {
        var arena_inst = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_inst.deinit();
        const a = arena_inst.allocator();

        const relay_urls = nostr_config.readRelays(a) catch return;

        var pks: std.ArrayList([32]u8) = .empty;
        pks.append(a, self.opts.author.?) catch return;
        for (self.opts.also) |pk| pks.append(a, pk) catch return;

        var updated = false;
        for (pks.items) |pk| {
            if (self.stopping()) return;
            var best: ?drive_index.Index = null;
            defer if (best) |b| b.deinit(a);

            const d_buf = a.alloc(u8, drive_index.d_prefix.len + self.opts.drive.len) catch return;
            var author_hex: [64]u8 = undefined;
            var kinds_buf: [1]u32 = undefined;
            var authors_buf: [1][]const u8 = undefined;
            var values_buf: [1][]const u8 = undefined;
            var tags_buf: [1]nostr.Filter.TagFilter = undefined;
            const filter = drive_index.indexFilter(pk, self.opts.drive, d_buf, &author_hex, &kinds_buf, &authors_buf, &values_buf, &tags_buf) orelse continue;

            for (relay_urls) |url| {
                if (self.stopping()) return;
                var r = relay_mod.Relay.connect(a, url, null) catch |err| {
                    log.debug("relay {s}: {}", .{ url, err });
                    continue;
                };
                defer r.deinit();
                const events = relay_mod.subscribeAndCollect(a, &r, filter, .{
                    .timeout_ms = 10_000,
                    .max_events = 100,
                    .verify_signatures = true,
                }) catch continue;
                for (events) |ev| {
                    defer ev.deinit(a);
                    // Relay-side filters are untrusted; the signature check
                    // only proves the event matches its *claimed* pubkey.
                    if (!std.mem.eql(u8, &ev.pubkey, &pk)) continue;
                    if (best != null and ev.created_at <= best.?.created_at) continue;
                    const idx = drive_index.parseEvent(a, ev) catch continue;
                    if (best) |b| b.deinit(a);
                    best = idx;
                }
            }

            const idx = best orelse continue;
            if (self.findAuthor(pk)) |au| {
                if (idx.created_at <= au.created_at) {
                    // Replay defense: a regression (or re-delivery of the
                    // applied event) is stale by definition.
                    continue;
                }
            }
            self.replaceAuthorFiles(pk, idx) catch {
                log.warn("out of memory applying drive index", .{});
                return;
            };
            updated = true;
            log.info("new drive index from {s}: {d} file(s), created_at {d}", .{ &author_hex, idx.files.len, idx.created_at });
        }

        if (updated) self.applyMerged();
    }

    fn findAuthor(self: *Drive, pk: [32]u8) ?*AuthorState {
        for (self.authors.items) |*au| {
            if (std.mem.eql(u8, &au.pubkey, &pk)) return au;
        }
        return null;
    }

    /// Adopt a freshly received index as author `pk`'s applied state (copies
    /// the entries into the drive allocator; frees the author's old table).
    fn replaceAuthorFiles(self: *Drive, pk: [32]u8, idx: drive_index.Index) !void {
        var recs: std.ArrayList(FileRecord) = .empty;
        errdefer {
            for (recs.items) |r| self.allocator.free(r.path);
            recs.deinit(self.allocator);
        }
        for (idx.files) |f| {
            const dup = try self.allocator.dupe(u8, f.path);
            errdefer self.allocator.free(dup);
            try recs.append(self.allocator, .{
                .path = dup,
                .info_hash = f.info_hash,
                .size = f.size,
                .mtime = f.mtime,
            });
        }
        if (self.findAuthor(pk)) |au| {
            for (au.files.items) |r| self.allocator.free(r.path);
            au.files.deinit(self.allocator);
            au.files = recs;
            au.created_at = idx.created_at;
        } else {
            try self.authors.append(self.allocator, .{ .pubkey = pk, .created_at = idx.created_at, .files = recs });
        }
    }

    /// Merge all writers' applied indexes (LWW per path), diff against the
    /// currently applied table, and converge: mirror new/changed torrents,
    /// quarantine removals into `.trash/`, rename in place.
    fn applyMerged(self: *Drive) void {
        var arena_inst = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_inst.deinit();
        const a = arena_inst.allocator();

        const merged = mergeAuthorFiles(a, self.authors.items) catch return;
        if (merged.len > self.opts.max_files) {
            log.err("merged drive index has {d} files, over the cap ({d}); refusing to apply", .{ merged.len, self.opts.max_files });
            return;
        }

        // Snapshot the currently applied table (arena-owned).
        self.mutex.lock();
        const old_recs = a.alloc(FileRecord, self.files.items.len) catch {
            self.mutex.unlock();
            return;
        };
        for (self.files.items, 0..) |rec, i| {
            old_recs[i] = .{
                .path = a.dupe(u8, rec.path) catch {
                    self.mutex.unlock();
                    return;
                },
                .info_hash = rec.info_hash,
                .size = rec.size,
                .mtime = rec.mtime,
            };
        }
        const first = !self.has_applied;
        self.mutex.unlock();

        const old_index: drive_index.Index = .{
            .drive = self.opts.drive,
            .files = recsToEntries(a, old_recs) catch return,
            .pubkey = .{0} ** 32,
            .created_at = 0,
            .event_id = .{0} ** 32,
        };
        const new_index: drive_index.Index = .{
            .drive = self.opts.drive,
            .files = recsToEntries(a, merged) catch return,
            .pubkey = .{0} ** 32,
            .created_at = 0,
            .event_id = .{0} ** 32,
        };

        const d = drive_index.diff(a, if (first) null else &old_index, &new_index) catch return;

        // Renames first, while the old paths still exist on disk. (v1 note:
        // the torrent name is bound to the infohash, so a publisher-side
        // rename produces a NEW infohash and surfaces as remove+add; this
        // branch exists for future multi-file/nested layouts.)
        for (d.renamed) |rn| {
            const entry = new_index.find(rn.to) orelse continue;
            self.renameLocal(rn.from, rn.to);
            self.mirror.evictTransfer(entry.info_hash);
            self.startFile(entry);
        }
        for (d.removed) |p| {
            const old_e = old_index.find(p) orelse continue;
            self.mirror.evictTransfer(old_e.info_hash);
            self.deleteCheckpoint(old_e.info_hash);
            self.trashLocal(p, old_e.mtime);
        }
        for (d.changed) |p| {
            const old_e = old_index.find(p) orelse continue;
            self.mirror.evictTransfer(old_e.info_hash);
            self.deleteCheckpoint(old_e.info_hash);
            const entry = new_index.find(p) orelse continue;
            self.startFile(entry);
        }
        for (d.added) |p| {
            const entry = new_index.find(p) orelse continue;
            self.startFile(entry);
        }

        // Adopt the merged table as the applied state and persist it.
        self.mutex.lock();
        for (self.files.items) |rec| self.allocator.free(rec.path);
        self.files.clearRetainingCapacity();
        for (merged) |rec| {
            const dup = self.allocator.dupe(u8, rec.path) catch continue;
            self.files.append(self.allocator, .{
                .path = dup,
                .info_hash = rec.info_hash,
                .size = rec.size,
                .mtime = rec.mtime,
            }) catch {
                self.allocator.free(dup);
                continue;
            };
        }
        self.has_applied = true;
        self.mutex.unlock();

        self.saveAppliedState();
    }

    fn startFile(self: *Drive, entry: *const drive_index.FileEntry) void {
        if (self.mirror.hasInfoHash(entry.info_hash)) return;
        if (self.mirror.count() >= self.opts.max_files) {
            log.err("drive file cap ({d}) reached; skipping {s}", .{ self.opts.max_files, entry.path });
            return;
        }
        var hash_hex: [40]u8 = undefined;
        secp.toHex(&entry.info_hash, &hash_hex);
        follow.startTransfer(self.mirror, entry.info_hash, entry.path, &.{}) catch |err| {
            log.warn("could not start transfer for {s}: {}", .{ entry.path, err });
            return;
        };
        log.info("syncing {s} ({s}, {d} bytes)", .{ entry.path, &hash_hex, entry.size });
    }

    /// Move a removed file into `.carl-drive/.trash/` — never unlink. A
    /// locally-modified file is quarantined too (publisher wins), loudly.
    fn trashLocal(self: *Drive, path: []const u8, recorded_mtime: i64) void {
        const a = self.allocator;
        const src = std.fmt.allocPrint(a, "{s}/{s}", .{ self.opts.dir, path }) catch return;
        defer a.free(src);
        if (std.fs.cwd().statFile(src) catch null) |st| {
            const local_mtime = mtimeSecs(st);
            if (local_mtime != recorded_mtime) {
                log.warn("local file {s} was modified (mtime {d} vs published {d}); quarantining anyway (publisher wins)", .{ path, local_mtime, recorded_mtime });
            }
        }
        const trash = std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ self.opts.dir, state_dirname, trash_dirname }) catch return;
        defer a.free(trash);
        std.fs.cwd().makePath(trash) catch {};
        var dst = std.fmt.allocPrint(a, "{s}/{s}", .{ trash, path }) catch return;
        defer a.free(dst);
        if (std.fs.cwd().statFile(dst) catch null != null) {
            const stamped = std.fmt.allocPrint(a, "{s}.{d}", .{ dst, std.time.timestamp() }) catch return;
            a.free(dst);
            dst = stamped;
        }
        std.fs.cwd().rename(src, dst) catch |err| {
            if (err != error.FileNotFound)
                log.warn("could not quarantine {s}: {}", .{ path, err });
            return;
        };
        log.info("moved {s} to {s} (removed from drive index)", .{ path, trash_dirname });
    }

    fn renameLocal(self: *Drive, from: []const u8, to: []const u8) void {
        const a = self.allocator;
        const src = std.fmt.allocPrint(a, "{s}/{s}", .{ self.opts.dir, from }) catch return;
        defer a.free(src);
        const dst = std.fmt.allocPrint(a, "{s}/{s}", .{ self.opts.dir, to }) catch return;
        defer a.free(dst);
        if (std.fs.path.dirname(dst)) |parent| std.fs.cwd().makePath(parent) catch {};
        std.fs.cwd().rename(src, dst) catch |err| {
            if (err != error.FileNotFound)
                log.warn("could not rename {s} -> {s}: {}", .{ from, to, err });
            return;
        };
        log.info("renamed {s} -> {s}", .{ from, to });
    }

    fn loadAppliedState(self: *Drive) void {
        const a = self.allocator;
        const path = std.fmt.allocPrint(a, "{s}/{s}/applied.json", .{ self.opts.dir, state_dirname }) catch return;
        defer a.free(path);
        const authors = readAppliedStateFile(a, path) catch |err| {
            if (err != error.FileNotFound)
                log.warn("could not read {s}: {} (starting fresh)", .{ path, err });
            return;
        };
        // readAppliedStateFile returns fully-owned AuthorStates; adopt them.
        self.authors = std.ArrayList(AuthorState).fromOwnedSlice(authors);
        self.has_applied = true;
        log.info("resumed applied state: {d} writer(s)", .{self.authors.items.len});
    }

    fn saveAppliedState(self: *Drive) void {
        const a = self.allocator;
        const path = std.fmt.allocPrint(a, "{s}/{s}/applied.json", .{ self.opts.dir, state_dirname }) catch return;
        defer a.free(path);
        writeAppliedStateFile(a, path, self.authors.items) catch |err| {
            log.warn("could not save applied state: {}", .{err});
        };
    }

    // ------------------------------------------------------------------
    // Shared
    // ------------------------------------------------------------------

    fn sleepInterruptible(self: *Drive, secs: u64) void {
        var slept_ms: u64 = 0;
        while (!self.stopping() and slept_ms < secs * 1000) {
            std.Thread.sleep(200 * std.time.ns_per_ms);
            slept_ms += 200;
        }
    }
};

fn sigintHandler(_: i32) callconv(.c) void {
    session_mod.shutdown_requested.store(true, .release);
}

/// Run the drive loop until SIGINT. Blocks. (CLI entry; the daemon embeds
/// `Drive` directly.)
pub fn run(allocator: Allocator, opts: Options) !void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = sigintHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);

    const drive = try Drive.create(allocator, opts);
    defer drive.destroy();
    try drive.start();

    while (!drive.stopping()) {
        std.Thread.sleep(200 * std.time.ns_per_ms);
    }
    log.info("shutting down drive '{s}'...", .{drive.opts.drive});
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

fn mtimeSecs(st: std.fs.File.Stat) i64 {
    return @intCast(@divTrunc(st.mtime, std.time.ns_per_s));
}

/// Merge every writer's file table into one, last-writer-wins per path
/// (strictly highest mtime wins; ties keep the earlier author — the primary
/// author is always first — for determinism). Output paths are duped in `a`.
fn mergeAuthorFiles(a: Allocator, authors: []const AuthorState) ![]FileRecord {
    var out: std.ArrayList(FileRecord) = .empty;
    errdefer {
        for (out.items) |r| a.free(r.path);
        out.deinit(a);
    }
    for (authors) |au| {
        for (au.files.items) |f| {
            var existing: ?*FileRecord = null;
            for (out.items) |*m| {
                if (std.mem.eql(u8, m.path, f.path)) {
                    existing = m;
                    break;
                }
            }
            if (existing) |m| {
                if (f.mtime > m.mtime) {
                    const dup = try a.dupe(u8, f.path);
                    a.free(m.path);
                    m.* = .{
                        .path = dup,
                        .info_hash = f.info_hash,
                        .size = f.size,
                        .mtime = f.mtime,
                    };
                }
            } else {
                const dup = try a.dupe(u8, f.path);
                errdefer a.free(dup);
                try out.append(a, .{ .path = dup, .info_hash = f.info_hash, .size = f.size, .mtime = f.mtime });
            }
        }
    }
    return out.toOwnedSlice(a);
}

fn recsToEntries(a: Allocator, recs: []const FileRecord) ![]drive_index.FileEntry {
    const out = try a.alloc(drive_index.FileEntry, recs.len);
    for (recs, 0..) |rec, i| {
        out[i] = .{ .path = rec.path, .info_hash = rec.info_hash, .size = rec.size, .mtime = rec.mtime };
    }
    return out;
}

/// Write via a temp file + rename so a crash mid-write never leaves a torn
/// state file (a torn state file would wedge the restart path).
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

fn writeJsonStr(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

fn writeFileRecordJson(w: anytype, rec: FileRecord) !void {
    var hex: [40]u8 = undefined;
    secp.toHex(&rec.info_hash, &hex);
    try w.writeAll("{\"path\":");
    try writeJsonStr(w, rec.path);
    try w.print(",\"infohash\":\"{s}\",\"size\":{d},\"mtime\":{d}}}", .{ &hex, rec.size, rec.mtime });
}

// -- state.json (publisher) --

const FileJson = struct {
    path: []const u8,
    infohash: []const u8,
    size: u64 = 0,
    mtime: i64 = 0,
};
const PublisherStateJson = struct {
    last_created_at: i64 = 0,
    files: []FileJson = &.{},
};

fn writePublisherStateFile(a: Allocator, path: []const u8, last_created_at: i64, files: []const FileRecord) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    const w = buf.writer(a);
    try w.print("{{\"last_created_at\":{d},\"files\":[", .{last_created_at});
    for (files, 0..) |rec, i| {
        if (i > 0) try w.writeByte(',');
        try writeFileRecordJson(w, rec);
    }
    try w.writeAll("]}\n");
    try writeFileAtomic(path, buf.items);
}

fn readPublisherStateFile(a: Allocator, path: []const u8) !struct { last_created_at: i64, files: []FileRecord } {
    const data = try std.fs.cwd().readFileAlloc(a, path, 4 * 1024 * 1024);
    defer a.free(data);
    const parsed = try std.json.parseFromSlice(PublisherStateJson, a, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    var out: std.ArrayList(FileRecord) = .empty;
    errdefer {
        for (out.items) |r| a.free(r.path);
        out.deinit(a);
    }
    for (parsed.value.files) |fj| {
        if (fj.infohash.len != 40) return error.InvalidState;
        var hash: [20]u8 = undefined;
        secp.fromHex(fj.infohash, &hash) catch return error.InvalidState;
        const dup = try a.dupe(u8, fj.path);
        errdefer a.free(dup);
        try out.append(a, .{ .path = dup, .info_hash = hash, .size = fj.size, .mtime = fj.mtime });
    }
    return .{ .last_created_at = parsed.value.last_created_at, .files = try out.toOwnedSlice(a) };
}

// -- applied.json (subscriber) --

const AuthorJson = struct {
    pubkey: []const u8,
    created_at: i64 = 0,
    files: []FileJson = &.{},
};
const AppliedJson = struct {
    authors: []AuthorJson = &.{},
};

fn writeAppliedStateFile(a: Allocator, path: []const u8, authors: []const AuthorState) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    const w = buf.writer(a);
    try w.writeAll("{\"authors\":[");
    for (authors, 0..) |au, i| {
        if (i > 0) try w.writeByte(',');
        var pk_hex: [64]u8 = undefined;
        secp.toHex(&au.pubkey, &pk_hex);
        try w.print("{{\"pubkey\":\"{s}\",\"created_at\":{d},\"files\":[", .{ &pk_hex, au.created_at });
        for (au.files.items, 0..) |rec, j| {
            if (j > 0) try w.writeByte(',');
            try writeFileRecordJson(w, rec);
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]}\n");
    try writeFileAtomic(path, buf.items);
}

/// Caller owns the returned slice and everything reachable from it (free each
/// record path, each author's files list, and the outer slice with `a`).
fn readAppliedStateFile(a: Allocator, path: []const u8) ![]AuthorState {
    const data = try std.fs.cwd().readFileAlloc(a, path, 4 * 1024 * 1024);
    defer a.free(data);
    const parsed = try std.json.parseFromSlice(AppliedJson, a, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    var out: std.ArrayList(AuthorState) = .empty;
    errdefer {
        for (out.items) |*au| {
            for (au.files.items) |r| a.free(r.path);
            au.files.deinit(a);
        }
        out.deinit(a);
    }
    for (parsed.value.authors) |aj| {
        if (aj.pubkey.len != 64) return error.InvalidState;
        var pk: [32]u8 = undefined;
        secp.fromHex(aj.pubkey, &pk) catch return error.InvalidState;
        var recs: std.ArrayList(FileRecord) = .empty;
        errdefer {
            for (recs.items) |r| a.free(r.path);
            recs.deinit(a);
        }
        for (aj.files) |fj| {
            if (fj.infohash.len != 40) return error.InvalidState;
            var hash: [20]u8 = undefined;
            secp.fromHex(fj.infohash, &hash) catch return error.InvalidState;
            const dup = try a.dupe(u8, fj.path);
            errdefer a.free(dup);
            try recs.append(a, .{ .path = dup, .info_hash = hash, .size = fj.size, .mtime = fj.mtime });
        }
        try out.append(a, .{ .pubkey = pk, .created_at = aj.created_at, .files = recs });
    }
    return out.toOwnedSlice(a);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn testRecord(a: Allocator, path: []const u8, byte: u8, size: u64, mtime: i64) !FileRecord {
    return .{
        .path = try a.dupe(u8, path),
        .info_hash = .{byte} ** 20,
        .size = size,
        .mtime = mtime,
    };
}

fn freeRecords(a: Allocator, recs: []FileRecord) void {
    for (recs) |r| a.free(r.path);
    a.free(recs);
}

test "publisher state.json round-trips" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);
    const path = try std.fmt.allocPrint(a, "{s}/state.json", .{dir});
    defer a.free(path);

    var recs: std.ArrayList(FileRecord) = .empty;
    defer {
        for (recs.items) |r| a.free(r.path);
        recs.deinit(a);
    }
    try recs.append(a, try testRecord(a, "report.pdf", 0xAB, 12345, 1_700_000_000));
    try recs.append(a, try testRecord(a, "weird \"name\".txt", 0xCD, 7, -5));

    try writePublisherStateFile(a, path, 1_700_000_123, recs.items);

    const loaded = try readPublisherStateFile(a, path);
    defer freeRecords(a, loaded.files);

    try testing.expectEqual(@as(i64, 1_700_000_123), loaded.last_created_at);
    try testing.expectEqual(@as(usize, 2), loaded.files.len);
    try testing.expectEqualStrings("report.pdf", loaded.files[0].path);
    try testing.expectEqualSlices(u8, &(.{0xAB} ** 20), &loaded.files[0].info_hash);
    try testing.expectEqual(@as(u64, 12345), loaded.files[0].size);
    try testing.expectEqual(@as(i64, 1_700_000_000), loaded.files[0].mtime);
    try testing.expectEqualStrings("weird \"name\".txt", loaded.files[1].path);
    try testing.expectEqual(@as(i64, -5), loaded.files[1].mtime);
}

test "applied.json round-trips authors with files" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);
    const path = try std.fmt.allocPrint(a, "{s}/applied.json", .{dir});
    defer a.free(path);

    var authors: std.ArrayList(AuthorState) = .empty;
    defer {
        for (authors.items) |*au| {
            for (au.files.items) |r| a.free(r.path);
            au.files.deinit(a);
        }
        authors.deinit(a);
    }
    var recs: std.ArrayList(FileRecord) = .empty;
    try recs.append(a, try testRecord(a, "a.txt", 1, 10, 100));
    try authors.append(a, .{ .pubkey = .{7} ** 32, .created_at = 42, .files = recs });
    try authors.append(a, .{ .pubkey = .{8} ** 32, .created_at = 7, .files = .empty });

    try writeAppliedStateFile(a, path, authors.items);

    const loaded = try readAppliedStateFile(a, path);
    defer {
        for (loaded) |*au| {
            for (au.files.items) |r| a.free(r.path);
            au.files.deinit(a);
        }
        a.free(loaded);
    }

    try testing.expectEqual(@as(usize, 2), loaded.len);
    try testing.expectEqualSlices(u8, &(.{7} ** 32), &loaded[0].pubkey);
    try testing.expectEqual(@as(i64, 42), loaded[0].created_at);
    try testing.expectEqual(@as(usize, 1), loaded[0].files.items.len);
    try testing.expectEqualStrings("a.txt", loaded[0].files.items[0].path);
    try testing.expectEqualSlices(u8, &(.{1} ** 20), &loaded[0].files.items[0].info_hash);
    try testing.expectEqual(@as(usize, 0), loaded[1].files.items.len);
}

test "mergeAuthorFiles: last-writer-wins per path, ties keep primary" {
    const a = testing.allocator;

    var primary: std.ArrayList(FileRecord) = .empty;
    defer primary.deinit(a);
    try primary.append(a, try testRecord(a, "shared.txt", 1, 10, 100));
    try primary.append(a, try testRecord(a, "only-a.txt", 2, 20, 100));
    var secondary: std.ArrayList(FileRecord) = .empty;
    defer secondary.deinit(a);
    try secondary.append(a, try testRecord(a, "shared.txt", 9, 99, 200)); // newer mtime wins
    try secondary.append(a, try testRecord(a, "tie.txt", 3, 30, 100));
    var tertiary: std.ArrayList(FileRecord) = .empty;
    defer tertiary.deinit(a);
    try tertiary.append(a, try testRecord(a, "tie.txt", 4, 40, 100)); // same mtime: loses

    const authors = [_]AuthorState{
        .{ .pubkey = .{1} ** 32, .created_at = 0, .files = primary },
        .{ .pubkey = .{2} ** 32, .created_at = 0, .files = secondary },
        .{ .pubkey = .{3} ** 32, .created_at = 0, .files = tertiary },
    };
    const merged = try mergeAuthorFiles(a, &authors);
    defer freeRecords(a, merged);
    defer for (authors) |au| {
        for (au.files.items) |r| a.free(r.path);
    };

    try testing.expectEqual(@as(usize, 3), merged.len);
    try testing.expectEqualStrings("shared.txt", merged[0].path);
    try testing.expectEqualSlices(u8, &(.{9} ** 20), &merged[0].info_hash); // LWW
    try testing.expectEqual(@as(u64, 99), merged[0].size);
    try testing.expectEqualStrings("only-a.txt", merged[1].path);
    try testing.expectEqualStrings("tie.txt", merged[2].path);
    try testing.expectEqualSlices(u8, &(.{3} ** 20), &merged[2].info_hash); // tie: earlier author
}

test "Drive create validates options and dupes strings" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);

    // Subscriber without an author is rejected.
    try testing.expectError(error.InvalidOptions, Drive.create(a, .{
        .role = .subscriber,
        .dir = dir,
        .drive = "x",
    }));
    // Empty drive name is rejected.
    try testing.expectError(error.InvalidOptions, Drive.create(a, .{
        .role = .subscriber,
        .dir = dir,
        .drive = "",
        .author = .{7} ** 32,
    }));
    // tor/proxy routes are a follow-up.
    try testing.expectError(error.UnsupportedRoute, Drive.create(a, .{
        .role = .subscriber,
        .dir = dir,
        .drive = "x",
        .author = .{7} ** 32,
        .route = .tor,
    }));

    // A valid subscriber drive: create/destroy alone must not leak or hang.
    const drive = try Drive.create(a, .{
        .role = .subscriber,
        .dir = dir,
        .drive = "x",
        .author = .{7} ** 32,
        .also = &.{.{8} ** 32},
    });
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const snap = try drive.filesSnapshot(arena.allocator());
    try testing.expectEqual(@as(usize, 0), snap.len);
    drive.destroy();
}
