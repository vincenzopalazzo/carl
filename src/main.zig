const std = @import("std");
const carl = @import("carl");

const log = std.log.scoped(.cli);

/// Configure std.log: show info and above, use default stderr output.
pub const std_options: std.Options = .{
    .log_level = .debug,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout = std.fs.File.stdout().deprecatedWriter();

    if (args.len < 2) {
        printUsage();
        std.process.exit(1);
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "info")) {
        if (args.len < 3) {
            log.err("usage: carl info <file.torrent>", .{});
            std.process.exit(1);
        }
        try cmdInfo(allocator, stdout, args[2]);
    } else if (std.mem.eql(u8, command, "announce")) {
        if (args.len < 3) {
            log.err("usage: carl announce <file.torrent>", .{});
            std.process.exit(1);
        }
        try cmdAnnounce(allocator, stdout, args[2], parseProxy(args[3..]));
    } else if (std.mem.eql(u8, command, "download")) {
        if (args.len < 3) {
            log.err("usage: carl download <source> [--output-dir <dir>] [--port <port>]", .{});
            std.process.exit(1);
        }
        // Reassemble magnet URIs that the shell may have split on '&'.
        // e.g. magnet:?xt=...&dn=... becomes multiple argv entries when unquoted.
        // Note: consumed fragments remain in args[3..] but are harmless —
        // parseFlag only matches "--output-dir" / "--port" which can't collide.
        const source = blk: {
            if (!std.mem.startsWith(u8, args[2], "magnet:")) break :blk args[2];
            var parts: std.ArrayList(u8) = .empty;
            defer parts.deinit(allocator);
            parts.appendSlice(allocator, args[2]) catch @panic("OOM");
            for (args[3..]) |a| {
                if (std.mem.startsWith(u8, a, "--")) break;
                parts.append(allocator, '&') catch @panic("OOM");
                parts.appendSlice(allocator, a) catch @panic("OOM");
            }
            break :blk @as([]const u8, allocator.dupe(u8, parts.items) catch @panic("OOM"));
        };
        const output_dir = parseFlag(args[3..], "--output-dir") orelse ".";
        const port = parsePort(args[3..]);
        const want_nostr = parseFlagPresent(args[3..], "--nostr");
        try cmdDownload(allocator, source, output_dir, port, parseProxy(args[3..]), want_nostr);
    } else if (std.mem.eql(u8, command, "seed")) {
        if (args.len < 4) {
            log.err("usage: carl seed <file.torrent> <data-dir> [--port <port>] [--nostr] [--external-ip <ip>]", .{});
            std.process.exit(1);
        }
        const port = parsePort(args[4..]);
        const want_nostr = parseFlagPresent(args[4..], "--nostr");
        const external_ip = parseFlag(args[4..], "--external-ip");
        const description = parseFlag(args[4..], "--description") orelse "";
        try cmdSeed(allocator, args[2], args[3], port, parseProxy(args[4..]), want_nostr, external_ip, description);
    } else if (std.mem.eql(u8, command, "search")) {
        if (args.len < 3) {
            log.err("usage: carl search <query> [--limit <n>] [--relay <url>]", .{});
            std.process.exit(1);
        }
        const limit = parseUnsignedFlag(args[3..], "--limit", 50);
        const single_relay = parseFlag(args[3..], "--relay");
        try cmdSearch(allocator, stdout, args[2], limit, single_relay);
    } else if (std.mem.eql(u8, command, "nostr-keygen")) {
        try cmdNostrKeygen(allocator, stdout);
    } else {
        log.err("unknown command: {s}", .{command});
        std.process.exit(1);
    }
}

