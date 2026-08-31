/// UDP tracker protocol (BEP 15).
///
/// Binary protocol over UDP:
/// 1. Connect: send connection_id + action=0 + transaction_id -> receive connection_id
/// 2. Announce: send connection_id + action=1 + transaction_id + params -> receive peers
const std = @import("std");
const Allocator = std.mem.Allocator;
const tracker = @import("tracker.zig");

const Net = std.Io.net;
const IpAddress = Net.IpAddress;
const Socket = Net.Socket;
const HostName = Net.HostName;

const log = std.log.scoped(.udp_tracker);

const protocol_id: u64 = 0x41727101980; // magic constant per BEP 15
const action_connect: u32 = 0;
const action_announce: u32 = 1;
const action_error: u32 = 3;
const timeout_ms: u32 = 5000;

pub const UdpTrackerError = error{
    DnsResolveFailed,
    SocketFailed,
    SendFailed,
    Timeout,
    InvalidResponse,
    OutOfMemory,
};

/// Perform a UDP tracker announce. Returns parsed AnnounceResponse.
pub fn announce(
    io: std.Io,
    allocator: Allocator,
    url: []const u8,
    req: tracker.AnnounceRequest,
) UdpTrackerError!tracker.AnnounceResponse {
    const host_port =
        parseUdpUrl(url) orelse return error.InvalidResponse;

    const resolved_addr =
        resolveIp4(io, host_port.host, host_port.port) orelse return error.DnsResolveFailed;
    const bind_addr: IpAddress = .{
        .ip4 = .{
            .bytes = .{ 0, 0, 0, 0 },
            .port = 0,
        },
    };

    const sock = bind_addr.bind(io, .{
        .mode = .dgram,
    }) catch return error.SocketFailed;

    defer sock.close(io);

    const rng_source: std.Random.IoSource = .{ .io = io };
    const rng = rng_source.interface();

    // Step 1: Connect
    const txn_id1 = rng.int(u32);
    var connect_buf: [16]u8 = undefined;
    std.mem.writeInt(u64, connect_buf[0..8], protocol_id, .big);
    std.mem.writeInt(u32, connect_buf[8..12], action_connect, .big);
    std.mem.writeInt(u32, connect_buf[12..16], txn_id1, .big);

    sock.send(io, &resolved_addr, &connect_buf) catch return error.SendFailed;

    var recv_buf: [8192]u8 = undefined; // 8KB: holds ~1360 peers in compact format
    const connect_len = recvWithTimeout(io, &sock, &recv_buf) catch return error.Timeout;

    if (connect_len < 8) return error.InvalidResponse;
    const resp_action = std.mem.readInt(u32, recv_buf[0..4], .big);
    const resp_txn = std.mem.readInt(u32, recv_buf[4..8], .big);
    if (resp_txn != txn_id1) return error.InvalidResponse;
    if (resp_action == action_error) {
        if (connect_len > 8) log.warn("tracker error: {s}", .{recv_buf[8..connect_len]});
        return error.InvalidResponse;
    }
    if (resp_action != action_connect or connect_len < 16) return error.InvalidResponse;

    const connection_id = std.mem.readInt(u64, recv_buf[8..16], .big);

    // Step 2: Announce
    const txn_id2 = rng.int(u32);
    var ann_buf: [98]u8 = undefined;
    std.mem.writeInt(u64, ann_buf[0..8], connection_id, .big);
    std.mem.writeInt(u32, ann_buf[8..12], action_announce, .big);
    std.mem.writeInt(u32, ann_buf[12..16], txn_id2, .big);
    @memcpy(ann_buf[16..36], &req.info_hash);
    @memcpy(ann_buf[36..56], &req.peer_id);
    std.mem.writeInt(u64, ann_buf[56..64], req.downloaded, .big);
    std.mem.writeInt(u64, ann_buf[64..72], req.left, .big);
    std.mem.writeInt(u64, ann_buf[72..80], req.uploaded, .big);
    std.mem.writeInt(u32, ann_buf[80..84], eventToInt(req.event), .big);
    std.mem.writeInt(u32, ann_buf[84..88], 0, .big); // IP address (0 = default)
    std.mem.writeInt(u32, ann_buf[88..92], rng.int(u32), .big); // key
    std.mem.writeInt(i32, ann_buf[92..96], -1, .big); // num_want = -1 (default)
    std.mem.writeInt(u16, ann_buf[96..98], req.port, .big);

    sock.send(io, &resolved_addr, &ann_buf) catch return error.SendFailed;

    const ann_len = recvWithTimeout(io, &sock, &recv_buf) catch return error.Timeout;

    if (ann_len < 8) return error.InvalidResponse;
    const ann_action = std.mem.readInt(u32, recv_buf[0..4], .big);
    const ann_txn = std.mem.readInt(u32, recv_buf[4..8], .big);
    if (ann_txn != txn_id2) return error.InvalidResponse;
    if (ann_action == action_error) {
        if (ann_len > 8) log.warn("tracker announce error: {s}", .{recv_buf[8..ann_len]});
        return error.InvalidResponse;
    }
    if (ann_action != action_announce or ann_len < 20) return error.InvalidResponse;

    const interval = std.mem.readInt(u32, recv_buf[8..12], .big);
    const leechers = std.mem.readInt(u32, recv_buf[12..16], .big);
    const seeders = std.mem.readInt(u32, recv_buf[16..20], .big);

    // Parse compact peers (6 bytes each) from remaining data
    const peer_data = recv_buf[20..ann_len];
    if (peer_data.len % 6 != 0) return error.InvalidResponse;
    const peer_count = peer_data.len / 6;
    const peers = allocator.alloc(tracker.Peer, peer_count) catch return error.OutOfMemory;

    for (0..peer_count) |i| {
        const off = i * 6;
        peers[i] = .{
            .ip = .{ peer_data[off], peer_data[off + 1], peer_data[off + 2], peer_data[off + 3] },
            .port = @as(u16, peer_data[off + 4]) << 8 | @as(u16, peer_data[off + 5]),
        };
    }

    return .{
        .interval = interval,
        .min_interval = null,
        .complete = seeders,
        .incomplete = leechers,
        .peers = peers,
        .failure_reason = null,
        .warning_message = null,
    };
}

