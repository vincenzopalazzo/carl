/// Kademlia DHT for BitTorrent (BEP 5).
///
/// Provides decentralized peer discovery. Nodes exchange UDP messages
/// (bencoded dictionaries) to find peers for a given info_hash.
///
/// Messages: ping, find_node, get_peers, announce_peer
/// Each node has a 160-bit ID and maintains a routing table of k-buckets.
const std = @import("std");
const Allocator = std.mem.Allocator;
const bencode = @import("bencode.zig");
const tracker_mod = @import("tracker.zig");

const log = std.log.scoped(.dht);

/// k parameter: max nodes per bucket.
const k: usize = 8;

/// Node ID size in bytes (160 bits).
pub const id_len: usize = 20;

/// A DHT node: ID + address.
pub const Node = struct {
    id: [id_len]u8,
    address: std.net.Address,
};

/// Well-known bootstrap nodes.
const bootstrap_nodes = [_]struct { host: []const u8, port: u16 }{
    .{ .host = "router.bittorrent.com", .port = 6881 },
    .{ .host = "dht.transmissionbt.com", .port = 6881 },
    .{ .host = "router.utorrent.com", .port = 6881 },
};

/// XOR distance between two node IDs.
fn distance(a: [id_len]u8, b: [id_len]u8) [id_len]u8 {
    var result: [id_len]u8 = undefined;
    for (0..id_len) |i| {
        result[i] = a[i] ^ b[i];
    }
    return result;
}

/// Find the bucket index for a given distance (leading zero bits).
fn bucketIndex(dist: [id_len]u8) u8 {
    for (0..id_len) |i| {
        if (dist[i] != 0) {
            // Count leading zeros in this byte
            var byte = dist[i];
            var zeros: u8 = 0;
            while (byte & 0x80 == 0) {
                zeros += 1;
                byte <<= 1;
            }
            return @intCast(i * 8 + zeros);
        }
    }
    return 159; // Same ID
}