fn printUsage() void {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    stderr.print(
        \\usage: carl <command> [args]
        \\
        \\commands:
        \\  info <file.torrent>                              show torrent metadata
        \\  announce <file.torrent> [--proxy url]            query tracker for peers
        \\  download <source> [--output-dir d] [--port p] [--proxy url] [--nostr]
        \\           source: file.torrent, magnet:?..., or http(s):// URL
        \\           --nostr: also subscribe to nostr peer-announce events
        \\  seed <file.torrent> <data-dir> [--port p] [--proxy url] [--nostr] [--external-ip <ip>] [--description "..."]
        \\           --nostr: publish NIP-35 torrent event + peer-announce
        \\           --external-ip: required with --nostr; the IP peers should dial
        \\  search <query> [--limit n] [--relay <wss://...>]
        \\           search nostr relays for kind-2003 torrent events
        \\  nostr-keygen                                     generate a fresh nostr key
        \\
        \\  --proxy url   route peers and HTTP trackers through a proxy. Forms:
        \\                socks5h://[user:pass@]host:port  (remote DNS, no leak)
        \\                socks5://[user:pass@]host:port   (local DNS)
        \\                http://[user:pass@]host:port     (HTTP CONNECT)
        \\                When set, DHT, UDP trackers, web seeds, and incoming
        \\                peers are disabled for anonymity.
        \\
    , .{}) catch {};
}

fn readTorrent(allocator: std.mem.Allocator, path: []const u8) carl.metainfo.Metainfo {
    const data = std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch |err| {
        log.err("cannot read '{s}': {}", .{ path, err });
        std.process.exit(1);
    };
    defer allocator.free(data);

    return carl.metainfo.parse(allocator, data) catch |err| {
        log.err("invalid torrent file: {}", .{err});
        std.process.exit(1);
    };
}

fn cmdInfo(allocator: std.mem.Allocator, stdout: anytype, path: []const u8) !void {
    const mi = readTorrent(allocator, path);
    defer mi.deinit(allocator);

    try stdout.print("name:         {s}\n", .{mi.name});
    try stdout.print("announce:     {s}\n", .{mi.announce});
    try stdout.print("piece length: {d}\n", .{mi.piece_length});
    try stdout.print("pieces:       {d}\n", .{mi.pieces.len / 20});

    if (mi.comment) |c| try stdout.print("comment:      {s}\n", .{c});
    if (mi.created_by) |c| try stdout.print("created by:   {s}\n", .{c});
    if (mi.creation_date) |ts| try stdout.print("created:      {d}\n", .{ts});

    const hash = carl.metainfo.infoHash(mi.raw_info);
    try stdout.print("info hash:    ", .{});
    for (hash) |byte| {
        try stdout.print("{x:0>2}", .{byte});
    }
    try stdout.print("\n", .{});

    try stdout.print("\nfiles ({d}):\n", .{mi.files.len});
    for (mi.files) |file| {
        try stdout.print("  ", .{});
        for (file.path, 0..) |comp, j| {
            if (j > 0) try stdout.print("/", .{});
            try stdout.print("{s}", .{comp});
        }
        try stdout.print(" ({d} bytes)\n", .{file.length});
    }
}

fn cmdAnnounce(allocator: std.mem.Allocator, stdout: anytype, path: []const u8, proxy: ?carl.proxy.Proxy) !void {
    const mi = readTorrent(allocator, path);
    defer mi.deinit(allocator);

    const info_hash = carl.metainfo.infoHash(mi.raw_info);

    var peer_id: [20]u8 = undefined;
    @memcpy(peer_id[0..8], "-CA0010-");
    std.crypto.random.bytes(peer_id[8..]);

    log.info("announcing to {s}...", .{mi.announce});

    const resp = carl.tracker.announce(allocator, mi.announce, .{
        .info_hash = info_hash,
        .peer_id = peer_id,
        .port = 6881,
        .uploaded = 0,
        .downloaded = 0,
        .left = 0,
        .compact = true,
        .event = .started,
    }, proxy) catch |err| {
        log.err("tracker announce failed: {}", .{err});
        std.process.exit(1);
    };
    defer resp.deinit(allocator);

    if (resp.failure_reason) |reason| {
        log.err("tracker error: {s}", .{reason});
        std.process.exit(1);
    }

    try stdout.print("interval:     {d}s\n", .{resp.interval});
    if (resp.complete) |c| try stdout.print("seeders:      {d}\n", .{c});
    if (resp.incomplete) |i| try stdout.print("leechers:     {d}\n", .{i});

    try stdout.print("\npeers ({d}):\n", .{resp.peers.len});
    for (resp.peers) |peer| {
        try stdout.print("  {d}.{d}.{d}.{d}:{d}\n", .{
            peer.ip[0], peer.ip[1], peer.ip[2], peer.ip[3], peer.port,
        });
    }
}

fn cmdDownload(allocator: std.mem.Allocator, source: []const u8, output_dir: []const u8, port: u16, proxy: ?carl.proxy.Proxy, want_nostr: bool) !void {
    if (std.mem.startsWith(u8, source, "magnet:")) {
        // Magnet link
        const ml = carl.magnet.parse(allocator, source) catch |err| {
            log.err("invalid magnet link: {}", .{err});
            std.process.exit(1);
        };
        defer ml.deinit(allocator);

        log.info("magnet link parsed", .{});
        if (ml.name) |n| log.info("name: {s}", .{n});

        const announce = if (ml.trackers.len > 0)
            allocator.dupe(u8, ml.trackers[0]) catch {
                std.process.exit(1);
            }
        else blk: {
            // Trackerless magnet -- will use DHT for peer discovery
            log.info("no trackers in magnet link, will use DHT", .{});
            break :blk allocator.dupe(u8, "") catch {
                std.process.exit(1);
            };
        };

        const name = if (ml.name) |n|
            allocator.dupe(u8, n) catch {
                std.process.exit(1);
            }
        else
            allocator.dupe(u8, "unknown") catch {
                std.process.exit(1);
            };

        var announce_list: ?[]const []const []const u8 = null;
        if (ml.trackers.len > 1) {
            const tier = allocator.alloc([]const u8, ml.trackers.len) catch {
                std.process.exit(1);
            };
            for (ml.trackers, 0..) |t, i| {
                tier[i] = allocator.dupe(u8, t) catch {
                    std.process.exit(1);
                };
            }
            const tiers = allocator.alloc([]const []const u8, 1) catch {
                std.process.exit(1);
            };
            tiers[0] = tier;
            announce_list = tiers;
        }

        const empty_path = allocator.alloc([]const u8, 1) catch {
            std.process.exit(1);
        };
        empty_path[0] = allocator.dupe(u8, name) catch {
            std.process.exit(1);
        };
        const empty_files = allocator.alloc(carl.metainfo.FileInfo, 1) catch {
            std.process.exit(1);
        };
        empty_files[0] = .{ .length = 0, .path = empty_path };

        const mi = carl.metainfo.Metainfo{
            .announce = announce,
            .announce_list = announce_list,
            .name = name,
            .piece_length = 0,
            .pieces = &.{},
            .files = empty_files,
            .comment = null,
            .creation_date = null,
            .created_by = null,
            .raw_info = &.{},
            .url_list = null,
        };
        defer mi.deinit(allocator);

        std.fs.cwd().makePath(output_dir) catch {};
        var session = carl.session.Session.init(allocator, mi, output_dir, .download, port, proxy) catch |err| {
            log.err("failed to initialize session: {}", .{err});
            std.process.exit(1);
        };
        defer session.deinit();
        session.info_hash = ml.info_hash; // Use magnet's hash, not SHA1("")
        session.metadata_download = carl.extension.MetadataDownload.init(allocator, ml.info_hash);
        session.metadata_only = true;
        if (want_nostr) {
            collectNostrPeers(allocator, ml.info_hash, &session);
        }
        session.run() catch |err| {
            log.err("session failed: {}", .{err});
            std.process.exit(1);
        };
    } else if (std.mem.startsWith(u8, source, "http://") or std.mem.startsWith(u8, source, "https://")) {
        // HTTP URL
        log.info("downloading torrent from {s}...", .{source});
        const torrent_data = fetchUrl(allocator, source, proxy) catch |err| {
            log.err("failed to download torrent: {}", .{err});
            std.process.exit(1);
        };
        defer allocator.free(torrent_data);

        const mi = carl.metainfo.parse(allocator, torrent_data) catch |err| {
            log.err("invalid torrent file: {}", .{err});
            std.process.exit(1);
        };
        defer mi.deinit(allocator);
        startDownload(allocator, mi, output_dir, port, proxy, want_nostr);
    } else {
        // File path
        const mi = readTorrent(allocator, source);
        defer mi.deinit(allocator);
        startDownload(allocator, mi, output_dir, port, proxy, want_nostr);
    }
}

fn startDownload(allocator: std.mem.Allocator, mi: carl.metainfo.Metainfo, output_dir: []const u8, port: u16, proxy: ?carl.proxy.Proxy, want_nostr: bool) void {
    std.fs.cwd().makePath(output_dir) catch {};
    var session = carl.session.Session.init(allocator, mi, output_dir, .download, port, proxy) catch |err| {
        log.err("failed to initialize session: {}", .{err});
        std.process.exit(1);
    };
    defer session.deinit();
    if (want_nostr) {
        const info_hash = carl.metainfo.infoHash(mi.raw_info);
        collectNostrPeers(allocator, info_hash, &session);
    }
    session.run() catch |err| {
        log.err("session failed: {}", .{err});
        std.process.exit(1);
    };
}

fn fetchUrl(allocator: std.mem.Allocator, url: []const u8, proxy: ?carl.proxy.Proxy) ![]u8 {
    // Route the initial .torrent fetch through the proxy too, so it doesn't
    // leak the real IP. HTTPS torrent URLs are not yet supported over a proxy.
    if (proxy) |px| {
        return carl.proxy.httpGet(allocator, px, url, null) catch |err| {
            log.err("HTTP fetch via proxy error: {}", .{err});
            return error.HttpFailed;
        };
    }

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();
    var response_body: std.ArrayList(u8) = .empty;
    defer response_body.deinit(allocator);
    var adapt_buf: [4096]u8 = undefined;
    const deprecated_writer = response_body.writer(allocator);
    var adapter = deprecated_writer.adaptToNewApi(&adapt_buf);
    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &adapter.new_interface,
    }) catch |err| {
        log.err("HTTP fetch error: {}", .{err});
        return error.HttpFailed;
    };

    // Flush any remaining buffered data from the adapter
    const buffered = adapter.new_interface.buffered();
    if (buffered.len > 0) {
        response_body.appendSlice(allocator, buffered) catch return error.HttpFailed;
    }

    if (result.status != .ok) return error.HttpFailed;
    if (response_body.items.len == 0) return error.HttpFailed;
    return response_body.toOwnedSlice(allocator);
}

