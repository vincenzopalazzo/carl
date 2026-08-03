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
    socks_connecting,
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
pub const min_pipeline: u32 = 32;
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
    client_name: ?[]u8 = null,

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
    up_rate: u64 = 0,
    rate_last_up_bytes: u64 = 0,

    // Stats for choking algorithm
    bytes_downloaded: u64,
    bytes_uploaded: u64,

    // Timestamps
    last_recv_time: i64,
    last_send_time: i64,
    /// Wall-clock second a clearnet non-blocking connect was started.
    /// `maintenance` disconnects a `.connecting` peer that exceeds the connect
    /// timeout, so a dead host can't squat a poll slot forever.
    connect_started_at: i64 = 0,

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
        if (self.client_name) |n| self.allocator.free(n);
        if (self.peer_bitfield) |*bf| bf.deinit(self.allocator);
        if (self.raw_bitfield) |rb| self.allocator.free(rb);
        self.recv_buf.deinit(self.allocator);
        self.send_buf.deinit(self.allocator);
        self.pending_requests.deinit(self.allocator);
    }

    /// Connect timeout in seconds. Generous: a non-blocking connect integrated
    /// into the poll loop costs nothing while waiting, and international /
    /// congested peers routinely need 5-10 s to complete a TCP handshake.
    pub const connect_timeout_secs: u32 = 15;

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

    /// Raise SO_RCVBUF/SO_SNDBUF so high-bandwidth block traffic doesn't
    /// overflow the kernel's default buffers (often 64–256 KiB) and drop under
    /// bursts. Best-effort: silently ignored if the OS denies the raise.
    pub fn setSocketBuffers(sock_fd: std.posix.fd_t) void {
        const sz: c_int = 512 * 1024;
        std.posix.setsockopt(sock_fd, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, std.mem.asBytes(&sz)) catch {};
        std.posix.setsockopt(sock_fd, std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, std.mem.asBytes(&sz)) catch {};
    }

    /// Initiate TCP connection with a timeout.
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
        setSocketBuffers(sock);

        // Connect with a hard timeout. SO_SNDTIMEO does NOT bound connect() on
        // macOS, so a dead or filtered peer (e.g. a stale nostr peer-announce)
        // could block the whole session in connect() for the OS default ~75 s.
        // Use a non-blocking connect + poll(POLLOUT) so connect_timeout_secs is
        // a real upper bound on every platform, then restore blocking mode for
        // the session's normal poll-driven I/O.
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

        // Back to blocking: the session multiplexes peers with poll() and then
        // does blocking reads/writes on ready sockets.
        o.NONBLOCK = false;
        _ = std.posix.fcntl(sock, std.posix.F.SETFL, @as(u32, @bitCast(o))) catch {};

        self.stream = .{ .handle = sock };
        setNoDelay(self.stream.?);
        self.state = .handshaking;
    }

    /// Begin connecting without blocking the single event-loop thread.
    ///
    /// For a clearnet peer this issues a non-blocking connect() and returns
    /// immediately on EINPROGRESS. The peer stays `.connecting`; the session's
    /// poll loop watches the socket for POLLOUT and calls `finishConnect` to
    /// complete it. This lets one tracker announce (hundreds of peers) kick off
    /// dozens of connections in microseconds instead of blocking the event loop
    /// for up to N × connect_timeout_secs while dead/firewalled peers each burn
    /// their full timeout serially.
    ///
    /// Proxied (SOCKS/Tor) and native-I2P peers finish their handshake here
    /// synchronously (the caller caps how many it attempts per call); the BT
    /// handshake is queued right after.
    pub fn startConnect(self: *PeerConnection, info_hash: [20]u8, peer_id: [20]u8) !void {
        if (self.proxy) |px| {
            if (px.scheme == .socks5 or px.scheme == .socks5h) {
                // Async SOCKS5 (Tor): fast local handshake + send CONNECT, then
                // return. The poll loop reads the reply when Tor finishes building
                // the circuit — no blocking the event loop for 1-10s per peer.
                try self.startProxyConnect();
                return;
            }
            // HTTP CONNECT proxy: synchronous (rare, not Tor)
            try self.connect();
            try self.sendHandshake(info_hash, peer_id);
            return;
        }
        if (self.i2p != null) {
            try self.connect();
            try self.sendHandshake(info_hash, peer_id);
            return;
        }

        // Clearnet: non-blocking connect, return on EINPROGRESS.
        const sock = std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
            std.posix.IPPROTO.TCP,
        ) catch {
            self.state = .disconnected;
            return error.ConnectionFailed;
        };
        errdefer std.posix.close(sock);
        setSocketBuffers(sock);

        const flags = std.posix.fcntl(sock, std.posix.F.GETFL, 0) catch {
            self.state = .disconnected;
            return error.ConnectionFailed;
        };
        var o: std.posix.O = @bitCast(@as(u32, @truncate(flags)));
        o.NONBLOCK = true;
        _ = std.posix.fcntl(sock, std.posix.F.SETFL, @as(u32, @bitCast(o))) catch {};

        std.posix.connect(sock, &self.address.any, @sizeOf(std.posix.sockaddr.in)) catch |err| switch (err) {
            // EINPROGRESS: connect underway — the session poll loop completes it.
            error.WouldBlock => {
                self.stream = .{ .handle = sock };
                self.state = .connecting;
                self.connect_started_at = std.time.timestamp();
                return;
            },
            else => {
                self.state = .disconnected;
                return error.ConnectionFailed;
            },
        };

        // Immediate success (loopback / same host): finish without blocking.
        o.NONBLOCK = false;
        _ = std.posix.fcntl(sock, std.posix.F.SETFL, @as(u32, @bitCast(o))) catch {};
        self.stream = .{ .handle = sock };
        setNoDelay(self.stream.?);
        self.state = .handshaking;
        try self.sendHandshake(info_hash, peer_id);
    }

    /// Complete a clearnet non-blocking connect whose socket became writable.
    /// Surfaces any asynchronous connect error via SO_ERROR; on success
    /// restores blocking mode and queues the BitTorrent handshake.
    pub fn finishConnect(self: *PeerConnection, info_hash: [20]u8, peer_id: [20]u8) !void {
        const s = self.stream orelse return error.ConnectionFailed;
        std.posix.getsockoptError(s.handle) catch {
            self.state = .disconnected;
            return error.ConnectionFailed;
        };
        const flags = std.posix.fcntl(s.handle, std.posix.F.GETFL, 0) catch {
            self.state = .disconnected;
            return error.ConnectionFailed;
        };
        var o: std.posix.O = @bitCast(@as(u32, @truncate(flags)));
        o.NONBLOCK = false;
        _ = std.posix.fcntl(s.handle, std.posix.F.SETFL, @as(u32, @bitCast(o))) catch {};
        setNoDelay(s);
        self.state = .handshaking;
        try self.sendHandshake(info_hash, peer_id);
    }

    /// Async SOCKS5 proxy connect: TCP connect to proxy + SOCKS5 auth + send
    /// CONNECT request (all fast/local), then return. The poll loop calls
    /// finishProxyConnect when the socket is readable (Tor circuit built).
    fn startProxyConnect(self: *PeerConnection) !void {
        const px = self.proxy orelse return error.ConnectionFailed;
        self.stream = proxy_mod.connectThroughProxyAddrStart(self.allocator, px, self.address) catch {
            self.state = .disconnected;
            return error.ConnectionFailed;
        };
        const flags = std.posix.fcntl(self.stream.?.handle, std.posix.F.GETFL, 0) catch {
            self.state = .disconnected;
            return error.ConnectionFailed;
        };
        var o: std.posix.O = @bitCast(@as(u32, @truncate(flags)));
        o.NONBLOCK = true;
        _ = std.posix.fcntl(self.stream.?.handle, std.posix.F.SETFL, @as(u32, @bitCast(o))) catch {};
        self.state = .socks_connecting;
        self.connect_started_at = std.time.timestamp();
    }

    /// Complete an async SOCKS5 proxy connect: read the CONNECT reply (socket
    /// is readable so this is instant), restore blocking, queue BT handshake.
    pub fn finishProxyConnect(self: *PeerConnection, info_hash: [20]u8, peer_id: [20]u8) !void {
        const s = self.stream orelse return error.ConnectionFailed;
        const flags = std.posix.fcntl(s.handle, std.posix.F.GETFL, 0) catch {
            self.state = .disconnected;
            return error.ConnectionFailed;
        };
        var o: std.posix.O = @bitCast(@as(u32, @truncate(flags)));
        o.NONBLOCK = false;
        _ = std.posix.fcntl(s.handle, std.posix.F.SETFL, @as(u32, @bitCast(o))) catch {};
        proxy_mod.readSocks5ReplyPub(s) catch {
            self.state = .disconnected;
            return error.ConnectionFailed;
        };
        setNoDelay(s);
        setSocketBuffers(s.handle);
        self.state = .handshaking;
        try self.sendHandshake(info_hash, peer_id);
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

    /// Flush send buffer to socket. Returns bytes written.
    pub fn flushSend(self: *PeerConnection) !usize {
        const s = self.stream orelse return 0;
        const remaining = self.send_buf.items[self.send_pos..];
        if (remaining.len == 0) return 0;

        const written = s.write(remaining) catch {
            self.state = .disconnected;
            return error.IoError;
        };
        self.send_pos += written;
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

    /// Read available data from socket into recv_buf. The buffer is sized to
    /// drain several piece messages per poll wake — a 16 KiB read forced one
    /// syscall + poll round per block.
    pub fn readIncoming(self: *PeerConnection) !usize {
        const s = self.stream orelse return 0;
        var buf: [65536]u8 = undefined;
        const n = s.read(&buf) catch {
            self.state = .disconnected;
            return error.IoError;
        };
        if (n == 0) {
            self.state = .disconnected;
            return 0;
        }
        self.recv_buf.appendSlice(self.allocator, buf[0..n]) catch return error.OutOfMemory;
        self.last_recv_time = std.time.timestamp();
        return n;
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

        const up_delta = self.bytes_uploaded -| self.rate_last_up_bytes;
        self.rate_last_up_bytes = self.bytes_uploaded;
        const up_inst = up_delta / @as(u64, @intCast(dt));
        self.up_rate = (self.up_rate * 3 + up_inst) / 4;

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

test "peer handshake serialization" {
    const allocator = std.testing.allocator;
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6881);
    var peer = PeerConnection.init(allocator, addr);
    defer peer.deinit();

    try peer.sendHandshake([_]u8{0xAA} ** 20, [_]u8{0xBB} ** 20);
    try std.testing.expectEqual(@as(usize, 68), peer.send_buf.items.len);
}