/// DHT client for peer discovery.
pub const Dht = struct {
    allocator: Allocator,
    our_id: [id_len]u8,
    sock: ?std.posix.fd_t,
    port: u16,

    // Routing table: 160 buckets, each up to k nodes
    buckets: [160]std.ArrayList(Node),

    pub fn init(allocator: Allocator, port: u16) Dht {
        var our_id: [id_len]u8 = undefined;
        std.crypto.random.bytes(&our_id);

        var buckets: [160]std.ArrayList(Node) = undefined;
        for (&buckets) |*b| {
            b.* = .empty;
        }

        return .{
            .allocator = allocator,
            .our_id = our_id,
            .sock = null,
            .port = port,
            .buckets = buckets,
        };
    }

    pub fn deinit(self: *Dht) void {
        if (self.sock) |s| std.posix.close(s);
        for (&self.buckets) |*b| {
            b.deinit(self.allocator);
        }
    }

    /// Start the DHT: bind UDP socket and bootstrap.
    pub fn start(self: *Dht) !void {
        const sock = std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC,
            std.posix.IPPROTO.UDP,
        ) catch return error.SocketFailed;

        // Set receive timeout
        const tv = std.posix.timeval{ .sec = 2, .usec = 0 };
        std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};

        // Bind to port
        const bind_addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, self.port);
        std.posix.bind(sock, &bind_addr.any, @sizeOf(std.posix.sockaddr.in)) catch {
            std.posix.close(sock);
            return error.BindFailed;
        };

        self.sock = sock;

        // Bootstrap from well-known nodes
        self.bootstrap() catch |err| {
            log.warn("DHT bootstrap failed: {}", .{err});
        };
    }

    fn bootstrap(self: *Dht) !void {
        for (bootstrap_nodes) |bn| {
            const addr_list = std.net.getAddressList(self.allocator, bn.host, bn.port) catch continue;
            defer addr_list.deinit();

            for (addr_list.addrs) |addr| {
                if (addr.any.family == std.posix.AF.INET) {
                    self.sendFindNode(addr, self.our_id) catch continue;
                    break;
                }
            }
        }

        // Wait for responses
        self.processResponses(3) catch {};
    }

    /// Query the DHT for peers with a given info_hash.
    /// Returns a list of peers found.
    pub fn getPeers(
        self: *Dht,
        allocator: Allocator,
        info_hash: [id_len]u8,
    ) ![]tracker_mod.Peer {
        var peers: std.ArrayList(tracker_mod.Peer) = .empty;
        errdefer peers.deinit(allocator);

        // Find closest nodes to the info_hash
        var closest = self.findClosest(info_hash, k);

        // Send get_peers to each closest node
        for (closest.items) |node| {
            self.sendGetPeers(node.address, info_hash) catch continue;
        }
        closest.deinit(self.allocator);

        // Also query bootstrap nodes directly
        for (bootstrap_nodes) |bn| {
            const addr_list = std.net.getAddressList(self.allocator, bn.host, bn.port) catch continue;
            defer addr_list.deinit();
            for (addr_list.addrs) |addr| {
                if (addr.any.family == std.posix.AF.INET) {
                    self.sendGetPeers(addr, info_hash) catch continue;
                    break;
                }
            }
        }

        // Iterative lookup: collect responses and query closer nodes we discover.
        var recv_buf: [8192]u8 = undefined;
        const sock = self.sock orelse return peers.toOwnedSlice(allocator) catch return error.OutOfMemory;

        var iterations: usize = 0;
        while (iterations < 3) : (iterations += 1) {
            // Drain responses for this iteration
            var rounds: usize = 0;
            while (rounds < 8) : (rounds += 1) {
                var src_addr: std.posix.sockaddr = undefined;
                var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
                const n = std.posix.recvfrom(sock, &recv_buf, 0, &src_addr, &addr_len) catch break;
                if (n == 0) break;

                // Parse response
                const resp = bencode.decode(allocator, recv_buf[0..n]) catch continue;
                defer resp.deinit(allocator);

                // Check for "values" (peers)
                if (resp.dictGet("r")) |r_dict| {
                    if (r_dict.dictGet("values")) |values| {
                        if (values.asList()) |peer_list| {
                            for (peer_list) |peer_val| {
                                if (peer_val.asString()) |compact| {
                                    if (compact.len == 6) {
                                        const peer = tracker_mod.Peer{
                                            .ip = .{ compact[0], compact[1], compact[2], compact[3] },
                                            .port = @as(u16, compact[4]) << 8 | @as(u16, compact[5]),
                                        };
                                        peers.append(allocator, peer) catch continue;
                                    }
                                }
                            }
                        }
                    }

                    // Process "nodes" for routing table
                    if (r_dict.dictGet("nodes")) |nodes_val| {
                        if (nodes_val.asString()) |compact_nodes| {
                            self.addCompactNodes(compact_nodes);
                        }
                    }
                }
            }

            // If we found peers, we're done
            if (peers.items.len > 0) break;

            // Otherwise, query the closer nodes we just learned about
            var next_closest = self.findClosest(info_hash, k);
            defer next_closest.deinit(self.allocator);
            if (next_closest.items.len == 0) break;

            for (next_closest.items) |node| {
                self.sendGetPeers(node.address, info_hash) catch continue;
            }
        }

        return peers.toOwnedSlice(allocator) catch return error.OutOfMemory;
    }

    fn processResponses(self: *Dht, max_rounds: usize) !void {
        var recv_buf: [8192]u8 = undefined;
        const sock = self.sock orelse return;

        var rounds: usize = 0;
        while (rounds < max_rounds) : (rounds += 1) {
            var src_addr: std.posix.sockaddr = undefined;
            var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
            const n = std.posix.recvfrom(sock, &recv_buf, 0, &src_addr, &addr_len) catch break;
            if (n == 0) break;

            const resp = bencode.decode(self.allocator, recv_buf[0..n]) catch continue;
            defer resp.deinit(self.allocator);

            if (resp.dictGet("r")) |r_dict| {
                if (r_dict.dictGet("nodes")) |nodes_val| {
                    if (nodes_val.asString()) |compact_nodes| {
                        self.addCompactNodes(compact_nodes);
                    }
                }
            }
        }
    }

    fn addCompactNodes(self: *Dht, compact: []const u8) void {
        // Each node: 20-byte ID + 4-byte IP + 2-byte port = 26 bytes
        if (compact.len % 26 != 0) return;
        const count = compact.len / 26;

        for (0..count) |i| {
            const off = i * 26;
            var node_id: [id_len]u8 = undefined;
            @memcpy(&node_id, compact[off .. off + 20]);

            const ip = [4]u8{ compact[off + 20], compact[off + 21], compact[off + 22], compact[off + 23] };
            const port = @as(u16, compact[off + 24]) << 8 | @as(u16, compact[off + 25]);

            if (port == 0) continue;

            const addr = std.net.Address.initIp4(ip, port);
            self.addNode(.{ .id = node_id, .address = addr });
        }
    }

    fn addNode(self: *Dht, node: Node) void {
        const dist = distance(self.our_id, node.id);
        const bucket_idx = bucketIndex(dist);
        if (bucket_idx >= 160) return;

        var bucket = &self.buckets[bucket_idx];

        // Check if already in bucket
        for (bucket.items) |existing| {
            if (std.mem.eql(u8, &existing.id, &node.id)) return;
        }

        if (bucket.items.len < k) {
            bucket.append(self.allocator, node) catch {};
        }
    }

    fn findClosest(self: *Dht, target: [id_len]u8, count: usize) std.ArrayList(Node) {
        var result: std.ArrayList(Node) = .empty;

        // Collect all nodes and sort by distance to target
        for (&self.buckets) |*bucket| {
            for (bucket.items) |node| {
                result.append(self.allocator, node) catch continue;
            }
        }

        // Sort by XOR distance to target
        if (result.items.len > 1) {
            std.mem.sort(Node, result.items, target, struct {
                fn cmp(tgt: [id_len]u8, a: Node, b: Node) bool {
                    const da = distance(tgt, a.id);
                    const db = distance(tgt, b.id);
                    return std.mem.order(u8, &da, &db) == .lt;
                }
            }.cmp);
        }

        // Trim to count
        if (result.items.len > count) {
            result.shrinkRetainingCapacity(count);
        }

        return result;
    }

    fn sendFindNode(self: *Dht, addr: std.net.Address, target: [id_len]u8) !void {
        // Use bencode encoder for correctness
        var args_entries: [2]bencode.Value.DictEntry = undefined;
        args_entries[0] = .{ .key = "id", .value = .{ .string = &self.our_id } };
        args_entries[1] = .{ .key = "target", .value = .{ .string = &target } };

        // Keys sorted: a, q, t, y
        var top_entries: [4]bencode.Value.DictEntry = undefined;
        top_entries[0] = .{ .key = "a", .value = .{ .dict = &args_entries } };
        top_entries[1] = .{ .key = "q", .value = .{ .string = "find_node" } };
        top_entries[2] = .{ .key = "t", .value = .{ .string = "fn" } };
        top_entries[3] = .{ .key = "y", .value = .{ .string = "q" } };

        const msg = bencode.encode(self.allocator, .{ .dict = &top_entries }) catch return;
        defer self.allocator.free(msg);

        const sock = self.sock orelse return;
        _ = std.posix.sendto(sock, msg, 0, &addr.any, @sizeOf(std.posix.sockaddr.in)) catch {};
    }

    fn sendGetPeers(self: *Dht, addr: std.net.Address, info_hash: [id_len]u8) !void {
        var args_entries: [2]bencode.Value.DictEntry = undefined;
        args_entries[0] = .{ .key = "id", .value = .{ .string = &self.our_id } };
        args_entries[1] = .{ .key = "info_hash", .value = .{ .string = &info_hash } };

        var top_entries: [4]bencode.Value.DictEntry = undefined;
        top_entries[0] = .{ .key = "a", .value = .{ .dict = &args_entries } };
        top_entries[1] = .{ .key = "q", .value = .{ .string = "get_peers" } };
        top_entries[2] = .{ .key = "t", .value = .{ .string = "gp" } };
        top_entries[3] = .{ .key = "y", .value = .{ .string = "q" } };

        const msg = bencode.encode(self.allocator, .{ .dict = &top_entries }) catch return;
        defer self.allocator.free(msg);

        const sock = self.sock orelse return;
        _ = std.posix.sendto(sock, msg, 0, &addr.any, @sizeOf(std.posix.sockaddr.in)) catch {};
    }
};

