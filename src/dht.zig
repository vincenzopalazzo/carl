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

/// Well-known bootstrap nodes. Kept deliberately broad: routers die or
/// degrade (observed in the wild: router.bittorrent.com and router.utorrent.com
/// timing out for whole residential networks while transmissionbt answers with
/// a single dead-end node). A client starting with an empty table needs
/// several live, generous routers to have a chance.
const bootstrap_nodes = [_]struct { host: []const u8, port: u16 }{
    .{ .host = "router.bittorrent.com", .port = 6881 },
    .{ .host = "dht.transmissionbt.com", .port = 6881 },
    .{ .host = "router.utorrent.com", .port = 6881 },
    .{ .host = "dht.libtorrent.org", .port = 25401 },
    .{ .host = "dht.bluetigers.club", .port = 6881 },
    .{ .host = "dht.anacrolix.link", .port = 6881 },
    .{ .host = "router.silotis.us", .port = 6881 },
    .{ .host = "dht.aelitis.com", .port = 6881 },
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

pub const AnnounceToken = struct {
    addr: std.posix.sockaddr,
    len: std.posix.socklen_t,
    token: [32]u8,
    token_len: u8,
};

/// DHT client for peer discovery.
pub const Dht = struct {
    allocator: Allocator,
    our_id: [id_len]u8,
    sock: ?std.posix.fd_t,
    port: u16,

    /// (addr, token) pairs learned from get_peers responses, used by
    /// announceSelf (BEP 5 announce_peer). Tokens are single-use-ish per
    /// node; we keep the most recent few and clear them after announcing.
    announce_tokens: [8]AnnounceToken = undefined,
    announce_token_count: usize = 0,

    /// Max nodes written to the cache file.

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
        while (iterations < 8) : (iterations += 1) {
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
                    // Capture the announce token (BEP 5): announce_peer must
                    // echo a token the node previously handed us in a
                    // get_peers response.
                    if (r_dict.dictGet("token")) |tok_val| {
                        if (tok_val.asString()) |ts| {
                            if (ts.len > 0 and ts.len <= 32 and self.announce_token_count < self.announce_tokens.len) {
                                const slot = &self.announce_tokens[self.announce_token_count];
                                slot.addr = src_addr;
                                slot.len = addr_len;
                                @memcpy(slot.token[0..ts.len], ts);
                                slot.token_len = @intCast(ts.len);
                                self.announce_token_count += 1;
                            }
                        }
                    }
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
            if (next_closest.items.len == 0) {
                next_closest.deinit(self.allocator);
                break;
            }

            for (next_closest.items) |node| {
                self.sendGetPeers(node.address, info_hash) catch continue;
            }
            next_closest.deinit(self.allocator);
        }

        return peers.toOwnedSlice(allocator) catch return error.OutOfMemory;
    }

    /// BEP 5 announce_peer: tell the nodes that issued us tokens that this
    /// client holds (or is interested in) `info_hash` and is reachable for the
    /// BitTorrent protocol on `bt_port`. Without this, a carl session is
    /// invisible to other DHT clients: they can get_peers all day and never
    /// find us. Fire-and-forget; responses are ignored (the next lookup's
    /// drain consumes them harmlessly).
    pub fn announceSelf(self: *Dht, info_hash: [id_len]u8, bt_port: u16) void {
        const sock = self.sock orelse return;
        if (bt_port == 0) return;

        for (self.announce_tokens[0..self.announce_token_count]) |*tok| {
            var a_entries: [5]bencode.Value.DictEntry = undefined;
            a_entries[0] = .{ .key = "id", .value = .{ .string = &self.our_id } };
            a_entries[1] = .{ .key = "implied_port", .value = .{ .integer = 0 } };
            a_entries[2] = .{ .key = "info_hash", .value = .{ .string = &info_hash } };
            a_entries[3] = .{ .key = "port", .value = .{ .integer = @intCast(bt_port) } };
            a_entries[4] = .{ .key = "token", .value = .{ .string = tok.token[0..tok.token_len] } };

            var top_entries: [4]bencode.Value.DictEntry = undefined;
            top_entries[0] = .{ .key = "a", .value = .{ .dict = &a_entries } };
            top_entries[1] = .{ .key = "q", .value = .{ .string = "announce_peer" } };
            top_entries[2] = .{ .key = "t", .value = .{ .string = "ap" } };
            top_entries[3] = .{ .key = "y", .value = .{ .string = "q" } };

            const msg = bencode.encode(self.allocator, .{ .dict = &top_entries }) catch continue;
            defer self.allocator.free(msg);
            _ = std.posix.sendto(sock, msg, 0, &tok.addr, tok.len) catch continue;
        }
        self.announce_token_count = 0;
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

// --- Routing-table persistence ------------------------------------------------
//
// A fresh client with an empty table is at the mercy of the well-known
// routers; several of them are chronically dead or answer with a single
// dead-end node (observed in the wild). Persisting learned nodes across
// sessions gives every later lookup a warm table, exactly like libtorrent's
// dht_state. Format: u32 LE count, then per node 20B id + 4B IPv4 + 2B BE port.
//
// All file I/O here goes through raw syscalls (std.posix.system) instead of
// std.fs: the cache is a pure optimization and must never be able to abort
// the process. std.fs wrappers contain `unreachable` branches for errno paths
// they consider impossible (EFAULT/BADF) and an inline length assert in
// toPosixPath — under the detached DHT worker a corrupted slice hit exactly
// that assert once and killed a seeder mid-lookup. Raw syscalls let us treat
// every failure as "no cache this time".

/// Max nodes written to the cache file.
pub const node_cache_max: usize = 64;

/// NUL-terminate `path` into `buf`; null when it does not fit.
fn pathZ(buf: []u8, path: []const u8) ?[*:0]const u8 {
    if (path.len + 1 > buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf.ptr);
}

/// Write up to `node_cache_max` routing-table nodes to `path`. Best-effort:
/// every failure is silently ignored.
pub fn saveNodeCache(self: *const Dht, path: []const u8) void {
    const c = std.posix.system;

    var buf: [4 + node_cache_max * 26]u8 = undefined;
    var n: usize = 0;
    outer: for (&self.buckets) |*b| {
        for (b.items) |node| {
            if (n >= node_cache_max) break :outer;
            if (node.address.any.family != std.posix.AF.INET) continue;
            @memcpy(buf[4 + n * 26 ..][0..20], &node.id);
            const ip4: [4]u8 = @bitCast(node.address.in.sa.addr);
            buf[4 + n * 26 + 20] = ip4[0];
            buf[4 + n * 26 + 21] = ip4[1];
            buf[4 + n * 26 + 22] = ip4[2];
            buf[4 + n * 26 + 23] = ip4[3];
            const port = node.address.getPort();
            buf[4 + n * 26 + 24] = @intCast(port >> 8);
            buf[4 + n * 26 + 25] = @intCast(port & 0xff);
            n += 1;
        }
    }
    if (n == 0) return;
    std.mem.writeInt(u32, buf[0..4], @intCast(n), .little);

    var pbuf: [512]u8 = undefined;
    const p = pathZ(&pbuf, path) orelse return;
    const oflags: c.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    const fd = c.openat(-100, p, oflags, @as(c.mode_t, 0o644));
    if (fd < 0) return;
    defer _ = c.close(fd);

    var off: usize = 0;
    const total = 4 + n * 26;
    while (off < total) {
        const rc = c.write(fd, buf[off..].ptr, buf[off..].len);
        if (rc <= 0) return; // error or nothing written; best-effort
        off += @intCast(rc);
    }
}

/// Load a previously saved node cache into the routing table. Returns how
/// many nodes were inserted. Missing/corrupt file is not an error.
pub fn loadNodeCache(self: *Dht, path: []const u8) usize {
    const c = std.posix.system;

    var pbuf: [512]u8 = undefined;
    const p = pathZ(&pbuf, path) orelse return 0;
    const oflags: c.O = .{ .ACCMODE = .RDONLY };
    const fd = c.openat(-100, p, oflags, @as(c.mode_t, 0));
    if (fd < 0) return 0;
    defer _ = c.close(fd);

    var hdr: [4]u8 = undefined;
    if (!readFull(c, fd, &hdr)) return 0;
    const count = std.mem.readInt(u32, &hdr, .little);
    if (count == 0 or count > 4096) return 0;

    var inserted: usize = 0;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        var entry: [26]u8 = undefined;
        if (!readFull(c, fd, &entry)) break;
        const port = (@as(u16, entry[24]) << 8) | @as(u16, entry[25]);
        if (port == 0) continue;
        var id: [id_len]u8 = undefined;
        @memcpy(&id, entry[0..20]);
        const addr = std.net.Address.initIp4(.{ entry[20], entry[21], entry[22], entry[23] }, port);
        self.addNode(.{ .id = id, .address = addr });
        inserted += 1;
    }
    return inserted;
}

fn readFull(c: anytype, fd: c_int, buf: []u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const rc = c.read(fd, buf[off..].ptr, buf[off..].len);
        if (rc <= 0) return false;
        off += @intCast(rc);
    }
    return true;
}
