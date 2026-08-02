/// Per-peer connection state machine for BitTorrent wire protocol.
const std = @import("std");
const Allocator = std.mem.Allocator;
const wire = @import("wire.zig");
const piece_mod = @import("piece.zig");
const extension = @import("extension.zig");
const proxy_mod = @import("proxy.zig");
const i2p_sam = @import("i2p_sam.zig");

pub const PeerState = enum {
    connecting,
    handshaking,
    active,
    disconnected,
};

/// Request-pipeline sizing. The pipeline must hold roughly
/// `rate * RTT / block_size` outstanding requests to keep the link full
/// (bandwidth-delay product); a fixed small depth caps throughput at
/// `depth * 16 KiB / RTT` — e.g. 5 blocks over a 2 s I2P round trip is
/// only 40 KiB/s. The session resizes `pipeline_limit` once a second from
/// the peer's measured download rate, targeting `pipeline_queue_secs` of
/// data in flight, clamped to [`min_pipeline`, `max_pipeline`].
pub const min_pipeline: u32 = 16;
pub const max_pipeline: u32 = 512;
pub const pipeline_queue_secs: u32 = 4;

/// An outstanding block request, stamped so the session can expire requests
/// a connected-but-silent peer never answers.
pub const PendingRequest = struct {
    index: u32,
    begin: u32,
    length: u32,
    requested_at: i64,
};