fn cmdSeed(
    allocator: std.mem.Allocator,
    torrent_path: []const u8,
    data_dir: []const u8,
    port: u16,
    proxy: ?carl.proxy.Proxy,
    want_nostr: bool,
    external_ip: ?[]const u8,
    description: []const u8,
) !void {
    const mi = readTorrent(allocator, torrent_path);
    defer mi.deinit(allocator);

    if (want_nostr) {
        if (external_ip == null) {
            log.err("--nostr requires --external-ip <ip> so peers know how to dial you", .{});
            std.process.exit(1);
        }
        const ip = parseIpv4(external_ip.?) orelse {
            log.err("invalid --external-ip: {s}", .{external_ip.?});
            std.process.exit(1);
        };
        // Run the seeder's own IP through the same safety filter we apply to
        // peers we'd download from. Publishing a peer-announce for 127.0.0.1
        // or 192.168.x.y is always a mistake — every receiving carl will
        // reject it in peer_announce.parse, so we may as well catch it here
        // with a useful error instead of silently emitting a dud event.
        if (!carl.peer_announce.isRoutable(ip)) {
            log.err(
                "--external-ip {d}.{d}.{d}.{d} is not a routable public address; refusing to publish peer-announce",
                .{ ip[0], ip[1], ip[2], ip[3] },
            );
            std.process.exit(1);
        }
        publishNostr(allocator, mi, ip, port, description) catch |err| {
            log.warn("nostr publish failed: {} (continuing seed)", .{err});
        };
    }

    var session = carl.session.Session.init(allocator, mi, data_dir, .seed, port, proxy) catch |err| {
        log.err("failed to initialize session: {}", .{err});
        std.process.exit(1);
    };
    defer session.deinit();

    session.run() catch |err| {
        log.err("session failed: {}", .{err});
        std.process.exit(1);
    };
}

