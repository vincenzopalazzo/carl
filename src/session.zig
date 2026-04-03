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

const max_peers: usize = 50;
const unchoke_slots: usize = 4;
const unchoke_interval_secs: i64 = 10;
const optimistic_interval_secs: i64 = 30;

/// Global flag for graceful shutdown on SIGINT.
var shutdown_requested: bool = false;

fn sigintHandler(_: i32) callconv(.c) void {
    shutdown_requested = true;
}

pub const Mode = enum { download, seed };

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

    // Choking state
    last_unchoke_time: i64,
    last_optimistic_time: i64,
    optimistic_peer: ?*peer_mod.PeerConnection,

    // Endgame mode
    endgame_active: bool,

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
    ) !Session {
        const total_length = piece_mod.totalLength(meta.files);
        const num_pieces = piece_mod.numPieces(total_length, meta.piece_length);
        const info_hash = metainfo.infoHash(meta.raw_info);

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

        var listener: ?std.net.Server = null;
        if (mode == .seed or our_bitfield.count() > 0) {
            const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, listen_port);
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
            .mode = mode,
            .tracker_interval = 1800,
            .last_announce_time = 0,
            .uploaded = 0,
            .downloaded = 0,
            .total_length = total_length,
            .piece_len = meta.piece_length,
            .num_pieces = num_pieces,
            .running = true,
            .last_unchoke_time = now,
            .last_optimistic_time = now,
            .optimistic_peer = null,
            .endgame_active = false,
            .start_time = now,
            .last_progress_time = now,
            .last_progress_bytes = 0,
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

        if (self.listener) |*l| l.deinit();
        self.our_bitfield.deinit(self.allocator);
        self.store.deinit();
    }

    pub fn run(self: *Session) !void {
        const stdout = std.fs.File.stdout().deprecatedWriter();
        const stderr = std.fs.File.stderr().deprecatedWriter();

        const act = std.posix.Sigaction{
            .handler = .{ .handler = sigintHandler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);

        // Multi-tracker announce (BEP 12)
        stderr.print("announcing to tracker...\n", .{}) catch {};
        self.doMultiTrackerAnnounce(.started) catch |err| {
            stderr.print("all trackers failed: {}\n", .{err}) catch {};
        };

        stdout.print("session started: {d} pieces, {d} bytes\n", .{ self.num_pieces, self.total_length }) catch {};

        while (self.running and !shutdown_requested) {
            if (self.mode == .download and self.our_bitfield.isComplete()) {
                stdout.print("\ndownload complete!\n", .{}) catch {};
                self.doMultiTrackerAnnounce(.completed) catch {};
                if (self.listener == null) {
                    const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, self.listen_port);
                    self.listener = addr.listen(.{ .reuse_address = true }) catch null;
                }
                self.mode = .seed;
                stdout.print("now seeding on port {d}...\n", .{self.listen_port}) catch {};
            }

            var fds: [max_peers + 1]std.posix.pollfd = undefined;
            const nfds = self.buildPollFds(&fds);

            _ = std.posix.poll(fds[0..nfds], 1000) catch 0;

            self.processPollResults(fds[0..nfds]) catch {};

            // Check endgame activation
            if (self.mode == .download and !self.endgame_active) {
                self.checkEndgame();
            }

            self.scheduleRequests() catch {};
            self.maintenance() catch {};
        }

        if (shutdown_requested) {
            stderr.print("\nshutting down gracefully...\n", .{}) catch {};
        }
        self.doMultiTrackerAnnounce(.stopped) catch {};
        stderr.print("sent stopped announce to tracker\n", .{}) catch {};
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
            if (p.wantsSend()) events |= std.posix.POLL.OUT;

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
                p.disconnect();
                fd_idx += 1;
                continue;
            }

            if (revents & std.posix.POLL.IN != 0) {
                _ = p.readIncoming() catch {
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

                        if (self.our_bitfield.count() > 0) {
                            p.enqueueMessage(.{ .bitfield = self.our_bitfield.rawBytes() }) catch {};
                        }

                        if (self.mode == .download) {
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
                p.clearPendingRequests();
            },
            .unchoke => {
                p.peer_choking = false;
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
                if (p.peer_bitfield) |*bf| {
                    // Remove old availability counts
                    self.removeAvailability(bf);
                    bf.deinit(self.allocator);
                }
                p.peer_bitfield = piece_mod.Bitfield.fromRaw(self.allocator, data, self.num_pieces) catch null;
                if (p.peer_bitfield) |*bf| {
                    self.addAvailability(bf);
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
        }
    }

    fn onBlockReceived(self: *Session, p: *peer_mod.PeerConnection, pd: wire.Message.PieceData) !void {
        p.completePendingRequest(pd.index, pd.begin);
        p.bytes_downloaded += pd.block.len;

        const pp_ptr = self.active_pieces.get(pd.index) orelse return;
        const complete = pp_ptr.addBlock(pd.begin, pd.block);

        if (complete) {
            const hash = piece_mod.pieceHash(self.meta.pieces, pd.index) orelse return;

            if (piece_mod.verifyPiece(pp_ptr.data, hash)) {
                self.store.writePiece(pd.index, pp_ptr.data) catch {};
                self.our_bitfield.setPiece(pd.index);
                self.downloaded += pp_ptr.piece_len;

                self.printProgress() catch {};

                for (self.peers.items) |peer| {
                    if (peer.state == .active) {
                        peer.enqueueMessage(.{ .have = pd.index }) catch {};
                    }
                }
            } else {
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
        if (req.begin + req.length > plen) return;

        const data = self.store.readPiece(self.allocator, req.index, plen) catch return;
        defer self.allocator.free(data);

        const block = data[req.begin .. req.begin + req.length];
        p.enqueueMessage(.{ .piece = .{
            .index = req.index,
            .begin = req.begin,
            .block = block,
        } }) catch {};

        self.uploaded += req.length;
        p.bytes_uploaded += req.length;
    }

    // --- Piece selection: rarest-first ---

    fn scheduleRequests(self: *Session) !void {
        if (self.mode != .download) return;

        for (self.peers.items) |p| {
            if (p.state != .active) continue;

            while (p.canRequest()) {
                const piece_idx = if (self.endgame_active)
                    self.pickEndgamePiece(p)
                else
                    self.pickRarestPiece(p);

                const idx = piece_idx orelse break;

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

                const block_idx = pp_ptr.nextMissingBlock() orelse break;
                const spec = pp_ptr.blockSpec(block_idx);

                const req = wire.Message.BlockRequest{
                    .index = idx,
                    .begin = spec.begin,
                    .length = spec.length,
                };

                p.enqueueMessage(.{ .request = req }) catch break;
                p.addPendingRequest(req) catch break;
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

            // Skip if already active and fully requested
            if (self.active_pieces.get(idx)) |pp| {
                if (pp.nextMissingBlock() == null) continue;
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

    /// In endgame mode, request remaining blocks from ALL peers that have them.
    fn pickEndgamePiece(self: *Session, p: *peer_mod.PeerConnection) ?u32 {
        for (0..self.num_pieces) |i| {
            const idx: u32 = @intCast(i);
            if (self.our_bitfield.hasPiece(idx)) continue;
            if (!p.hasPiece(idx)) continue;

            if (self.active_pieces.get(idx)) |pp| {
                if (pp.nextMissingBlock() != null) return idx;
                // In endgame, also re-request blocks from other peers
                // (the first response wins, duplicates are ignored)
                return idx;
            }
        }
        return null;
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

        // Sort by bytes_downloaded descending (they upload to us the most)
        const slice = interested_peers[0..count];
        std.mem.sort(*peer_mod.PeerConnection, slice, {}, struct {
            fn cmp(_: void, a: *peer_mod.PeerConnection, b: *peer_mod.PeerConnection) bool {
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

        // Remove disconnected peers and update availability
        var i: usize = 0;
        while (i < self.peers.items.len) {
            const p = self.peers.items[i];
            if (p.state == .disconnected) {
                if (p.peer_bitfield) |*bf| {
                    self.removeAvailability(bf);
                }
                p.deinit();
                self.allocator.destroy(p);
                _ = self.peers.orderedRemove(i);
            } else {
                if (now - p.last_send_time > 60) {
                    p.enqueueMessage(.keep_alive) catch {};
                }
                if (now - p.last_recv_time > 120) {
                    p.disconnect();
                }
                i += 1;
            }
        }

        // Run choking algorithm
        self.runChokingAlgorithm();

        // Re-announce
        const interval_secs = std.math.cast(i64, self.tracker_interval) orelse 1800;
        if (now - self.last_announce_time > interval_secs) {
            self.doMultiTrackerAnnounce(.none) catch {};
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

        // Try announce-list tiers first (BEP 12)
        if (self.meta.announce_list) |tiers| {
            for (tiers) |tier| {
                for (tier) |url| {
                    if (self.tryAnnounceUrl(url, req)) |resp| {
                        self.handleAnnounceResponse(resp);
                        return;
                    }
                }
            }
        }

        // Fall back to primary announce URL
        if (self.tryAnnounceUrl(self.meta.announce, req)) |resp| {
            self.handleAnnounceResponse(resp);
            return;
        }

        return error.TrackerFailed;
    }

    fn tryAnnounceUrl(self: *Session, url: []const u8, req: tracker_mod.AnnounceRequest) ?tracker_mod.AnnounceResponse {
        if (std.mem.startsWith(u8, url, "udp://")) {
            return udp_tracker.announce(self.allocator, url, req) catch null;
        } else {
            return tracker_mod.announce(self.allocator, url, req) catch null;
        }
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

        const stderr = std.fs.File.stderr().deprecatedWriter();
        stderr.print("tracker: {d} peers", .{resp.peers.len}) catch {};
        if (resp.complete) |c| stderr.print(", {d} seeders", .{c}) catch {};
        if (resp.incomplete) |ic| stderr.print(", {d} leechers", .{ic}) catch {};
        stderr.print("\n", .{}) catch {};

        self.connectToPeers(resp.peers) catch {};
    }

    fn computeLeft(self: *Session) u64 {
        var remaining: u64 = 0;
        for (0..self.num_pieces) |i| {
            if (!self.our_bitfield.hasPiece(@intCast(i))) {
                remaining += piece_mod.pieceLength(@intCast(i), self.piece_len, self.total_length);
            }
        }
        return remaining;
    }

    fn connectToPeers(self: *Session, peer_list: []const tracker_mod.Peer) !void {
        for (peer_list) |tracker_peer| {
            if (self.peers.items.len >= max_peers) break;

            const addr = std.net.Address.initIp4(tracker_peer.ip, tracker_peer.port);
            var already = false;
            for (self.peers.items) |existing| {
                if (std.mem.eql(u8, &std.mem.toBytes(existing.address), &std.mem.toBytes(addr))) {
                    already = true;
                    break;
                }
            }
            if (already) continue;

            const p = self.allocator.create(peer_mod.PeerConnection) catch continue;
            p.* = peer_mod.PeerConnection.init(self.allocator, addr);

            p.connect() catch {
                p.deinit();
                self.allocator.destroy(p);
                continue;
            };

            p.sendHandshake(self.info_hash, self.peer_id) catch {
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

    fn printProgress(self: *Session) !void {
        const stdout = std.fs.File.stdout().deprecatedWriter();
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