// --- Tests ---

test "XOR distance" {
    const a = [_]u8{0xFF} ** 20;
    const b = [_]u8{0x00} ** 20;
    const dist = distance(a, b);
    try std.testing.expectEqual(@as(u8, 0xFF), dist[0]);
}

test "bucket index" {
    // Distance with first bit set = bucket 0
    var dist = [_]u8{0} ** 20;
    dist[0] = 0x80;
    try std.testing.expectEqual(@as(u8, 0), bucketIndex(dist));

    // Distance with bit 8 set = bucket 8
    dist[0] = 0;
    dist[1] = 0x80;
    try std.testing.expectEqual(@as(u8, 8), bucketIndex(dist));

    // All zeros = bucket 159
    dist[1] = 0;
    try std.testing.expectEqual(@as(u8, 159), bucketIndex(dist));
}

test "DHT init and deinit" {
    const allocator = std.testing.allocator;
    var dht = Dht.init(allocator, 16881);
    defer dht.deinit();
    try std.testing.expectEqual(@as(usize, 20), dht.our_id.len);
}

test "add compact nodes" {
    const allocator = std.testing.allocator;
    var dht = Dht.init(allocator, 16881);
    defer dht.deinit();

    // Build a compact node entry: 20 bytes ID + 4 bytes IP + 2 bytes port
    var compact: [26]u8 = undefined;
    @memset(compact[0..20], 0xAA); // node ID
    compact[20] = 192;
    compact[21] = 168;
    compact[22] = 1;
    compact[23] = 1;
    compact[24] = 0x1A; // port 6881 big-endian
    compact[25] = 0xE1;

    dht.addCompactNodes(&compact);

    // Should have added one node to some bucket
    var total: usize = 0;
    for (&dht.buckets) |*b| {
        total += b.items.len;
    }
    try std.testing.expectEqual(@as(usize, 1), total);
}