// -------------------------------------------------------------------------
// `carl search`
// -------------------------------------------------------------------------

fn cmdSearch(
    allocator: std.mem.Allocator,
    stdout: anytype,
    query: []const u8,
    limit: u32,
    single_relay: ?[]const u8,
) !void {
    var relay_urls: [][]const u8 = undefined;
    var relays_owned = false;
    if (single_relay) |r| {
        const arr = try allocator.alloc([]const u8, 1);
        arr[0] = r;
        relay_urls = arr;
    } else {
        relay_urls = carl.nostr_config.readRelays(allocator) catch |err| {
            log.err("could not read relay config: {}", .{err});
            std.process.exit(1);
        };
        relays_owned = true;
    }
    defer {
        if (relays_owned) {
            carl.nostr_config.freeRelays(allocator, relay_urls);
        } else {
            allocator.free(relay_urls);
        }
    }

    log.info("searching {d} relays for '{s}' (limit {d})", .{ relay_urls.len, query, limit });

    // Use the relay's NIP-50 `search` filter where available; if a relay
    // doesn't support it, it'll just return events matching `kinds` and we
    // filter client-side.
    const filter: carl.nostr.Filter = .{
        .kinds = &[_]u32{carl.nip35.kind_torrent},
        .limit = limit,
        .search = query,
    };

    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        seen.deinit();
    }

    var found_any = false;
    for (relay_urls) |url| {
        var r = carl.relay.Relay.connect(allocator, url) catch |err| {
            log.warn("relay {s}: {}", .{ url, err });
            continue;
        };
        defer r.deinit();

        const events = carl.relay.subscribeAndCollect(allocator, &r, filter, .{
            .timeout_ms = 15_000,
            .max_events = @as(usize, @intCast(limit)) * 4,
            .verify_signatures = true,
        }) catch |err| {
            log.warn("relay {s} search failed: {}", .{ url, err });
            continue;
        };
        defer {
            for (events) |e| e.deinit(allocator);
            allocator.free(events);
        }

        for (events) |ev| {
            // Dedupe by event id.
            var id_hex_buf: [carl.nostr.event_id_len * 2]u8 = undefined;
            carl.secp.toHex(&ev.id, &id_hex_buf);
            const id_hex_owned = try allocator.dupe(u8, &id_hex_buf);
            const gop = seen.getOrPut(id_hex_owned) catch {
                allocator.free(id_hex_owned);
                continue;
            };
            if (gop.found_existing) {
                allocator.free(id_hex_owned);
                continue;
            }

            const entry = carl.nip35.parseEvent(allocator, ev) catch continue;
            defer entry.deinit(allocator);

            // Filter client-side too in case the relay ignored `search`.
            if (!textMatches(entry.title, query) and !textMatches(entry.description, query)) continue;

            found_any = true;
            try printSearchResult(stdout, entry);
        }
    }

    if (!found_any) {
        try stdout.print("no results\n", .{});
    }
}

