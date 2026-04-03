/// Per-peer connection state machine for BitTorrent wire protocol.
const std = @import("std");
const Allocator = std.mem.Allocator;
const wire = @import("wire.zig");
const piece_mod = @import("piece.zig");

pub const PeerState = enum {
    connecting,
    handshaking,
    active,
    disconnected,
};

pub const max_pipeline: u32 = 5;

/// Per-peer connection state.
pub const PeerConnection = struct {
    allocator: Allocator,
    address: std.net.Address,
    stream: ?std.net.Stream,
    state: PeerState,

    // Protocol state
    am_choking: bool,
    am_interested: bool,
    peer_choking: bool,
    peer_interested: bool,

    peer_bitfield: ?piece_mod.Bitfield,
    peer_id: ?[20]u8,

    // Buffers
    recv_buf: std.ArrayList(u8),
    send_buf: std.ArrayList(u8),
    send_pos: usize,

    // Request pipeline
    pending_requests: std.ArrayList(wire.Message.BlockRequest),

    // Timestamps
    last_recv_time: i64,
    last_send_time: i64,

    pub fn init(allocator: Allocator, address: std.net.Address) PeerConnection {
        return .{
            .allocator = allocator,
            .address = address,
            .stream = null,
            .state = .connecting,
            .am_choking = true,
            .am_interested = false,
            .peer_choking = true,
            .peer_interested = false,
            .peer_bitfield = null,
            .peer_id = null,
            .recv_buf = .empty,
            .send_buf = .empty,
            .send_pos = 0,
            .pending_requests = .empty,
            .last_recv_time = std.time.timestamp(),
            .last_send_time = std.time.timestamp(),
        };
    }

    pub fn deinit(self: *PeerConnection) void {
        if (self.stream) |s| s.close();
        if (self.peer_bitfield) |*bf| bf.deinit(self.allocator);
        self.recv_buf.deinit(self.allocator);
        self.send_buf.deinit(self.allocator);
        self.pending_requests.deinit(self.allocator);
    }

    /// Connect timeout in seconds.
    pub const connect_timeout_secs: u32 = 5;

    /// Initiate TCP connection with a timeout.
    pub fn connect(self: *PeerConnection) !void {
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

        // Set send timeout to limit blocking connect duration
        const timeout = std.posix.timeval{ .sec = connect_timeout_secs, .usec = 0 };
        std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};

        // Blocking connect with timeout
        std.posix.connect(sock, &self.address.any, @sizeOf(std.posix.sockaddr.in)) catch {
            std.posix.close(sock);
            self.state = .disconnected;
            return error.ConnectionFailed;
        };

        self.stream = .{ .handle = sock };
        self.state = .handshaking;
    }

    /// Queue the handshake for sending.
    pub fn sendHandshake(self: *PeerConnection, info_hash: [20]u8, peer_id: [20]u8) !void {
        const hs = wire.Handshake{
            .reserved = [_]u8{0} ** 8,
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

    /// Read available data from socket into recv_buf.
    pub fn readIncoming(self: *PeerConnection) !usize {
        const s = self.stream orelse return 0;
        var buf: [16384]u8 = undefined;
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

    /// Try to parse the handshake from recv_buf. Returns the parsed handshake or null.
    pub fn tryParseHandshake(self: *PeerConnection) ?wire.Handshake {
        if (self.recv_buf.items.len < wire.handshake_len) return null;
        const hs = wire.Handshake.parse(self.recv_buf.items[0..wire.handshake_len]) catch return null;

        // Consume handshake bytes
        const leftover = self.recv_buf.items[wire.handshake_len..];
        std.mem.copyForwards(u8, self.recv_buf.items[0..leftover.len], leftover);
        self.recv_buf.shrinkRetainingCapacity(leftover.len);

        return hs;
    }

    /// Parse and return the next complete message, or null if incomplete.
    pub fn nextMessage(self: *PeerConnection) !?wire.Message {
        const result = wire.parseMessage(self.allocator, self.recv_buf.items) catch |err| {
            self.state = .disconnected;
            return err;
        };
        if (result) |r| {
            // Consume parsed bytes
            const leftover = self.recv_buf.items[r.consumed..];
            std.mem.copyForwards(u8, self.recv_buf.items[0..leftover.len], leftover);
            self.recv_buf.shrinkRetainingCapacity(leftover.len);
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
        return !self.peer_choking and self.pending_requests.items.len < max_pipeline;
    }

    pub fn addPendingRequest(self: *PeerConnection, req: wire.Message.BlockRequest) !void {
        self.pending_requests.append(self.allocator, req) catch return error.OutOfMemory;
    }

    pub fn completePendingRequest(self: *PeerConnection, index: u32, begin: u32) void {
        for (self.pending_requests.items, 0..) |r, i| {
            if (r.index == index and r.begin == begin) {
                _ = self.pending_requests.orderedRemove(i);
                return;
            }
        }
    }

    pub fn clearPendingRequests(self: *PeerConnection) void {
        self.pending_requests.clearRetainingCapacity();
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

    // Fill pipeline
    for (0..max_pipeline) |i| {
        try peer.addPendingRequest(.{ .index = @intCast(i), .begin = 0, .length = 16384 });
    }
    try std.testing.expect(!peer.canRequest());

    // Complete one
    peer.completePendingRequest(2, 0);
    try std.testing.expect(peer.canRequest());
    try std.testing.expectEqual(@as(usize, max_pipeline - 1), peer.pending_requests.items.len);
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