fn eventToInt(event: tracker.Event) u32 {
    return switch (event) {
        .none => 0,
        .completed => 1,
        .started => 2,
        .stopped => 3,
    };
}

const HostPort = struct {
    host: []const u8,
    port: u16,
};

fn parseUdpUrl(url: []const u8) ?HostPort {
    // udp://host:port/path
    const prefix = "udp://";
    if (!std.mem.startsWith(u8, url, prefix)) return null;
    const rest = url[prefix.len..];

    // Find end of host:port (at '/' or end)
    const host_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host_port = rest[0..host_end];

    // Split host:port
    const colon = std.mem.lastIndexOfScalar(u8, host_port, ':') orelse return null;
    const host = host_port[0..colon];
    const port_str = host_port[colon + 1 ..];
    const port = std.fmt.parseUnsigned(u16, port_str, 10) catch return null;

    return .{ .host = host, .port = port };
}
fn resolveIp4(
    io: std.Io,
    host: []const u8,
    port: u16,
) ?IpAddress {
    const host_name = HostName.init(host) catch return null;

    var result_storage: [16]HostName.LookupResult = undefined;
    var resolved =
        std.Io.Queue(HostName.LookupResult).init(&result_storage);

    host_name.lookup(io, &resolved, .{
        .port = port,
        .family = .ip4,
    }) catch return null;

    while (true) {
        const result = resolved.getOne(io) catch break;

        switch (result) {
            .address => |addr| switch (addr) {
                .ip4 => return addr,
                .ip6 => continue,
            },
            .canonical_name => {},
        }
    }

    return null;
}

fn recvWithTimeout(
    io: std.Io,
    sock: *const Socket,
    buf: []u8,
) !usize {
    const incoming = sock.receiveTimeout(
        io,
        buf,
        .{
            .duration = .{
                .raw = .fromMilliseconds(@as(i64, timeout_ms)),
                .clock = .awake,
            },
        },
    ) catch return error.Timeout;

    return incoming.data.len;
}

// --- Tests ---

test "parse UDP URL" {
    const hp = parseUdpUrl("udp://tracker.example.com:6969/announce").?;
    try std.testing.expectEqualStrings("tracker.example.com", hp.host);
    try std.testing.expectEqual(@as(u16, 6969), hp.port);
}

test "parse UDP URL without path" {
    const hp = parseUdpUrl("udp://tracker.example.com:1337").?;
    try std.testing.expectEqualStrings("tracker.example.com", hp.host);
    try std.testing.expectEqual(@as(u16, 1337), hp.port);
}

test "reject non-UDP URL" {
    try std.testing.expect(parseUdpUrl("http://tracker.example.com/announce") == null);
}

test "event to int mapping" {
    try std.testing.expectEqual(@as(u32, 0), eventToInt(.none));
    try std.testing.expectEqual(@as(u32, 1), eventToInt(.completed));
    try std.testing.expectEqual(@as(u32, 2), eventToInt(.started));
    try std.testing.expectEqual(@as(u32, 3), eventToInt(.stopped));
}