fn textMatches(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    // Case-insensitive ASCII substring search.
    if (haystack.len < needle.len) return false;
    const max_off = haystack.len - needle.len + 1;
    var off: usize = 0;
    while (off < max_off) : (off += 1) {
        var match = true;
        for (needle, 0..) |n, i| {
            const h = std.ascii.toLower(haystack[off + i]);
            const l = std.ascii.toLower(n);
            if (h != l) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn printSearchResult(stdout: anytype, entry: carl.nip35.TorrentEntry) !void {
    var ih_hex: [40]u8 = undefined;
    carl.secp.toHex(&entry.info_hash, &ih_hex);

    var total: u64 = 0;
    for (entry.files) |f| total += f.size;

    try stdout.print("─" ** 60 ++ "\n", .{});
    try stdout.print("title:     {s}\n", .{entry.title});
    try stdout.print("infohash:  {s}\n", .{ih_hex});
    try stdout.print("files:     {d}, total {d} bytes\n", .{ entry.files.len, total });
    try stdout.print("trackers:  {d}\n", .{entry.trackers.len});
    if (entry.description.len > 0) {
        try stdout.print("desc:      {s}\n", .{entry.description});
    }
    try stdout.print("magnet:    magnet:?xt=urn:btih:{s}\n", .{ih_hex});
}

// -------------------------------------------------------------------------
// `carl nostr-keygen`
// -------------------------------------------------------------------------

fn cmdNostrKeygen(allocator: std.mem.Allocator, stdout: anytype) !void {
    const sk = carl.secp.generateSecretKey() catch {
        log.err("failed to generate secret key", .{});
        std.process.exit(1);
    };
    const pk = carl.secp.publicKeyFromSecret(sk) catch {
        log.err("failed to derive public key", .{});
        std.process.exit(1);
    };

    const nsec = carl.nostr_config.writeSecretKey(allocator, sk) catch |err| {
        log.err("failed to save key: {}", .{err});
        std.process.exit(1);
    };
    defer allocator.free(nsec);

    const npub = try carl.nip19.encode32(allocator, .npub, pk);
    defer allocator.free(npub);

    try stdout.print("wrote nsec (secret key) to your config dir\n", .{});
    try stdout.print("npub: {s}\n", .{npub});
    try stdout.print("\nkeep your nsec private. anyone with it can publish as you.\n", .{});
}

// -------------------------------------------------------------------------
// Nostr helpers for seed/download
// -------------------------------------------------------------------------

fn publishNostr(
    allocator: std.mem.Allocator,
    mi: carl.metainfo.Metainfo,
    external_ip: [4]u8,
    port: u16,
    description: []const u8,
) !void {
    const sk = carl.nostr_config.readSecretKey(allocator) catch |err| {
        switch (err) {
            error.NoKey => {
                log.err("no nostr key configured. run `carl nostr-keygen` first", .{});
                return error.NoKey;
            },
            else => return err,
        }
    };
    const pk = try carl.secp.publicKeyFromSecret(sk);
    const info_hash = carl.metainfo.infoHash(mi.raw_info);

    var torrent_ev = try carl.nip35.buildFromMetainfo(allocator, sk, pk, mi, info_hash, description);
    defer torrent_ev.deinit(allocator);
    var announce_ev = try carl.peer_announce.build(allocator, sk, pk, info_hash, external_ip, port);
    defer announce_ev.deinit(allocator);

    const relay_urls = try carl.nostr_config.readRelays(allocator);
    defer carl.nostr_config.freeRelays(allocator, relay_urls);

    var torrent_acks: usize = 0;
    var announce_acks: usize = 0;
    for (relay_urls) |url| {
        var r = carl.relay.Relay.connect(allocator, url) catch |err| {
            log.warn("nostr publish: {s}: {}", .{ url, err });
            continue;
        };
        defer r.deinit();
        if (carl.relay.publishAndWait(allocator, &r, torrent_ev, 5_000)) {
            log.info("published kind-2003 to {s}", .{url});
            torrent_acks += 1;
        }
        if (carl.relay.publishAndWait(allocator, &r, announce_ev, 5_000)) {
            log.info("published kind-30078 peer-announce to {s}", .{url});
            announce_acks += 1;
        }
    }
    log.info(
        "nostr publish: kind-2003 {d}/{d} relays, kind-30078 {d}/{d} relays",
        .{ torrent_acks, relay_urls.len, announce_acks, relay_urls.len },
    );
}

fn collectNostrPeers(
    allocator: std.mem.Allocator,
    info_hash: [20]u8,
    session: *carl.session.Session,
) void {
    var ih_hex: [40]u8 = undefined;
    carl.secp.toHex(&info_hash, &ih_hex);

    const relay_urls = carl.nostr_config.readRelays(allocator) catch return;
    defer carl.nostr_config.freeRelays(allocator, relay_urls);

    var values_arr = [_][]const u8{&ih_hex};
    var tag_filters = [_]carl.nostr.Filter.TagFilter{.{ .letter = 'd', .values = &values_arr }};
    const filter: carl.nostr.Filter = .{
        .kinds = &[_]u32{carl.peer_announce.kind_peer_announce},
        .tags = &tag_filters,
        .limit = 200,
    };

    var added: usize = 0;
    for (relay_urls) |url| {
        var r = carl.relay.Relay.connect(allocator, url) catch |err| {
            log.debug("nostr peer-discover: {s}: {}", .{ url, err });
            continue;
        };
        defer r.deinit();
        const events = carl.relay.subscribeAndCollect(allocator, &r, filter, .{
            .timeout_ms = 10_000,
            .max_events = 200,
            .verify_signatures = true,
        }) catch continue;
        defer {
            for (events) |e| e.deinit(allocator);
            allocator.free(events);
        }
        for (events) |ev| {
            const ann = carl.peer_announce.parse(ev) catch continue;
            if (!std.mem.eql(u8, &ann.info_hash, &info_hash)) continue;
            if (added >= 50) break; // cap how many nostr peers we proactively dial
            const addr = std.net.Address.initIp4(ann.ip, ann.port);
            session.connectDirectPeer(addr) catch continue;
            added += 1;
        }
    }
    if (added > 0) log.info("added {d} peers from nostr", .{added});
}

fn parseIpv4(s: []const u8) ?[4]u8 {
    var result: [4]u8 = undefined;
    var octet: usize = 0;
    var start: usize = 0;
    for (s, 0..) |c, i| {
        if (c == '.') {
            if (octet >= 3) return null;
            const v = std.fmt.parseUnsigned(u8, s[start..i], 10) catch return null;
            result[octet] = v;
            octet += 1;
            start = i + 1;
        }
    }
    if (octet != 3) return null;
    const v = std.fmt.parseUnsigned(u8, s[start..], 10) catch return null;
    result[3] = v;
    return result;
}

fn parseFlag(extra_args: []const [:0]u8, flag: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < extra_args.len) : (i += 1) {
        if (std.mem.eql(u8, extra_args[i], flag)) {
            return extra_args[i + 1];
        }
    }
    return null;
}

fn parsePort(extra_args: []const [:0]u8) u16 {
    const port_str = parseFlag(extra_args, "--port") orelse return 6881;
    return std.fmt.parseUnsigned(u16, port_str, 10) catch 6881;
}

/// Parse `--proxy <url>`. Exits with an error if the URL is malformed or the
/// flag is given without a value, so a typo never silently falls back to a
/// direct (de-anonymized) connection.
fn parseProxy(extra_args: []const [:0]u8) ?carl.proxy.Proxy {
    const url = parseFlag(extra_args, "--proxy") orelse {
        // `--proxy` as the last argument has no value, so parseFlag returns
        // null. Fail closed rather than running unproxied (which would leak
        // the real IP) -- distinguish "flag absent" from "flag without value".
        for (extra_args) |a| {
            if (std.mem.eql(u8, a, "--proxy")) {
                log.err("--proxy requires a URL value (e.g. socks5h://host:1080)", .{});
                std.process.exit(1);
            }
        }
        return null;
    };
    return carl.proxy.parseUrl(url) catch |err| {
        log.err("invalid --proxy URL '{s}': {}", .{ url, err });
        std.process.exit(1);
    };
}

fn parseFlagPresent(extra_args: []const [:0]u8, flag: []const u8) bool {
    for (extra_args) |a| if (std.mem.eql(u8, a, flag)) return true;
    return false;
}

fn parseUnsignedFlag(extra_args: []const [:0]u8, flag: []const u8, default: u32) u32 {
    const s = parseFlag(extra_args, flag) orelse return default;
    return std.fmt.parseUnsigned(u32, s, 10) catch default;
}

test {
    _ = @import("carl");
}