/// Per-peer connection state.
pub const PeerConnection = struct {
    allocator: Allocator,
    address: std.net.Address,
    stream: ?std.net.Stream,
    state: PeerState,

    /// Outbound proxy to tunnel this connection through. When null, connect
    /// directly. Set by the session after `init` from its own proxy config.
    proxy: ?proxy_mod.Proxy,

    /// When set with `proxy`, connect via SOCKS to this hostname (e.g. `.onion`).
    /// Also carries the `.b32.i2p` destination when `i2p` is set.
    connect_host: ?[]const u8 = null,

    /// Borrowed SAM session (owned by the manager). When set, dial `connect_host`
    /// (a `.b32.i2p` destination) over native I2P instead of TCP/SOCKS.
    i2p: ?*i2p_sam.Session = null,

    // Protocol state
    am_choking: bool,
    am_interested: bool,
    peer_choking: bool,
    peer_interested: bool,

    peer_bitfield: ?piece_mod.Bitfield,
    /// Raw bitfield bytes as received, kept so a bitfield that arrives during
    /// the magnet metadata-only phase (when piece count is still unknown) can
    /// be re-parsed once `onMetadataComplete` learns the real piece count.
    /// Owned by the connection. Defaulted so struct literals can omit it.
    raw_bitfield: ?[]u8 = null,
    peer_id: ?[20]u8,

    // BEP 10 extension state
    supports_extensions: bool,
    peer_ut_metadata_id: ?u8, // peer's assigned ID for ut_metadata
    peer_metadata_size: ?u32,

    // Buffers
    recv_buf: std.ArrayList(u8),
    /// Parse offset into `recv_buf`. Consumed messages advance this instead
    /// of memmoving the remainder per message (compaction is amortized, like
    /// the send side). Defaulted so the init struct literals need not set it.
    recv_pos: usize = 0,
    send_buf: std.ArrayList(u8),
    send_pos: usize,

    // Request pipeline
    pending_requests: std.ArrayList(PendingRequest),
    /// Current pipeline depth, resized once a second by the session from the
    /// measured download rate (see `updatePipelineLimit`). Defaulted so the
    /// init struct literals need not set it.
    pipeline_limit: u32 = min_pipeline,
    /// EWMA download rate (bytes/s) and the `bytes_downloaded` value at the
    /// last sample, both owned by `updatePipelineLimit`.
    down_rate: u64 = 0,
    rate_last_bytes: u64 = 0,
    /// Whether O_NONBLOCK has been set on `stream`. Streams reach us from four
    /// places (direct connect, SOCKS proxy, I2P SAM, and inbound accept), so
    /// rather than have every producer remember, the first read/write flips it.
    nonblocking: bool = false,
    /// Wall-clock second at which `startConnect` issued the non-blocking
    /// connect(). The session enforces `connect_timeout_secs` against this in
    /// its maintenance tick instead of blocking inside connect().
    connect_started_at: i64 = 0,

    // Stats for choking algorithm
    bytes_downloaded: u64,
    bytes_uploaded: u64,

    // Timestamps
    last_recv_time: i64,
    last_send_time: i64,

    pub fn init(allocator: Allocator, address: std.net.Address) PeerConnection {
        return .{
            .allocator = allocator,
            .address = address,
            .stream = null,
            .state = .connecting,
            .proxy = null,
            .connect_host = null,
            .am_choking = true,
            .am_interested = false,
            .peer_choking = true,
            .peer_interested = false,
            .peer_bitfield = null,
            .peer_id = null,
            .supports_extensions = false,
            .peer_ut_metadata_id = null,
            .peer_metadata_size = null,
            .recv_buf = .empty,
            .send_buf = .empty,
            .send_pos = 0,
            .pending_requests = .empty,
            .bytes_downloaded = 0,
            .bytes_uploaded = 0,
            .last_recv_time = std.time.timestamp(),
            .last_send_time = std.time.timestamp(),
        };
    }

    /// Outbound connection to a Tor hidden service or other proxied hostname.
    pub fn initOnion(allocator: Allocator, host: []const u8, port: u16) !PeerConnection {
        const host_owned = try allocator.dupe(u8, host);
        return .{
            .allocator = allocator,
            .address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port),
            .stream = null,
            .state = .connecting,
            .proxy = null,
            .connect_host = host_owned,
            .am_choking = true,
            .am_interested = false,
            .peer_choking = true,
            .peer_interested = false,
            .peer_bitfield = null,
            .peer_id = null,
            .supports_extensions = false,
            .peer_ut_metadata_id = null,
            .peer_metadata_size = null,
            .recv_buf = .empty,
            .send_buf = .empty,
            .send_pos = 0,
            .pending_requests = .empty,
            .bytes_downloaded = 0,
            .bytes_uploaded = 0,
            .last_recv_time = std.time.timestamp(),
            .last_send_time = std.time.timestamp(),
        };
    }

    /// Outbound connection to an I2P `.b32.i2p` destination over a SAM session
    /// (owned by the caller). The session must outlive this connection. `port`
    /// is the peer's advertised I2CP destination port (0 = default), stored in
    /// `address` and passed to SAM as `TO_PORT` at connect time.
    pub fn initI2p(allocator: Allocator, host: []const u8, port: u16, sam: *i2p_sam.Session) !PeerConnection {
        var p = try PeerConnection.initOnion(allocator, host, port);
        p.i2p = sam;
        return p;
    }

    pub fn deinit(self: *PeerConnection) void {
        if (self.stream) |s| s.close();
        if (self.connect_host) |h| self.allocator.free(h);
        if (self.peer_bitfield) |*bf| bf.deinit(self.allocator);
        if (self.raw_bitfield) |rb| self.allocator.free(rb);
        self.recv_buf.deinit(self.allocator);
        self.send_buf.deinit(self.allocator);
        self.pending_requests.deinit(self.allocator);
    }

    /// Connect timeout in seconds.
    pub const connect_timeout_secs: u32 = 5;

    /// Disable Nagle on a peer socket (best-effort). Wire requests are tiny
    /// and latency-sensitive; letting the kernel coalesce them behind delayed
    /// ACKs stalls the request pipeline. Also applied to proxy/SAM bridge
    /// sockets — those are local TCP connections where Nagle only adds delay.
    pub fn setNoDelay(stream: std.net.Stream) void {
        const one: c_int = 1;
        std.posix.setsockopt(
            stream.handle,
            std.posix.IPPROTO.TCP,
            std.posix.TCP.NODELAY,
            std.mem.asBytes(&one),
        ) catch {};
    }

    /// Start a plain-TCP connect WITHOUT waiting for it to complete: create a
    /// non-blocking socket, issue connect(), and leave the peer in `.connecting`
    /// for the session's poll loop to finish via `completeConnect`.
    ///
    /// The blocking `connect` below waits up to `connect_timeout_secs` inside
    /// its own poll(); doing that for every tracker peer serialized the dials
    /// (20 dead peers x 5 s = ~100 s with the event loop frozen) and, because
    /// the run loop was not yet turning, meant peers dialed early sat with an
    /// open socket and zero handshake bytes on it until the loop got around to
    /// them — long past the 10 s handshake timeout real clients enforce.
    /// Only for the direct route; proxy/SAM dials keep their blocking handshake.
    pub fn startConnect(self: *PeerConnection) !void {
        const sock = std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
            std.posix.IPPROTO.TCP,
        ) catch {
            self.state = .disconnected;
            return error.ConnectionFailed;
        };
        // `stream` is only adopted on the success path below, so the socket is
        // ours to close until then (and never double-closed by `deinit`).
        var adopted = false;
        defer if (!adopted) {
            std.posix.close(sock);
            self.state = .disconnected;
        };

        const flags = std.posix.fcntl(sock, std.posix.F.GETFL, 0) catch
            return error.ConnectionFailed;
        var o: std.posix.O = @bitCast(@as(u32, @truncate(flags)));
        o.NONBLOCK = true;
        _ = std.posix.fcntl(sock, std.posix.F.SETFL, @as(u32, @bitCast(o))) catch {};

        std.posix.connect(sock, &self.address.any, @sizeOf(std.posix.sockaddr.in)) catch |err| switch (err) {
            // EINPROGRESS is the expected outcome: the handshake runs in the
            // kernel and poll(POLLOUT) reports the result.
            error.WouldBlock => {},
            else => return error.ConnectionFailed,
        };

        adopted = true;
        self.stream = .{ .handle = sock };
        self.nonblocking = true;
        setNoDelay(self.stream.?);
        self.connect_started_at = std.time.timestamp();
        // Even a connect() that completed inline (loopback) goes through
        // `completeConnect`, so there is exactly one path to `.handshaking`.
        self.state = .connecting;
    }

    /// Finish a `.connecting` socket after poll reported it writable (or in
    /// error). SO_ERROR carries the asynchronous outcome — a refused or
    /// unreachable peer also makes the socket "ready".
    pub fn completeConnect(self: *PeerConnection) !void {
        const s = self.stream orelse {
            self.state = .disconnected;
            return error.ConnectionFailed;
        };
        std.posix.getsockoptError(s.handle) catch {
            self.state = .disconnected;
            return error.ConnectionFailed;
        };
        self.state = .handshaking;
    }

    /// True when a `.connecting` peer has outlived `connect_timeout_secs`.
    /// Checked from the session's maintenance tick, so the deadline costs
    /// nothing while the loop keeps serving every other peer.
    pub fn connectTimedOut(self: PeerConnection, now: i64) bool {
        if (self.state != .connecting) return false;
        return now - self.connect_started_at >= connect_timeout_secs;
    }

    /// Initiate a connection and BLOCK until it is established (or times out).
    /// Still used by the proxy/SOCKS and I2P/SAM routes, whose own handshakes
    /// are synchronous. The direct route uses `startConnect` instead.
    pub fn connect(self: *PeerConnection) !void {
        // Native I2P: open a SAM stream to the destination. Synchronous, so on
        // success the stream is ready for the BT handshake (like the proxy path).
        if (self.i2p) |sam| {
            const dest = self.connect_host orelse {
                self.state = .disconnected;
                return error.ConnectionFailed;
            };
            self.stream = sam.connect(dest, self.address.getPort()) catch {
                self.state = .disconnected;
                return error.ConnectionFailed;
            };
            setNoDelay(self.stream.?);
            self.state = .handshaking;
            return;
        }

        // When a proxy is configured, tunnel through it. The handshake is
        // synchronous, so on success the stream is ready for the BT handshake.
        if (self.proxy) |px| {
            if (self.connect_host) |host| {
                const port = self.address.getPort();
                self.stream = proxy_mod.connectThroughProxyHost(self.allocator, px, host, port) catch {
                    self.state = .disconnected;
                    return error.ConnectionFailed;
                };
            } else {
                self.stream = proxy_mod.connectThroughProxyAddr(self.allocator, px, self.address) catch {
                    self.state = .disconnected;
                    return error.ConnectionFailed;
                };
            }
            setNoDelay(self.stream.?);
            self.state = .handshaking;
            return;
        }

        // Create socket
        const sock = std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
            std.posix.IPPROTO.TCP,
        ) catch {
            self.state = .disconnected;
            return error.ConnectionFailed;
        };
        errdefer std.posix.close(sock);

        // Connect with a hard timeout. SO_SNDTIMEO does NOT bound connect() on
        // macOS, so a dead or filtered peer (e.g. a stale nostr peer-announce)
        // could block the whole session in connect() for the OS default ~75 s.
        // Use a non-blocking connect + poll(POLLOUT) so connect_timeout_secs is
        // a real upper bound on every platform. The socket then stays
        // non-blocking for the session's poll-driven I/O (see below).
        const flags = std.posix.fcntl(sock, std.posix.F.GETFL, 0) catch {
            self.state = .disconnected;
            return error.ConnectionFailed;
        };
        var o: std.posix.O = @bitCast(@as(u32, @truncate(flags)));
        o.NONBLOCK = true;
        _ = std.posix.fcntl(sock, std.posix.F.SETFL, @as(u32, @bitCast(o))) catch {};

        std.posix.connect(sock, &self.address.any, @sizeOf(std.posix.sockaddr.in)) catch |err| switch (err) {
            // EINPROGRESS: the connect is underway; wait for the socket to
            // become writable (success) or error out, bounded by our timeout.
            error.WouldBlock => {
                var pfd = [_]std.posix.pollfd{.{
                    .fd = sock,
                    .events = std.posix.POLL.OUT,
                    .revents = 0,
                }};
                const ready = std.posix.poll(&pfd, connect_timeout_secs * 1000) catch {
                    self.state = .disconnected;
                    return error.ConnectionFailed;
                };
                if (ready == 0) {
                    self.state = .disconnected;
                    return error.ConnectionTimedOut;
                }
                // Connect finished -- surface any asynchronous error (refused,
                // unreachable, …) via SO_ERROR rather than treating it as ok.
                std.posix.getsockoptError(sock) catch {
                    self.state = .disconnected;
                    return error.ConnectionFailed;
                };
            },
            else => {
                self.state = .disconnected;
                return error.ConnectionFailed;
            },
        };

        // Stay non-blocking. A blocking socket caps each peer at ONE buffer per
        // poll wake (a second read would stall every other peer), which made
        // peer throughput `peers x 64 KiB x loop_rate` — measured at 384 KB/s on
        // a 50-peer swarm. Non-blocking lets `readIncoming`/`flushSend` drain to
        // EAGAIN, and stops a slow leecher's large piece send from freezing the
        // whole session mid-write.
        self.nonblocking = true;

        self.stream = .{ .handle = sock };
        setNoDelay(self.stream.?);
        self.state = .handshaking;
    }

    /// Queue the handshake for sending.
    pub fn sendHandshake(self: *PeerConnection, info_hash: [20]u8, peer_id: [20]u8) !void {
        var reserved = [_]u8{0} ** 8;
        extension.setExtensionBit(&reserved); // advertise BEP 10
        const hs = wire.Handshake{
            .reserved = reserved,
            .info_hash = info_hash,
            .peer_id = peer_id,
        };
        const buf = hs.serialize();
        self.send_buf.appendSlice(self.allocator, &buf) catch return error.OutOfMemory;
    }

    /// Queue a wire message for sending.
    pub fn enqueueMessage(self: *PeerConnection, msg: wire.Message) !void {
        const serialized = wire.serializeMessage(self.allocator, msg) catch return error.OutOfMemory;
        defer self.allocator.free(serialized);
        self.send_buf.appendSlice(self.allocator, serialized) catch return error.OutOfMemory;
    }

    /// Ensure the socket is non-blocking. Idempotent; see the `nonblocking`
    /// field for why this is done lazily at the I/O sites.
    fn ensureNonBlocking(self: *PeerConnection) void {
        if (self.nonblocking) return;
        const s = self.stream orelse return;
        const flags = std.posix.fcntl(s.handle, std.posix.F.GETFL, 0) catch return;
        var o: std.posix.O = @bitCast(@as(u32, @truncate(flags)));
        o.NONBLOCK = true;
        _ = std.posix.fcntl(s.handle, std.posix.F.SETFL, @as(u32, @bitCast(o))) catch return;
        self.nonblocking = true;
    }

    /// Flush the send buffer, writing until the socket says EAGAIN or the
    /// buffer empties. A single write() left the rest queued until the next
    /// poll wake, which delayed every `interested`/`request`/`piece` by a full
    /// loop iteration; on a blocking socket it could also stall the session
    /// inside one large piece send. Returns total bytes written.
    pub fn flushSend(self: *PeerConnection) !usize {
        const s = self.stream orelse return 0;
        self.ensureNonBlocking();

        var written: usize = 0;
        while (self.send_pos < self.send_buf.items.len) {
            const remaining = self.send_buf.items[self.send_pos..];
            const n = s.write(remaining) catch |err| switch (err) {
                // Kernel buffer full: keep the remainder queued for the next
                // POLLOUT rather than treating backpressure as a failure.
                error.WouldBlock => break,
                else => {
                    self.state = .disconnected;
                    return error.IoError;
                },
            };
            if (n == 0) break;
            self.send_pos += n;
            written += n;
        }
        if (written == 0) return 0;
        self.last_send_time = std.time.timestamp();

        // Compact send buffer when half consumed
        if (self.send_pos > self.send_buf.items.len / 2 and self.send_pos > 0) {
            const leftover = self.send_buf.items[self.send_pos..];
            std.mem.copyForwards(u8, self.send_buf.items[0..leftover.len], leftover);
            self.send_buf.shrinkRetainingCapacity(leftover.len);
            self.send_pos = 0;
        }

        return written;
    }

    /// Largest amount `readIncoming` will drain from one peer in one call.
    /// Without a bound, a peer that streams faster than we process could hold
    /// the loop indefinitely and starve the others; poll reports the socket
    /// readable again next iteration, so nothing is lost by stopping here.
    const max_read_per_call: usize = 1 << 20;

    /// Read available data from socket into recv_buf, draining until the socket
    /// reports EAGAIN (or `max_read_per_call`). Reading a single buffer per poll
    /// wake capped each peer at 64 KiB per loop iteration — the dominant limit
    /// on peer throughput. Returns total bytes read.
    pub fn readIncoming(self: *PeerConnection) !usize {
        const s = self.stream orelse return 0;
        self.ensureNonBlocking();

        var buf: [65536]u8 = undefined;
        var total: usize = 0;
        while (total < max_read_per_call) {
            const n = s.read(&buf) catch |err| switch (err) {
                // Socket drained; what we already appended still counts.
                error.WouldBlock => break,
                else => {
                    self.state = .disconnected;
                    return error.IoError;
                },
            };
            if (n == 0) {
                // Orderly EOF: the peer closed. Report the disconnect, but keep
                // any bytes read in this call — they may hold whole messages.
                self.state = .disconnected;
                break;
            }
            self.recv_buf.appendSlice(self.allocator, buf[0..n]) catch return error.OutOfMemory;
            total += n;
            // A short read means the socket is drained; another read would only
            // return EAGAIN.
            if (n < buf.len) break;
        }
        if (total > 0) self.last_recv_time = std.time.timestamp();
        return total;
    }

    /// Drop consumed bytes from the front of recv_buf. Amortized: a no-op
    /// until everything is consumed or the consumed prefix dominates.
    fn compactRecv(self: *PeerConnection) void {
        if (self.recv_pos == 0) return;
        if (self.recv_pos == self.recv_buf.items.len) {
            self.recv_buf.clearRetainingCapacity();
            self.recv_pos = 0;
            return;
        }
        if (self.recv_pos > self.recv_buf.items.len / 2) {
            const leftover = self.recv_buf.items[self.recv_pos..];
            std.mem.copyForwards(u8, self.recv_buf.items[0..leftover.len], leftover);
            self.recv_buf.shrinkRetainingCapacity(leftover.len);
            self.recv_pos = 0;
        }
    }

    /// Try to parse the handshake from recv_buf. Returns the parsed handshake or null.
    pub fn tryParseHandshake(self: *PeerConnection) ?wire.Handshake {
        const avail = self.recv_buf.items[self.recv_pos..];
        if (avail.len < wire.handshake_len) return null;
        const hs = wire.Handshake.parse(avail[0..wire.handshake_len]) catch return null;

        self.recv_pos += wire.handshake_len;
        self.compactRecv();

        return hs;
    }

    /// Parse and return the next complete message, or null if incomplete.
    pub fn nextMessage(self: *PeerConnection) !?wire.Message {
        const result = wire.parseMessage(self.allocator, self.recv_buf.items[self.recv_pos..]) catch |err| {
            self.state = .disconnected;
            return err;
        };
        if (result) |r| {
            self.recv_pos += r.consumed;
            self.compactRecv();
            return r.msg;
        }
        return null;
    }

    pub fn fd(self: PeerConnection) std.posix.fd_t {
        return if (self.stream) |s| s.handle else -1;
    }

    pub fn wantsSend(self: PeerConnection) bool {
        return self.send_pos < self.send_buf.items.len;
    }

    pub fn canRequest(self: PeerConnection) bool {
        return !self.peer_choking and self.pending_requests.items.len < self.pipeline_limit;
    }

    pub fn addPendingRequest(self: *PeerConnection, req: wire.Message.BlockRequest) !void {
        self.pending_requests.append(self.allocator, .{
            .index = req.index,
            .begin = req.begin,
            .length = req.length,
            .requested_at = std.time.timestamp(),
        }) catch return error.OutOfMemory;
    }

    pub fn completePendingRequest(self: *PeerConnection, index: u32, begin: u32) void {
        for (self.pending_requests.items, 0..) |r, i| {
            if (r.index == index and r.begin == begin) {
                _ = self.pending_requests.swapRemove(i);
                return;
            }
        }
    }

    pub fn hasPendingRequest(self: PeerConnection, index: u32, begin: u32) bool {
        for (self.pending_requests.items) |r| {
            if (r.index == index and r.begin == begin) return true;
        }
        return false;
    }

    pub fn clearPendingRequests(self: *PeerConnection) void {
        self.pending_requests.clearRetainingCapacity();
    }

    /// Resample this peer's download rate (EWMA, alpha 1/4) and resize the
    /// request pipeline to hold `pipeline_queue_secs` of data in flight.
    /// Called once a second by the session's maintenance tick.
    pub fn updatePipelineLimit(self: *PeerConnection, dt: i64) void {
        if (dt <= 0) return;
        const delta = self.bytes_downloaded -| self.rate_last_bytes;
        self.rate_last_bytes = self.bytes_downloaded;
        const inst = delta / @as(u64, @intCast(dt));
        self.down_rate = (self.down_rate * 3 + inst) / 4;

        const target = self.down_rate * pipeline_queue_secs / piece_mod.block_size;
        self.pipeline_limit = @intCast(std.math.clamp(target, min_pipeline, max_pipeline));
    }

    pub fn hasPiece(self: PeerConnection, index: u32) bool {
        if (self.peer_bitfield) |bf| return bf.hasPiece(index);
        return false;
    }

    pub fn disconnect(self: *PeerConnection) void {
        if (self.stream) |s| {
            s.close();
            self.stream = null;
        }
        self.state = .disconnected;
    }

    pub const Error = error{
        ConnectionFailed,
        IoError,
        OutOfMemory,
    } || wire.ParseError;
};

