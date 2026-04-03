/// Central session coordinator with poll-based event loop.
const std = @import("std");
const Allocator = std.mem.Allocator;
const metainfo = @import("metainfo.zig");
const tracker_mod = @import("tracker.zig");
const wire = @import("wire.zig");
const piece_mod = @import("piece.zig");
const storage_mod = @import("storage.zig");
const peer_mod = @import("peer.zig");

const max_peers: usize = 50;

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
    next_piece_hint: u32,

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

    pub fn init(
        allocator: Allocator,
        meta: metainfo.Metainfo,
        output_dir: []const u8,
        mode: Mode,
    ) !Session {
        const total_length = piece_mod.totalLength(meta.files);
        const num_pieces = piece_mod.numPieces(total_length, meta.piece_length);
        const info_hash = metainfo.infoHash(meta.raw_info);

        var peer_id: [20]u8 = undefined;
        @memcpy(peer_id[0..8], "-CA0010-");
        std.crypto.random.bytes(peer_id[8..]);

        var our_bitfield = try piece_mod.Bitfield.init(allocator, num_pieces);
        errdefer our_bitfield.deinit(allocator);

        const create = mode == .download;
        var store = storage_mod.Storage.init(allocator, meta, output_dir, create) catch
            return error.StorageInitFailed;
        errdefer store.deinit();

        // For seed mode, verify existing pieces
        if (mode == .seed) {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            stderr.print("verifying pieces...\n", .{}) catch {};
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
            stderr.print("verified: {d}/{d} pieces\n", .{ our_bitfield.count(), num_pieces }) catch {};
        }

        // Start listener for seeding
        var listener: ?std.net.Server = null;
        const listen_port: u16 = 6881;
        if (mode == .seed or our_bitfield.count() > 0) {
            const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, listen_port);
            listener = addr.listen(.{ .reuse_address = true }) catch null;
        }

        return .{
            .allocator = allocator,
            .meta = meta,
            .info_hash = info_hash,
            .peer_id = peer_id,
            .our_bitfield = our_bitfield,
            .store = store,
            .peers = .empty,
            .active_pieces = std.AutoHashMap(u32, *piece_mod.PieceProgress).init(allocator),
            .next_piece_hint = 0,
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
        };
    }

    pub fn deinit(self: *Session) void {
        // Clean up active pieces
        var it = self.active_pieces.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.active_pieces.deinit();

        // Clean up peers
        for (self.peers.items) |p| {
            p.deinit();
            self.allocator.destroy(p);
        }
        self.peers.deinit(self.allocator);

        if (self.listener) |*l| l.deinit();
        self.our_bitfield.deinit(self.allocator);
        self.store.deinit();
    }

    /// Run the main event loop.
    pub fn run(self: *Session) !void {
        const stdout = std.fs.File.stdout().deprecatedWriter();
        const stderr = std.fs.File.stderr().deprecatedWriter();

        // Initial announce
        stderr.print("announcing to tracker...\n", .{}) catch {};
        self.doAnnounce(.started) catch |err| {
            stderr.print("tracker announce failed: {}\n", .{err}) catch {};
        };

        stdout.print("download started: {d} pieces, {d} bytes\n", .{ self.num_pieces, self.total_length }) catch {};

        while (self.running) {
            // Check completion
            if (self.mode == .download and self.our_bitfield.isComplete()) {
                stdout.print("\ndownload complete!\n", .{}) catch {};
                self.doAnnounce(.completed) catch {};
                // Switch to seeding
                if (self.listener == null) {
                    const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, self.listen_port);
                    self.listener = addr.listen(.{ .reuse_address = true }) catch null;
                }
                self.mode = .seed;
                stdout.print("now seeding on port {d}...\n", .{self.listen_port}) catch {};
            }

            // Build pollfds
            var fds: [max_peers + 1]std.posix.pollfd = undefined;
            const nfds = self.buildPollFds(&fds);

            // Poll with 1 second timeout
            const ready = std.posix.poll(fds[0..nfds], 1000) catch 0;
            _ = ready;

            // Process results
            self.processPollResults(fds[0..nfds]) catch |err| {
                stderr.print("poll error: {}\n", .{err}) catch {};
            };

            // Schedule requests
            self.scheduleRequests() catch {};

            // Maintenance
            self.maintenance() catch {};
        }

        // Final announce
        self.doAnnounce(.stopped) catch {};
    }

    fn buildPollFds(self: *Session, fds: *[max_peers + 1]std.posix.pollfd) usize {
        var n: usize = 0;

        // Listener fd
        if (self.listener) |l| {
            fds[n] = .{
                .fd = l.stream.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            };
            n += 1;
        }

        // Peer fds
        for (self.peers.items) |p| {
            if (p.state == .disconnected or p.stream == null) continue;
            if (n >= fds.len) break;

            var events: i16 = std.posix.POLL.IN;
            if (p.wantsSend()) events |= std.posix.POLL.OUT;

            fds[n] = .{
                .fd = p.fd(),
                .events = events,
                .revents = 0,
            };
            n += 1;
        }

        return n;
    }

    fn processPollResults(self: *Session, fds: []std.posix.pollfd) !void {
        var fd_idx: usize = 0;

        // Check listener
        if (self.listener != null) {
            if (fds[fd_idx].revents & std.posix.POLL.IN != 0) {
                self.acceptIncoming() catch {};
            }
            fd_idx += 1;
        }

        // Check peers
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

                // Process messages
                if (p.state == .handshaking) {
                    if (p.tryParseHandshake()) |hs| {
                        if (!std.mem.eql(u8, &hs.info_hash, &self.info_hash)) {
                            p.disconnect();
                            fd_idx += 1;
                            continue;
                        }
                        p.peer_id = hs.peer_id;
                        p.state = .active;

                        // Send our bitfield
                        if (self.our_bitfield.count() > 0) {
                            p.enqueueMessage(.{ .bitfield = self.our_bitfield.rawBytes() }) catch {};
                        }

                        // Express interest if downloading
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
                // Unchoke interested peers (naive strategy)
                if (p.am_choking) {
                    p.am_choking = false;
                    p.enqueueMessage(.unchoke) catch {};
                }
            },
            .not_interested => {
                p.peer_interested = false;
            },
            .have => |index| {
                if (p.peer_bitfield) |*bf| {
                    if (index < bf.num_pieces) bf.setPiece(index);
                }
            },
            .bitfield => |data| {
                if (p.peer_bitfield) |*bf| bf.deinit(self.allocator);
                p.peer_bitfield = piece_mod.Bitfield.fromRaw(self.allocator, data, self.num_pieces) catch null;

                // Re-evaluate interest
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
            .cancel => {
                // Minimal implementation: ignore cancels
            },
            .keep_alive => {},
        }
    }

    fn onBlockReceived(self: *Session, p: *peer_mod.PeerConnection, pd: wire.Message.PieceData) !void {
        p.completePendingRequest(pd.index, pd.begin);

        const pp_ptr = self.active_pieces.get(pd.index) orelse return;
        const complete = pp_ptr.addBlock(pd.begin, pd.block);

        if (complete) {
            const hash = piece_mod.pieceHash(self.meta.pieces, pd.index) orelse return;

            if (piece_mod.verifyPiece(pp_ptr.data, hash)) {
                // Write to disk
                self.store.writePiece(pd.index, pp_ptr.data) catch {};

                self.our_bitfield.setPiece(pd.index);
                self.downloaded += pp_ptr.piece_len;

                const stdout = std.fs.File.stdout().deprecatedWriter();
                stdout.print("[{d}/{d}] piece {d} verified\n", .{
                    self.our_bitfield.count(), self.num_pieces, pd.index,
                }) catch {};

                // Broadcast have to all active peers
                for (self.peers.items) |peer| {
                    if (peer.state == .active) {
                        peer.enqueueMessage(.{ .have = pd.index }) catch {};
                    }
                }
            } else {
                // Hash mismatch -- reset and retry
                pp_ptr.reset();
                return;
            }

            // Remove from active pieces
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

        const end = req.begin + req.length;
        const block = data[req.begin..end];

        p.enqueueMessage(.{ .piece = .{
            .index = req.index,
            .begin = req.begin,
            .block = block,
        } }) catch {};

        self.uploaded += req.length;
    }

    fn scheduleRequests(self: *Session) !void {
        if (self.mode != .download) return;

        for (self.peers.items) |p| {
            if (p.state != .active) continue;

            while (p.canRequest()) {
                const piece_idx = self.pickNextPiece(p) orelse break;

                // Get or create PieceProgress
                const pp_ptr = self.active_pieces.get(piece_idx) orelse blk: {
                    const plen = piece_mod.pieceLength(piece_idx, self.piece_len, self.total_length);
                    const pp = self.allocator.create(piece_mod.PieceProgress) catch break;
                    pp.* = piece_mod.PieceProgress.init(self.allocator, piece_idx, plen) catch {
                        self.allocator.destroy(pp);
                        break;
                    };
                    self.active_pieces.put(piece_idx, pp) catch {
                        pp.deinit(self.allocator);
                        self.allocator.destroy(pp);
                        break;
                    };
                    break :blk pp;
                };

                const block_idx = pp_ptr.nextMissingBlock() orelse break;
                const spec = pp_ptr.blockSpec(block_idx);

                const req = wire.Message.BlockRequest{
                    .index = piece_idx,
                    .begin = spec.begin,
                    .length = spec.length,
                };

                p.enqueueMessage(.{ .request = req }) catch break;
                p.addPendingRequest(req) catch break;
            }
        }
    }

    fn pickNextPiece(self: *Session, p: *peer_mod.PeerConnection) ?u32 {
        // Sequential strategy: scan from hint
        var i: u32 = 0;
        while (i < self.num_pieces) : (i += 1) {
            const idx = (self.next_piece_hint + i) % self.num_pieces;
            if (self.our_bitfield.hasPiece(idx)) continue;
            if (!p.hasPiece(idx)) continue;

            // Check if already active and fully requested
            if (self.active_pieces.get(idx)) |pp| {
                if (pp.nextMissingBlock() == null) continue;
            }

            self.next_piece_hint = (idx + 1) % self.num_pieces;
            return idx;
        }
        return null;
    }

    fn peerHasNeededPieces(self: *Session, p: *peer_mod.PeerConnection) bool {
        for (0..self.num_pieces) |i| {
            const idx: u32 = @intCast(i);
            if (!self.our_bitfield.hasPiece(idx) and p.hasPiece(idx)) return true;
        }
        return false;
    }

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

        // Send our handshake
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

        // Remove disconnected peers
        var i: usize = 0;
        while (i < self.peers.items.len) {
            const p = self.peers.items[i];
            if (p.state == .disconnected) {
                p.deinit();
                self.allocator.destroy(p);
                _ = self.peers.orderedRemove(i);
            } else {
                // Keep-alive
                if (now - p.last_send_time > 60) {
                    p.enqueueMessage(.keep_alive) catch {};
                }
                // Timeout
                if (now - p.last_recv_time > 120) {
                    p.disconnect();
                }
                i += 1;
            }
        }

        // Re-announce
        const interval_secs = std.math.cast(i64, self.tracker_interval) orelse 1800;
        if (now - self.last_announce_time > interval_secs) {
            self.doAnnounce(.none) catch {};
        }
    }

    fn doAnnounce(self: *Session, event: tracker_mod.Event) !void {
        const left = blk: {
            var remaining: u64 = 0;
            for (0..self.num_pieces) |i| {
                if (!self.our_bitfield.hasPiece(@intCast(i))) {
                    remaining += piece_mod.pieceLength(@intCast(i), self.piece_len, self.total_length);
                }
            }
            break :blk remaining;
        };

        const resp = tracker_mod.announce(self.allocator, self.meta.announce, .{
            .info_hash = self.info_hash,
            .peer_id = self.peer_id,
            .port = self.listen_port,
            .uploaded = self.uploaded,
            .downloaded = self.downloaded,
            .left = left,
            .compact = true,
            .event = event,
        }) catch return error.TrackerFailed;
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
        if (resp.incomplete) |i| stderr.print(", {d} leechers", .{i}) catch {};
        stderr.print("\n", .{}) catch {};

        // Connect to new peers
        self.connectToPeers(resp.peers) catch {};
    }

    fn connectToPeers(self: *Session, peer_list: []const tracker_mod.Peer) !void {
        for (peer_list) |tracker_peer| {
            if (self.peers.items.len >= max_peers) break;

            // Skip if already connected
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

    fn isComplete(self: Session) bool {
        return self.our_bitfield.isComplete();
    }
};