// --- Tests ---

test "peer init defaults" {
    const allocator = std.testing.allocator;
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6881);
    var peer = PeerConnection.init(allocator, addr);
    defer peer.deinit();

    try std.testing.expectEqual(PeerState.connecting, peer.state);
    try std.testing.expect(peer.am_choking);
    try std.testing.expect(!peer.am_interested);
    try std.testing.expect(peer.peer_choking);
    try std.testing.expect(!peer.peer_interested);
    try std.testing.expect(peer.stream == null);
}

test "peer request pipeline" {
    const allocator = std.testing.allocator;
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6881);
    var peer = PeerConnection.init(allocator, addr);
    defer peer.deinit();

    // Peer is choking us by default
    try std.testing.expect(!peer.canRequest());

    // Unchoke
    peer.peer_choking = false;
    try std.testing.expect(peer.canRequest());

    // Fill pipeline up to the current (initial) limit
    for (0..min_pipeline) |i| {
        try peer.addPendingRequest(.{ .index = @intCast(i), .begin = 0, .length = 16384 });
    }
    try std.testing.expect(!peer.canRequest());

    // Complete one
    peer.completePendingRequest(2, 0);
    try std.testing.expect(peer.canRequest());
    try std.testing.expectEqual(@as(usize, min_pipeline - 1), peer.pending_requests.items.len);
    try std.testing.expect(peer.hasPendingRequest(3, 0));
    try std.testing.expect(!peer.hasPendingRequest(2, 0));
}

test "peer pipeline limit scales with measured rate" {
    const allocator = std.testing.allocator;
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6881);
    var peer = PeerConnection.init(allocator, addr);
    defer peer.deinit();

    try std.testing.expectEqual(min_pipeline, peer.pipeline_limit);

    // A fast peer grows the pipeline toward rate * queue_secs / block_size.
    // Feed a steady 8 MiB/s until the EWMA converges.
    for (0..16) |_| {
        peer.bytes_downloaded += 8 * 1024 * 1024;
        peer.updatePipelineLimit(1);
    }
    try std.testing.expect(peer.pipeline_limit > min_pipeline);
    try std.testing.expect(peer.pipeline_limit <= max_pipeline);

    // A stalled peer decays back to the floor (never below it).
    for (0..64) |_| peer.updatePipelineLimit(1);
    try std.testing.expectEqual(min_pipeline, peer.pipeline_limit);
}

test "peer enqueue and send buffer" {
    const allocator = std.testing.allocator;
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6881);
    var peer = PeerConnection.init(allocator, addr);
    defer peer.deinit();

    try peer.enqueueMessage(.choke);
    try std.testing.expect(peer.wantsSend());
    try std.testing.expectEqual(@as(usize, 5), peer.send_buf.items.len); // 4 + 1
}

test "startConnect leaves the peer in .connecting and finishes via poll" {
    const allocator = std.testing.allocator;

    // Ephemeral loopback listener: something must accept, or the connect
    // completes with ECONNREFUSED instead.
    const listen_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    var server = try listen_addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.getPort();

    var peer = PeerConnection.init(allocator, std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port));
    defer peer.deinit();

    try peer.startConnect();
    // The whole point: the call returned without waiting for the handshake.
    try std.testing.expect(peer.stream != null);
    try std.testing.expect(peer.nonblocking);
    try std.testing.expectEqual(PeerState.connecting, peer.state);

    var pfd = [_]std.posix.pollfd{.{ .fd = peer.fd(), .events = std.posix.POLL.OUT, .revents = 0 }};
    const ready = try std.posix.poll(&pfd, 2000);
    try std.testing.expect(ready == 1);

    try peer.completeConnect();
    try std.testing.expectEqual(PeerState.handshaking, peer.state);

    var accepted = try server.accept();
    accepted.stream.close();
}

test "a refused async connect ends disconnected, never established" {
    const allocator = std.testing.allocator;

    // Bind then release a port so (almost certainly) nothing is listening on it.
    const probe_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    var probe = try probe_addr.listen(.{ .reuse_address = true });
    const dead_port = probe.listen_address.getPort();
    probe.deinit();

    var peer = PeerConnection.init(allocator, std.net.Address.initIp4(.{ 127, 0, 0, 1 }, dead_port));
    defer peer.deinit();

    // Loopback may refuse inside connect() (macOS) or asynchronously via
    // SO_ERROR; both must land on `.disconnected`, never `.handshaking`.
    if (peer.startConnect()) {
        var pfd = [_]std.posix.pollfd{.{ .fd = peer.fd(), .events = std.posix.POLL.OUT, .revents = 0 }};
        _ = try std.posix.poll(&pfd, 2000);
        try std.testing.expectError(error.ConnectionFailed, peer.completeConnect());
    } else |err| {
        try std.testing.expectEqual(error.ConnectionFailed, err);
    }
    try std.testing.expectEqual(PeerState.disconnected, peer.state);
}

test "connectTimedOut only fires for a stalled .connecting peer" {
    const allocator = std.testing.allocator;
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6881);
    var peer = PeerConnection.init(allocator, addr);
    defer peer.deinit();

    peer.state = .connecting;
    peer.connect_started_at = 1000;
    try std.testing.expect(!peer.connectTimedOut(1000 + PeerConnection.connect_timeout_secs - 1));
    try std.testing.expect(peer.connectTimedOut(1000 + PeerConnection.connect_timeout_secs));

    // An established peer is never reaped by the connect deadline.
    peer.state = .active;
    try std.testing.expect(!peer.connectTimedOut(1_000_000));
}

test "peer handshake serialization" {
    const allocator = std.testing.allocator;
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6881);
    var peer = PeerConnection.init(allocator, addr);
    defer peer.deinit();

    try peer.sendHandshake([_]u8{0xAA} ** 20, [_]u8{0xBB} ** 20);
    try std.testing.expectEqual(@as(usize, 68), peer.send_buf.items.len);
}
