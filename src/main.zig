const std = @import("std");
const carl = @import("carl");

const log = std.log.scoped(.cli);

/// Configure std.log: show info and above, use default stderr output.
pub const std_options: std.Options = .{
    .log_level = .debug,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    try carl.secp.init(init.io);

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const nostr_ctx: carl.nostr_config.Context = .{
        .io = init.io,
        .home = init.environ_map.get("HOME"),
        .xdg_config_home = init.environ_map.get("XDG_CONFIG_HOME"),
    };

    const carl_dir = init.environ_map.get("CARL_DIR");

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    if (args.len < 2) {
        printUsage(init.io);
        std.process.exit(1);
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "info")) {
        if (args.len < 3) {
            log.err("usage: carl info <file.torrent>", .{});
            std.process.exit(1);
        }
        try cmdInfo(init.io, allocator, stdout, args[2]);
    } else if (std.mem.eql(u8, command, "announce")) {
        if (args.len < 3) {
            log.err("usage: carl announce <file.torrent>", .{});
            std.process.exit(1);
        }
        try cmdAnnounce(init.io, allocator, stdout, args[2], parseProxy(args[3..]));
    } else if (std.mem.eql(u8, command, "download")) {
        if (args.len < 3) {
            log.err("usage: carl download <source> [--output-dir <dir>] [--port <port>]", .{});
            std.process.exit(1);
        }
        // Reassemble magnet URIs that the shell may have split on '&'.
        // e.g. magnet:?xt=...&dn=... becomes multiple argv entries when unquoted.
        // Note: consumed fragments remain in args[3..] but are harmless —
        // parseFlag only matches "--output-dir" / "--port" which can't collide.
        // `source` is either a borrowed argv slice (non-magnet) or an owned
        // reassembled buffer (magnet split on '&' by the shell); only free the
        // latter.
        var source_owned = false;
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
            source_owned = true;
            break :blk @as([]const u8, allocator.dupe(u8, parts.items) catch @panic("OOM"));
        };
        defer if (source_owned) allocator.free(source);
        // Default to the unified carl work dir (shared with the daemon/GUI)
        // so downloads from any frontend land in one reseedable place.
        var output_dir_owned: ?[]u8 = null;
        defer if (output_dir_owned) |d| allocator.free(d);
        const output_dir = parseFlag(args[3..], "--output-dir") orelse blk: {
            output_dir_owned = try carl.workdir.ensure(
                nostr_ctx,
                allocator,
                carl_dir,
            );
            break :blk @as([]const u8, output_dir_owned.?);
        };
        const port = parsePort(args[3..]);
        const want_nostr = parseFlagPresent(args[3..], "--nostr");
        const want_seed = parseFlagPresent(args[3..], "--seed");
        try cmdDownload(nostr_ctx, init.io, allocator, source, output_dir, port, parseProxy(args[3..]), want_nostr, want_seed);
    } else if (std.mem.eql(u8, command, "seed")) {
        if (args.len < 3) {
            log.err("usage: carl seed <file.torrent> [data-dir] [--port p] [--nostr] [--external-ip ip] [--tor-seed] [--tor-control addr] [--tor-cookie path] [--tor-onion-port p] [--tor-socks url] [--i2p-seed] [--i2p-sam host:port] [--description \"...\"]", .{});
            std.process.exit(1);
        }
        // data-dir is optional: when omitted (next arg is a flag or absent),
        // seed from the unified carl work dir — the same directory downloads
        // land in, so anything dropped there reseeds without extra arguments.
        const has_data_dir = args.len >= 4 and !std.mem.startsWith(u8, args[3], "--");
        const flag_args = if (has_data_dir) args[4..] else args[3..];
        var data_dir_owned: ?[]u8 = null;
        defer if (data_dir_owned) |d| allocator.free(d);
        const data_dir: []const u8 = if (has_data_dir) args[3] else blk: {
            data_dir_owned = try carl.workdir.ensure(
                nostr_ctx,
                allocator,
                carl_dir,
            );
            break :blk data_dir_owned.?;
        };
        const port = parsePort(flag_args);
        const want_nostr = parseFlagPresent(flag_args, "--nostr");
        const tor_seed = parseFlagPresent(flag_args, "--tor-seed");
        const external_ip = parseFlag(flag_args, "--external-ip");
        const description = parseFlag(flag_args, "--description") orelse "";
        const tor_control = parseFlag(flag_args, "--tor-control") orelse "127.0.0.1:9051";
        const tor_cookie = parseFlag(flag_args, "--tor-cookie");
        const tor_onion_port: u16 = parsePortFlag(flag_args, "--tor-onion-port", 80);
        const tor_socks_url = parseFlag(flag_args, "--tor-socks") orelse "socks5h://127.0.0.1:9050";
        const i2p_seed = parseFlagPresent(flag_args, "--i2p-seed");
        const i2p_sam_addr = parseFlag(flag_args, "--i2p-sam") orelse "127.0.0.1:7656";
        try cmdSeed(nostr_ctx, init.io, allocator, args[2], data_dir, port, parseProxy(flag_args), want_nostr, tor_seed, i2p_seed, i2p_sam_addr, external_ip, description, .{
            .control_addr = tor_control,
            .cookie_path = tor_cookie,
            .onion_port = tor_onion_port,
            .socks_url = tor_socks_url,
        });
    } else if (std.mem.eql(u8, command, "create")) {
        if (args.len < 3) {
            log.err("usage: carl create <file-or-dir> [-o out.torrent] [-t tracker]... [--comment \"...\"] [--piece-length bytes]", .{});
            std.process.exit(1);
        }
        try cmdCreate(
            init.io,
            allocator,
            stdout,
            args[2],
            args[3..],
        );
    } else if (std.mem.eql(u8, command, "search")) {
        if (args.len < 3) {
            log.err("usage: carl search <query> [--limit <n>] [--relay <url>]", .{});
            std.process.exit(1);
        }
        const limit = parseUnsignedFlag(args[3..], "--limit", 50);
        const single_relay = parseFlag(args[3..], "--relay");
        try cmdSearch(
            nostr_ctx,
            allocator,
            stdout,
            args[2],
            limit,
            single_relay,
            parseProxy(args[3..]),
        );
    } else if (std.mem.eql(u8, command, "follow")) {
        if (args.len < 3) {
            log.err("usage: carl follow <npub|pubkey-hex> [--route direct|i2p] [--dir d] [--i2p-sam host:port] [--external-ip ip] [--interval secs]", .{});
            std.process.exit(1);
        }
        try cmdFollow(nostr_ctx, allocator, args[2], args[3..]);
    } else if (std.mem.eql(u8, command, "drive")) {
        try cmdDrive(nostr_ctx, allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "nostr-keygen")) {
        try cmdNostrKeygen(nostr_ctx, allocator, stdout);
    } else if (std.mem.eql(u8, command, "whoami")) {
        try cmdWhoami(nostr_ctx, allocator, stdout);
    } else if (std.mem.eql(u8, command, "daemon")) {
        try cmdDaemon(init.io, nostr_ctx, allocator, stdout, args[2..]);
    } else {
        log.err("unknown command: {s}", .{command});
        std.process.exit(1);
    }
}

fn printUsage(io: std.Io) void {
    std.Io.File.stderr().writeStreamingAll(io,
        \\usage: carl <command> [args]
        \\
        \\commands:
        \\  info <file.torrent>                              show torrent metadata
        \\  announce <file.torrent> [--proxy url]            query tracker for peers
        \\  download <source> [--output-dir d] [--port p] [--proxy url] [--nostr] [--seed]
        \\           source: file.torrent, magnet:?..., or http(s):// URL
        \\           --output-dir: defaults to the carl work dir (see below)
        \\           --nostr: also subscribe to nostr peer-announce events
        \\           --seed: keep seeding after the download completes
        \\                   (default: exit once the download is done)
        \\  seed <file.torrent> [data-dir] [--port p] [--proxy url] [--nostr] [--external-ip <ip>]
        \\           [--tor-seed] [--tor-control host:port] [--tor-cookie path]
        \\           [--tor-onion-port p] [--tor-socks url]
        \\           [--i2p-seed] [--i2p-sam host:port] [--description "..."]
        \\           data-dir: defaults to the carl work dir (see below)
        \\           --nostr: publish NIP-35 torrent event + peer-announce
        \\           --external-ip: public IPv4 for peer-announce (classic seeding)
        \\           --tor-seed: hidden service via Tor ControlPort; requires --nostr
        \\           --i2p-seed: inbound I2P seed via SAM (stable .b32.i2p); requires
        \\                       --nostr. SAM bridge from --i2p-sam (default 127.0.0.1:7656)
        \\  create <file-or-dir> [-o out.torrent] [-t tracker]... [--comment "..."] [--piece-length bytes]
        \\           build a .torrent from a file or directory (multi-file).
        \\           -t may repeat; trackers are optional (Nostr/DHT discovery).
        \\           -o defaults to <name>.torrent in the current directory.
        \\  search <query> [--limit n] [--relay <wss://...>]
        \\           search nostr relays for kind-2003 torrent events
        \\  follow <npub|pubkey-hex> [--route direct|i2p] [--dir d] [--i2p-sam host:port]
        \\         [--external-ip ip] [--interval secs]
        \\           mirror a publisher: download every torrent they announce on
        \\           nostr (NIP-35) and reseed it, publishing our own
        \\           peer-announce so leechers can dial this mirror.
        \\           --route i2p: download AND reseed over I2P (stable .b32.i2p
        \\           per torrent); --external-ip enables dialable direct announces.
        \\           --dir defaults to <work dir>/follow-<pubkey prefix>.
        \\  drive create <dir> --name <drive> [--route direct|i2p] [--external-ip ip] [--interval secs]
        \\  drive subscribe <npub|pubkey-hex> <drive-name> [--also <npub>]... [--dir d]
        \\         [--route direct|i2p] [--interval secs]
        \\           shared drives over nostr: `create` watches a flat folder and
        \\           publishes every file in it as a torrent plus a kind-30035
        \\           (NIP-33) drive index; `subscribe` mirrors a publisher's drive
        \\           into --dir (default <work dir>/drive-<pubkey prefix>-<name>),
        \\           converging on every index update (removals are quarantined
        \\           to .carl-drive/.trash, never unlinked). --also adds extra
        \\           writer pubkeys (multi-writer, last-writer-wins per path).
        \\           --external-ip (create): routable IPv4 for direct-route
        \\           peer-announces (like `carl follow`); without it a direct
        \\           publisher seeds but is not dialable.
        \\  nostr-keygen                                     generate a fresh nostr key
        \\  whoami                                           print the configured identity's npub
        \\  daemon [--port p] [--bt-port p] [--route direct|proxy|tor|i2p] [--socks url]
        \\         [--i2p-sam host:port] [--download-dir d] [--token tok] [--parent-pid pid]
        \\         [--tor-control host:port] [--tor-cookie path] [--tor-onion-port p]
        \\           run a localhost HTTP+WebSocket API for the desktop GUI.
        \\           --route i2p connects peers over native I2P (SAM v3); set the
        \\           SAM bridge with --i2p-sam (default 127.0.0.1:7656). See docs/i2p.md.
        \\           --tor-* configure the ControlPort used to create hidden
        \\           services for tor-route seeds (default 127.0.0.1:9051).
        \\           binds 127.0.0.1 only; every request needs the printed token
        \\           (X-Carl-Token header, or ?token= for the /ws upgrade).
        \\
        \\  --proxy url   route peers and HTTP trackers through a proxy. Forms:
        \\                socks5h://[user:pass@]host:port  (remote DNS, no leak)
        \\                socks5://[user:pass@]host:port   (local DNS)
        \\                http://[user:pass@]host:port     (HTTP CONNECT)
        \\                When set, DHT, UDP trackers, web seeds, and incoming
        \\                peers are disabled for anonymity.
        \\
        \\  work dir      the shared download + seed directory used by the CLI,
        \\                daemon, and desktop app when no directory is given:
        \\                $CARL_DIR, else the GUI's persisted download folder
        \\                setting, else ~/Downloads/carl. Drop a file there and
        \\                `carl seed <file.torrent>` (or the app) can reseed it.
        \\
    ) catch {};
}

fn readTorrent(io: std.Io, allocator: std.mem.Allocator, path: []const u8) carl.metainfo.Metainfo {
    const data = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(10 * 1024 * 1024),
    ) catch |err| {
        log.err("cannot read '{s}': {}", .{ path, err });
        std.process.exit(1);
    };
    defer allocator.free(data);

    return carl.metainfo.parse(allocator, data) catch |err| {
        log.err("invalid torrent file: {}", .{err});
        std.process.exit(1);
    };
}

fn cmdInfo(io: std.Io, allocator: std.mem.Allocator, stdout: anytype, path: []const u8) !void {
    const mi = readTorrent(io, allocator, path);
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

fn cmdAnnounce(io: std.Io, allocator: std.mem.Allocator, stdout: anytype, path: []const u8, proxy: ?carl.proxy.Proxy) !void {
    const mi = readTorrent(io, allocator, path);
    defer mi.deinit(allocator);

    const info_hash = carl.metainfo.infoHash(mi.raw_info);

    var peer_id: [20]u8 = undefined;
    @memcpy(peer_id[0..8], "-CA0010-");
    io.random(peer_id[8..]);

    log.info("announcing to {s}...", .{mi.announce});

    const resp = carl.tracker.announce(io, allocator, mi.announce, .{
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
        if (peer.host()) |h| {
            try stdout.print("  {s}:{d}\n", .{ h, peer.port });
        } else {
            try stdout.print("  {d}.{d}.{d}.{d}:{d}\n", .{
                peer.ip[0], peer.ip[1], peer.ip[2], peer.ip[3], peer.port,
            });
        }
    }
}

fn cmdDownload(ctx: carl.nostr_config.Context, io: std.Io, allocator: std.mem.Allocator, source: []const u8, output_dir: []const u8, port: u16, proxy: ?carl.proxy.Proxy, want_nostr: bool, want_seed: bool) !void {
    if (std.mem.startsWith(u8, source, "magnet:")) {
        // Magnet link
        const ml = carl.magnet.parse(allocator, source) catch |err| {
            log.err("invalid magnet link: {}", .{err});
            std.process.exit(1);
        };
        defer ml.deinit(allocator);

        log.info("magnet link parsed", .{});
        if (ml.name) |n| log.info("name: {s}", .{n});

        var merged_trackers: std.ArrayList([]const u8) = .empty;
        defer {
            for (merged_trackers.items) |t| allocator.free(t);
            merged_trackers.deinit(allocator);
        }
        for (ml.trackers) |t| {
            merged_trackers.append(allocator, try allocator.dupe(u8, t)) catch std.process.exit(1);
        }

        // One NIP-35 lookup feeds BOTH tracker enrichment and the display name,
        // so a bare magnet costs a single relay round-trip here instead of two.
        var nip35_entry: ?carl.nip35.TorrentEntry = null;
        defer if (nip35_entry) |e| e.deinit(allocator);
        if (want_nostr) {
            nip35_entry = fetchNip35Entry(ctx, allocator, ml.info_hash, proxy);
        }

        if (nip35_entry) |entry| {
            var added: usize = 0;
            for (entry.trackers) |t| {
                var dup = false;
                for (merged_trackers.items) |existing| {
                    if (std.mem.eql(u8, existing, t)) {
                        dup = true;
                        break;
                    }
                }
                if (!dup) {
                    merged_trackers.append(allocator, try allocator.dupe(u8, t)) catch std.process.exit(1);
                    added += 1;
                }
            }
            if (added > 0 and ml.trackers.len == 0) {
                log.info("enriched magnet with {d} tracker(s) from nostr", .{added});
            }
        }

        const announce = if (merged_trackers.items.len > 0)
            allocator.dupe(u8, merged_trackers.items[0]) catch {
                std.process.exit(1);
            }
        else blk: {
            log.info("no trackers in magnet link, will use DHT and nostr peers", .{});
            break :blk allocator.dupe(u8, "") catch {
                std.process.exit(1);
            };
        };

        // Borrow the title from the still-live nip35_entry; `name` dupes it.
        var display_name: ?[]const u8 = ml.name;
        if (display_name == null) {
            if (nip35_entry) |entry| {
                if (entry.title.len > 0) display_name = entry.title;
            }
        }

        const name = if (display_name) |n|
            allocator.dupe(u8, n) catch {
                std.process.exit(1);
            }
        else
            allocator.dupe(u8, "unknown") catch {
                std.process.exit(1);
            };

        var announce_list: ?[]const []const []const u8 = null;
        if (merged_trackers.items.len > 1) {
            const tier = allocator.alloc([]const u8, merged_trackers.items.len) catch {
                std.process.exit(1);
            };
            for (merged_trackers.items, 0..) |t, i| {
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

        std.Io.Dir.cwd().createDirPath(io, output_dir) catch {};
        var session = carl.session.Session.init(
            io,
            ctx,
            allocator,
            mi,
            output_dir,
            .download,
            port,
            proxy,
            .any,
            false,
            null,
            false,
        ) catch |err| {
            log.err("failed to initialize session: {}", .{err});
            std.process.exit(1);
        };
        defer session.deinit();
        session.info_hash = ml.info_hash; // Use magnet's hash, not SHA1("")
        session.metadata_download = carl.extension.MetadataDownload.init(allocator, ml.info_hash);
        session.metadata_only = true;
        session.seed_after_complete = want_seed;

        var discovery_ctx: CliPeerDiscoveryCtx = .{
            .session = &session,
            .nostr_ctx = ctx,
        };

        if (want_nostr) {
            session.setPeerDiscovery(
                &discovery_ctx,
                cliRediscoverPeersCb,
            );

            collectNostrPeers(
                ctx,
                allocator,
                ml.info_hash,
                &session,
            );
        }
        session.run() catch |err| {
            log.err("session failed: {}", .{err});
            std.process.exit(1);
        };
    } else if (std.mem.startsWith(u8, source, "http://") or std.mem.startsWith(u8, source, "https://")) {
        // HTTP URL
        log.info("downloading torrent from {s}...", .{source});
        const torrent_data = fetchUrl(io, allocator, source, proxy) catch |err| {
            log.err("failed to download torrent: {}", .{err});
            std.process.exit(1);
        };
        defer allocator.free(torrent_data);

        const mi = carl.metainfo.parse(allocator, torrent_data) catch |err| {
            log.err("invalid torrent file: {}", .{err});
            std.process.exit(1);
        };
        defer mi.deinit(allocator);
        startDownload(io, ctx, allocator, mi, output_dir, port, proxy, want_nostr, want_seed);
    } else {
        // File path
        const mi = readTorrent(io, allocator, source);
        defer mi.deinit(allocator);
        startDownload(io, ctx, allocator, mi, output_dir, port, proxy, want_nostr, want_seed);
    }
}

fn startDownload(
    io: std.Io,
    ctx: carl.nostr_config.Context,
    allocator: std.mem.Allocator,
    mi: carl.metainfo.Metainfo,
    output_dir: []const u8,
    port: u16,
    proxy: ?carl.proxy.Proxy,
    want_nostr: bool,
    want_seed: bool,
) void {
    std.Io.Dir.cwd().createDirPath(io, output_dir) catch {};
    var session = carl.session.Session.init(io, ctx, allocator, mi, output_dir, .download, port, proxy, .any, false, null, false) catch |err| {
        log.err("failed to initialize session: {}", .{err});
        std.process.exit(1);
    };
    session.seed_after_complete = want_seed;
    defer session.deinit();
    if (want_nostr) {
        const info_hash = carl.metainfo.infoHash(mi.raw_info);
        session.setPeerDiscovery(&session, cliRediscoverPeersCb);
        collectNostrPeers(ctx, allocator, info_hash, &session);
    }
    session.run() catch |err| {
        log.err("session failed: {}", .{err});
        std.process.exit(1);
    };
}

fn fetchUrl(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: []const u8,
    proxy: ?carl.proxy.Proxy,
) ![]u8 {
    // Route the initial .torrent fetch through the proxy too, so it doesn't
    // leak the real IP. HTTPS torrent URLs are not yet supported over a proxy.
    if (proxy) |px| {
        return carl.proxy.httpGet(io, allocator, px, url, null) catch |err| {
            log.err("HTTP fetch via proxy error: {}", .{err});
            return error.HttpFailed;
        };
    }

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &response_body.writer,
    }) catch |err| {
        log.err("HTTP fetch error: {}", .{err});
        return error.HttpFailed;
    };

    if (result.status != .ok) return error.HttpFailed;

    const data = response_body.written();
    if (data.len == 0) return error.HttpFailed;

    return allocator.dupe(u8, data) catch error.HttpFailed;
}

const TorSeedOptions = struct {
    control_addr: []const u8,
    cookie_path: ?[]const u8,
    onion_port: u16,
    socks_url: []const u8,
};

fn cmdSeed(
    ctx: carl.nostr_config.Context,
    io: std.Io,
    allocator: std.mem.Allocator,
    torrent_path: []const u8,
    data_dir: []const u8,
    port: u16,
    proxy: ?carl.proxy.Proxy,
    want_nostr: bool,
    tor_seed: bool,
    i2p_seed: bool,
    i2p_sam_addr: []const u8,
    external_ip: ?[]const u8,
    description: []const u8,
    tor_opts: TorSeedOptions,
) !void {
    if (tor_seed and i2p_seed) {
        log.err("--tor-seed and --i2p-seed are mutually exclusive", .{});
        std.process.exit(1);
    }
    const hidden_seed = tor_seed or i2p_seed; // an anonymity-network seed
    if (hidden_seed and proxy != null) {
        log.err("--tor-seed/--i2p-seed and --proxy are mutually exclusive on seed", .{});
        std.process.exit(1);
    }
    if (hidden_seed and !want_nostr) {
        log.err("--tor-seed/--i2p-seed requires --nostr (the address is published over Nostr)", .{});
        std.process.exit(1);
    }
    if (hidden_seed and external_ip != null) {
        log.err("--tor-seed/--i2p-seed advertise a hidden address; do not pass --external-ip", .{});
        std.process.exit(1);
    }
    if (want_nostr and !hidden_seed and external_ip == null) {
        log.err("--nostr requires --external-ip <ip>, --tor-seed, or --i2p-seed", .{});
        std.process.exit(1);
    }

    const mi = readTorrent(io, allocator, torrent_path);
    defer mi.deinit(allocator);

    var hidden: ?carl.tor_control.HiddenService = null;
    defer if (hidden) |*h| h.deinit();

    // I2P seed: open a SAM session with a stable (persisted) destination, derive
    // the `.b32.i2p`, publish it, and run the session as a loopback seed fed by
    // a SAM STREAM FORWARD — the I2P analog of the Tor hidden-service seed.
    var i2p_session: ?carl.i2p_sam.Session = null;
    defer if (i2p_session) |*s| s.deinit();
    var i2p_host_buf: [carl.i2p_sam.b32_host_len]u8 = undefined;
    if (i2p_seed) {
        const bridge = carl.i2p_sam.parseUrl(i2p_sam_addr) catch {
            log.err("invalid --i2p-sam '{s}'", .{i2p_sam_addr});
            std.process.exit(1);
        };
        var hex: [40]u8 = undefined;
        carl.secp.toHex(&carl.metainfo.infoHash(mi.raw_info), &hex);
        const persisted = carl.i2p_seed.load(ctx, allocator, &hex) catch null;
        defer if (persisted) |p| allocator.free(p);
        var used_persisted = persisted != null;
        const dest: carl.i2p_sam.Session.Dest = if (persisted) |p| .{ .priv = p } else .transient;
        i2p_session = carl.i2p_sam.Session.createWithDest(io, allocator, bridge, "carl-seed", dest) catch |err| blk: {
            // Fall back only on a protocol-level rejection (SAM answered
            // RESULT != OK for our key). Network failures (ConnectFailed,
            // HandshakeFailed) say nothing about the key — retrying transient
            // could succeed on router recovery and quarantine a good key.
            if (persisted == null or err != error.SessionFailed) {
                log.err("i2p SAM session setup failed: {} (is the router running with SAM?)", .{err});
                std.process.exit(1);
            }
            // SAM rejected the persisted key (corrupt-but-plausible blob —
            // length/base64 checks cannot prove a blob is untorn). Fall back
            // to a fresh destination instead of dying in a restart loop: a
            // new address beats no seed.
            log.warn("SAM rejected the persisted i2p destination ({}) — generating a fresh one", .{err});
            used_persisted = false;
            const fresh = carl.i2p_sam.Session.createWithDest(io, allocator, bridge, "carl-seed", .transient) catch |err2| {
                log.err("i2p SAM session setup failed: {} (is the router running with SAM?)", .{err2});
                std.process.exit(1);
            };
            // Only quarantine once the retry succeeded — the first failure
            // was the key, not SAM, so the persisted blob is proven bad.
            carl.i2p_seed.remove(ctx, allocator, &hex);
            break :blk fresh;
        };
        if (!used_persisted) carl.i2p_seed.save(ctx, allocator, &hex, i2p_session.?.destination);
        const host = carl.i2p_sam.b32Address(allocator, i2p_session.?.destination) catch {
            log.err("could not derive the .b32.i2p address", .{});
            std.process.exit(1);
        };
        defer allocator.free(host);
        @memcpy(&i2p_host_buf, host);
        log.info("i2p seed address: {s}", .{host});
    }

    const nostr_proxy: ?carl.proxy.Proxy = if (tor_seed)
        parseTorSocksProxy(tor_opts.socks_url)
    else
        null;

    if (want_nostr) {
        if (tor_seed) {
            hidden = carl.tor_control.addOnion(io, allocator, .{
                .home = ctx.home,
                .control_addr = tor_opts.control_addr,
                .cookie_path = tor_opts.cookie_path,
                .local_port = port,
                .onion_port = tor_opts.onion_port,
            }) catch |err| {
                log.err("tor hidden service setup failed: {}", .{err});
                std.process.exit(1);
            };
            carl.seeding.publish(ctx, allocator, mi, carl.metainfo.infoHash(mi.raw_info), .{
                .onion = .{ .host = hidden.?.onion_host, .port = hidden.?.onion_port },
            }, description, nostr_proxy) catch |err| {
                log.warn("nostr publish failed: {} (continuing seed)", .{err});
            };
        } else if (i2p_seed) {
            // Port 0 = the destination's default I2CP port; the STREAM FORWARD
            // delivers every inbound stream for the session regardless.
            carl.seeding.publish(ctx, allocator, mi, carl.metainfo.infoHash(mi.raw_info), .{
                .i2p = .{ .host = &i2p_host_buf, .port = 0 },
            }, description, null) catch |err| {
                log.warn("nostr publish failed: {} (continuing seed)", .{err});
            };
        } else {
            const ip = parseIpv4(external_ip.?) orelse {
                log.err("invalid --external-ip: {s}", .{external_ip.?});
                std.process.exit(1);
            };
            if (!carl.peer_announce.isRoutable(ip)) {
                log.err(
                    "--external-ip {d}.{d}.{d}.{d} is not routable; refusing to publish peer-announce",
                    .{ ip[0], ip[1], ip[2], ip[3] },
                );
                std.process.exit(1);
            }
            carl.seeding.publish(ctx, allocator, mi, carl.metainfo.infoHash(mi.raw_info), .{
                .ipv4 = .{ .ip = ip, .port = port },
            }, description, null) catch |err| {
                log.warn("nostr publish failed: {} (continuing seed)", .{err});
            };
        }
    }

    const listen_bind: carl.session.ListenBind = if (hidden_seed) .loopback else .any;
    const i2p_ptr: ?*carl.i2p_sam.Session = if (i2p_session) |*s| s else null;
    var session = carl.session.Session.init(
        ctx.io,
        ctx,
        allocator,
        mi,
        data_dir,
        .seed,
        port,
        null,
        listen_bind,
        tor_seed,
        i2p_ptr,
        i2p_seed,
    ) catch |err| {
        log.err("failed to initialize session: {}", .{err});
        std.process.exit(1);
    };
    defer session.deinit();

    // I2P seed: register inbound forwarding now that the loopback listener is up.
    if (i2p_seed) {
        if (session.listener == null) {
            log.err("i2p seed: loopback listener failed to bind on port {d}; the address would be unreachable", .{port});
            std.process.exit(1);
        }
        i2p_session.?.forward(port) catch |err| {
            log.err("i2p seed: STREAM FORWARD failed: {}; the .b32.i2p would be unreachable", .{err});
            std.process.exit(1);
        };
        log.info("i2p seed: forwarding {s} -> 127.0.0.1:{d}", .{ &i2p_host_buf, port });
    }

    session.run() catch |err| {
        log.err("session failed: {}", .{err});
        std.process.exit(1);
    };
}

fn parseTorSocksProxy(url: []const u8) carl.proxy.Proxy {
    return carl.proxy.parseUrl(url) catch |err| {
        log.err("invalid --tor-socks URL '{s}': {}", .{ url, err });
        std.process.exit(1);
    };
}

// -------------------------------------------------------------------------
// `carl create` — build a .torrent from a file or directory
// -------------------------------------------------------------------------

fn cmdCreate(
    io: std.Io,
    allocator: std.mem.Allocator,
    stdout: anytype,
    path: []const u8,
    extra: []const [:0]const u8,
) !void {
    // Collect repeated -t / --tracker flags (parseFlag only returns the first).
    var trackers: std.ArrayList([]const u8) = .empty;
    defer trackers.deinit(allocator);
    {
        var i: usize = 0;
        while (i + 1 < extra.len) : (i += 1) {
            if (std.mem.eql(u8, extra[i], "-t") or std.mem.eql(u8, extra[i], "--tracker")) {
                if (extra[i + 1].len > 0) try trackers.append(allocator, extra[i + 1]);
            }
        }
    }
    const comment = parseFlag(extra, "--comment");
    const piece_length: u32 = parseUnsignedFlag(extra, "--piece-length", carl.metainfo.default_piece_length);

    const res = carl.metainfo.buildTorrent(io, allocator, path, .{
        .piece_length = piece_length,
        .trackers = trackers.items,
        .comment = comment,
        .created_by = "carl",
        .creation_date = std.Io.Clock.real.now(io).toSeconds(),
    }) catch |err| {
        log.err("could not create torrent from '{s}': {}", .{ path, err });
        std.process.exit(1);
    };
    defer allocator.free(res.data);

    // Default output: <basename>.torrent in the current directory.
    const base = std.fs.path.basename(path);
    const default_out = try std.fmt.allocPrint(allocator, "{s}.torrent", .{base});
    defer allocator.free(default_out);
    const out_path = parseFlag(extra, "-o") orelse parseFlag(extra, "--output") orelse default_out;

    {
        const f = std.Io.Dir.cwd().createFile(
            io,
            out_path,
            .{ .truncate = true },
        ) catch |err| {
            log.err("could not write '{s}': {}", .{ out_path, err });
            std.process.exit(1);
        };

        defer f.close(io);

        f.writeStreamingAll(io, res.data) catch |err| {
            log.err("could not write '{s}': {}", .{ out_path, err });
            std.process.exit(1);
        };
    }

    try stdout.print("created:      {s}\n", .{out_path});
    try stdout.print("name:         {s}\n", .{base});
    try stdout.print("files:        {d}\n", .{res.file_count});
    try stdout.print("size:         {d} bytes\n", .{res.total_length});
    try stdout.print("piece length: {d}\n", .{piece_length});
    if (trackers.items.len > 0) {
        try stdout.print("trackers:     {d}\n", .{trackers.items.len});
    } else {
        try stdout.print("trackers:     none (Nostr/DHT discovery)\n", .{});
    }
    try stdout.print("info hash:    ", .{});
    for (res.info_hash) |byte| try stdout.print("{x:0>2}", .{byte});
    try stdout.print("\n", .{});
}

// -------------------------------------------------------------------------
// `carl search`
// -------------------------------------------------------------------------

fn cmdSearch(
    ctx: carl.nostr_config.Context,
    allocator: std.mem.Allocator,
    stdout: anytype,
    query: []const u8,
    limit: u32,
    single_relay: ?[]const u8,
    proxy: ?carl.proxy.Proxy,
) !void {
    var relay_urls: [][]const u8 = undefined;
    var relays_owned = false;
    if (single_relay) |r| {
        const arr = try allocator.alloc([]const u8, 1);
        arr[0] = r;
        relay_urls = arr;
    } else {
        relay_urls = carl.nostr_config.readRelays(ctx, allocator) catch |err| {
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

    // Many public relays (damus, nos.lol, …) reject NIP-50 `search` with
    // CLOSED rather than ignoring it. Subscribe to recent kind-2003 events
    // and match client-side instead.
    const filter: carl.nostr.Filter = .{
        .kinds = &[_]u32{carl.nip35.kind_torrent},
        .limit = @max(limit, 100),
    };

    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        seen.deinit();
    }

    // `--limit n` is the global cap on printed results across ALL relays, not
    // a per-relay multiplier. With 3 default relays this prevents `--limit 10`
    // from printing up to 30 unique results.
    var printed: u32 = 0;
    var found_any = false;
    // One-shot user search: honor the skip list unless it would silence every
    // relay (same gate as the daemon-side one-shots).
    const gate = carl.relay.oneShotGate(
        ctx.io,
        relay_urls,
        proxy,
    );
    relay_loop: for (relay_urls) |url| {
        if (printed >= limit) break;

        var r = carl.relay.dial(
            ctx.io,
            allocator,
            url,
            proxy,
            gate,
        ) catch |err| {
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

            if (!textMatches(entry.title, query) and !textMatches(entry.description, query)) continue;

            found_any = true;
            try printSearchResult(stdout, entry);
            printed += 1;
            if (printed >= limit) break :relay_loop;
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
// `carl follow` — mirror everything a Nostr pubkey publishes
// -------------------------------------------------------------------------

fn cmdFollow(
    ctx: carl.nostr_config.Context,
    allocator: std.mem.Allocator,
    pubkey_arg: []const u8,
    extra: []const [:0]const u8,
) !void {
    const pubkey = carl.follow.parsePubkeyArg(pubkey_arg) catch {
        log.err("invalid pubkey '{s}' (expected npub1... or 64-char hex)", .{pubkey_arg});
        std.process.exit(1);
    };

    const route_str = parseFlag(extra, "--route") orelse "direct";
    const route = carl.api.Route.parse(route_str) orelse {
        log.err("invalid --route '{s}' (expected direct|i2p)", .{route_str});
        std.process.exit(1);
    };
    if (route != .direct and route != .i2p) {
        log.err("carl follow supports --route direct|i2p (tor/proxy mirrors are a follow-up)", .{});
        std.process.exit(1);
    }

    var external_ip: ?[4]u8 = null;
    if (parseFlag(extra, "--external-ip")) |s| {
        external_ip = parseIpv4(s) orelse {
            log.err("invalid --external-ip: {s}", .{s});
            std.process.exit(1);
        };
        if (!carl.peer_announce.isRoutable(external_ip.?)) {
            log.err("--external-ip {s} is not routable; refusing to publish peer-announces", .{s});
            std.process.exit(1);
        }
    }

    // Default mirror dir: <workdir>/follow-<pubkey prefix>, so different
    // followed publishers never mix data and the workdir stays reseedable.
    var dir_owned: ?[]u8 = null;
    defer if (dir_owned) |d| allocator.free(d);
    const dir = parseFlag(extra, "--dir") orelse blk: {
        var pk_hex: [64]u8 = undefined;
        carl.secp.toHex(&pubkey, &pk_hex);
        const base = try carl.workdir.ensure(ctx, allocator, null);
        defer allocator.free(base);
        dir_owned = try std.fmt.allocPrint(allocator, "{s}/follow-{s}", .{ base, pk_hex[0..12] });
        break :blk @as([]const u8, dir_owned.?);
    };

    try carl.follow.run(ctx, allocator, .{
        .pubkey = pubkey,
        .route = route,
        .dir = dir,
        .i2p_sam = parseFlag(extra, "--i2p-sam") orelse "127.0.0.1:7656",
        .external_ip = external_ip,
        .poll_interval_s = parseUnsignedFlag(extra, "--interval", 60),
    });
}

// -------------------------------------------------------------------------
// `carl drive` — shared folders over Nostr (kind-30035 drive index)
// -------------------------------------------------------------------------

fn parseDriveRoute(extra: []const [:0]const u8) carl.api.Route {
    const route_str = parseFlag(extra, "--route") orelse "direct";
    const route = carl.api.Route.parse(route_str) orelse {
        log.err("invalid --route '{s}' (expected direct|i2p)", .{route_str});
        std.process.exit(1);
    };
    if (route != .direct and route != .i2p) {
        log.err("carl drive supports --route direct|i2p (tor/proxy drives are a follow-up)", .{});
        std.process.exit(1);
    }
    return route;
}

fn cmdDrive(
    ctx: carl.nostr_config.Context,
    allocator: std.mem.Allocator,
    rest: []const [:0]const u8,
) !void {
    if (rest.len < 1) {
        log.err("usage: carl drive <create|subscribe> ...", .{});
        std.process.exit(1);
    }
    const sub = rest[0];
    if (std.mem.eql(u8, sub, "create")) {
        if (rest.len < 2) {
            log.err("usage: carl drive create <dir> --name <drive> [--route direct|i2p] [--external-ip ip] [--interval secs]", .{});
            std.process.exit(1);
        }
        const dir = rest[1];
        const extra = rest[2..];
        const name = parseFlag(extra, "--name") orelse {
            log.err("carl drive create requires --name <drive>", .{});
            std.process.exit(1);
        };
        // Same plumbing as `carl follow`: a direct-route publisher needs a
        // routable IPv4 to publish dialable kind-30078 announces.
        var external_ip: ?[4]u8 = null;
        if (parseFlag(extra, "--external-ip")) |s| {
            external_ip = parseIpv4(s) orelse {
                log.err("invalid --external-ip: {s}", .{s});
                std.process.exit(1);
            };
            if (!carl.peer_announce.isRoutable(external_ip.?)) {
                log.err("--external-ip {s} is not routable; refusing to publish peer-announces", .{s});
                std.process.exit(1);
            }
        }
        // The publisher watches a real folder; a typo must fail loudly.
        var d = std.Io.Dir.cwd().openDir(
            ctx.io,
            dir,
            .{},
        ) catch {
            log.err("cannot open drive dir '{s}'", .{dir});
            std.process.exit(1);
        };
        d.close(ctx.io);
        carl.drive.run(ctx, allocator, .{
            .role = .publisher,
            .dir = dir,
            .drive = name,
            .route = parseDriveRoute(extra),
            .external_ip = external_ip,
            .poll_interval_s = parseUnsignedFlag(extra, "--interval", 5),
        }) catch |err| {
            log.err("drive failed: {}", .{err});
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, sub, "subscribe")) {
        if (rest.len < 3) {
            log.err("usage: carl drive subscribe <npub|pubkey-hex> <drive-name> [--also <npub>]... [--dir d] [--route direct|i2p] [--interval secs]", .{});
            std.process.exit(1);
        }
        const author = carl.follow.parsePubkeyArg(rest[1]) catch {
            log.err("invalid pubkey '{s}' (expected npub1... or 64-char hex)", .{rest[1]});
            std.process.exit(1);
        };
        const name = rest[2];
        const extra = rest[3..];

        // Collect repeated --also flags (parseFlag only returns the first).
        var also: std.ArrayList([32]u8) = .empty;
        defer also.deinit(allocator);
        {
            var i: usize = 0;
            while (i < extra.len) : (i += 1) {
                if (std.mem.eql(u8, extra[i], "--also")) {
                    if (i + 1 >= extra.len) {
                        log.err("--also requires a pubkey argument", .{});
                        std.process.exit(1);
                    }
                    const pk = carl.follow.parsePubkeyArg(extra[i + 1]) catch {
                        log.err("invalid --also pubkey '{s}'", .{extra[i + 1]});
                        std.process.exit(1);
                    };
                    try also.append(allocator, pk);
                    i += 1; // consume the value
                }
            }
        }

        // Default sync dir: <workdir>/drive-<pubkey prefix>-<name>, so
        // different drives never mix data and the workdir stays reseedable.
        var dir_owned: ?[]u8 = null;
        defer if (dir_owned) |dd| allocator.free(dd);
        const dir = parseFlag(extra, "--dir") orelse blk: {
            var pk_hex: [64]u8 = undefined;
            carl.secp.toHex(&author, &pk_hex);
            const base = try carl.workdir.ensure(ctx, allocator, null);
            defer allocator.free(base);
            dir_owned = try std.fmt.allocPrint(allocator, "{s}/drive-{s}-{s}", .{ base, pk_hex[0..12], name });
            break :blk @as([]const u8, dir_owned.?);
        };

        carl.drive.run(ctx, allocator, .{
            .role = .subscriber,
            .dir = dir,
            .drive = name,
            .author = author,
            .also = also.items,
            .route = parseDriveRoute(extra),
            .relay_interval_s = parseUnsignedFlag(extra, "--interval", 15),
        }) catch |err| {
            log.err("drive failed: {}", .{err});
            std.process.exit(1);
        };
    } else {
        log.err("unknown drive subcommand: {s} (expected create|subscribe)", .{sub});
        std.process.exit(1);
    }
}

// -------------------------------------------------------------------------
// `carl nostr-keygen`
// -------------------------------------------------------------------------

fn cmdNostrKeygen(
    ctx: carl.nostr_config.Context,
    allocator: std.mem.Allocator,
    stdout: anytype,
) !void {
    const sk = carl.secp.generateSecretKey() catch {
        log.err("failed to generate secret key", .{});
        std.process.exit(1);
    };
    const pk = carl.secp.publicKeyFromSecret(sk) catch {
        log.err("failed to derive public key", .{});
        std.process.exit(1);
    };

    const nsec = carl.nostr_config.writeSecretKey(ctx, allocator, sk) catch |err| {
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
// `carl whoami` — print the configured identity's npub
// -------------------------------------------------------------------------

fn cmdWhoami(
    ctx: carl.nostr_config.Context,
    allocator: std.mem.Allocator,
    stdout: anytype,
) !void {
    const sk = carl.nostr_config.readSecretKey(ctx, allocator) catch {
        log.err("no nostr identity configured; run `carl nostr-keygen` first", .{});
        std.process.exit(1);
    };
    const pk = carl.secp.publicKeyFromSecret(sk) catch {
        log.err("could not derive public key", .{});
        std.process.exit(1);
    };
    const npub = try carl.nip19.encode32(allocator, .npub, pk);
    defer allocator.free(npub);
    var pk_hex: [64]u8 = undefined;
    carl.secp.toHex(&pk, &pk_hex);
    try stdout.print("npub: {s}\nhex:  {s}\n", .{ npub, &pk_hex });
}

// -------------------------------------------------------------------------
// `carl daemon` — localhost HTTP+WebSocket API for the desktop GUI
// -------------------------------------------------------------------------

/// SIGINT handler for the daemon. Reuses the session shutdown flag so any
/// running transfer threads stop too; the blocking accept() returns EINTR and
/// the serve loop then exits.
fn daemonSigintHandler(
    _: @TypeOf(std.posix.SIG.INT),
) callconv(.c) void {
    carl.session.shutdown_requested.store(true, .release);
}

/// Watch the spawning parent (the desktop shell). If it dies — including a hard
/// SIGKILL/crash that bypasses the shell's own cleanup — request shutdown so we
/// never linger as an orphan holding the port. `kill(pid, 0)` probes existence:
/// ProcessNotFound means the parent is gone; PermissionDenied means it's alive.
fn parentWatchdog(
    io: std.Io,
    parent_pid: std.posix.pid_t,
) void {
    while (!carl.session.shutdown_requested.load(.acquire)) {
        io.sleep(.fromSeconds(1), .awake) catch return;
        std.posix.kill(
            parent_pid,
            @as(std.posix.SIG, @enumFromInt(0)),
        ) catch |err| switch (err) {
            error.ProcessNotFound => {
                carl.session.shutdown_requested.store(true, .release);
                return;
            },
            else => {}, // alive (e.g. PermissionDenied) — keep watching
        };
    }
}

/// Replay persisted transfers off the serve path so a slow anonymized re-add
/// (i2p SAM session / Tor hidden service) can't delay the daemon's HTTP bind.
fn restoreInBackground(mgr: *carl.manager.Manager) void {
    mgr.restoreTransfers();
}

fn cmdDaemon(
    io: std.Io,
    ctx: carl.nostr_config.Context,
    allocator: std.mem.Allocator,
    stdout: anytype,
    extra: []const [:0]const u8,
) !void {
    const port = parsePortFlag(extra, "--port", 8088);
    const bt_port = parsePortFlag(extra, "--bt-port", 6881);
    const route_flag = parseFlag(extra, "--route");
    const route_str = route_flag orelse "direct";
    const route = carl.api.Route.parse(route_str) orelse {
        log.err("invalid --route '{s}' (expected direct|proxy|tor|i2p)", .{route_str});
        std.process.exit(1);
    };
    const socks = parseFlag(extra, "--socks") orelse "";
    const i2p_sam = parseFlag(extra, "--i2p-sam") orelse "";
    // Default to the unified carl work dir (CARL_DIR > persisted Settings
    // value > ~/Downloads/carl) so the daemon/GUI and the CLI share one
    // download + seed directory. An explicit flag or $CARL_DIR outranks the
    // persisted setting, and `download_dir_pinned` tells the manager so its
    // restore() doesn't clobber the dir with the stale DB value.
    const download_dir_flag = parseFlag(extra, "--download-dir");
    var download_dir_pinned = download_dir_flag != null;
    var download_dir_owned: ?[]u8 = null;
    defer if (download_dir_owned) |d| allocator.free(d);
    const download_dir = download_dir_flag orelse blk: {
        if (try carl.workdir.envOverride(allocator, null)) |d| {
            download_dir_owned = d;
            download_dir_pinned = true;
            break :blk @as([]const u8, d);
        }
        download_dir_owned = try carl.workdir.resolve(
            ctx,
            allocator,
            null,
        );
        break :blk @as([]const u8, download_dir_owned.?);
    };
    // Tor ControlPort config for reachable `.tor` seeds (hidden services). The
    // empty defaults let Manager.init fall back to 127.0.0.1:9051 + the default
    // cookie path, matching the CLI `carl seed --tor-seed` defaults.
    const tor_control = parseFlag(extra, "--tor-control") orelse "";
    const tor_cookie = parseFlag(extra, "--tor-cookie") orelse "";
    const tor_onion_port: u16 = parsePortFlag(extra, "--tor-onion-port", 80);

    // Token: use --token if given, else generate a random 32-hex secret. The
    // Tauri sidecar reads it off stdout and presents it on every request.
    var token_buf: [32]u8 = undefined;
    const token: []const u8 = if (parseFlag(extra, "--token")) |t| t else blk: {
        var raw: [16]u8 = undefined;
        io.random(&raw);
        const hex = "0123456789abcdef";
        for (raw, 0..) |b, i| {
            token_buf[i * 2] = hex[b >> 4];
            token_buf[i * 2 + 1] = hex[b & 0x0f];
        }
        break :blk token_buf[0..];
    };

    var mgr = carl.manager.Manager.init(io, ctx, allocator, .{
        .route = route,
        .route_explicit = route_flag != null,
        .socks = socks,
        .i2p_sam = i2p_sam,
        .download_dir = download_dir,
        .download_dir_pinned = download_dir_pinned,
        .listen_port = bt_port,
        .tor_control = tor_control,
        .tor_cookie = tor_cookie,
        .tor_onion_port = tor_onion_port,
    }) catch |err| {
        log.err("failed to init manager: {}", .{err});
        std.process.exit(1);
    };
    defer mgr.deinit();

    var daemon = carl.daemon.Daemon{ .allocator = allocator, .manager = &mgr, .token = token };

    const act = std.posix.Sigaction{
        .handler = .{ .handler = daemonSigintHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);

    // Optional parent-death watchdog: the desktop shell passes --parent-pid so a
    // hard-killed app doesn't leave the daemon orphaned on the port.
    if (parseFlag(extra, "--parent-pid")) |pid_str| {
        if (std.fmt.parseInt(std.posix.pid_t, pid_str, 10)) |pid| {
            if (std.Thread.spawn(.{}, parentWatchdog, .{ io, pid })) |t| {
                t.detach();
            } else |e| log.warn("parent watchdog failed to start: {}", .{e});
        } else |_| log.warn("invalid --parent-pid '{s}', ignoring", .{pid_str});
    }

    // Restore persisted transfers/seeds + settings in the BACKGROUND so the
    // daemon binds and answers the GUI immediately. Re-adding an anonymized
    // transfer does a slow blocking setup (an i2p SAM SESSION CREATE, a Tor
    // hidden service) — doing that inline froze startup for minutes with the
    // HTTP port unbound, so the app looked empty/stateless on restart. Now the
    // transfers re-appear in the UI as they come back. restore() is mutex-safe
    // against the concurrently-serving handlers (it goes through the same
    // add/persist locks). settings (route/download dir) are applied up front by
    // restoreSettings so the very first snapshot already reflects them.
    mgr.restoreSettings();
    if (std.Thread.spawn(.{}, restoreInBackground, .{&mgr})) |t| {
        t.detach();
    } else |e| {
        log.warn("restore thread failed to start ({}); restoring inline", .{e});
        mgr.restore();
    }

    // The token line is machine-readable (the GUI parses it); keep the format
    // stable: "token: <hex>".
    try stdout.print("carl daemon\n", .{});
    try stdout.print("listen: http://127.0.0.1:{d}\n", .{port});
    try stdout.print("token: {s}\n", .{token});
    try stdout.print("route: {s}\n", .{route_str});
    // 0.16 stdout is buffered (4 KiB). The GUI sidecar parses `token:` and
    // gives up after 10s if it never arrives — flush before serve() blocks.
    try stdout.flush();

    // On a proxy/tor route, check the SOCKS proxy up front and say clearly why
    // it's unreachable (the daemon keeps running and the GUI shows live health).
    // The i2p route doesn't use SOCKS (SAM bridge) — probing it here would warn
    // about Tor on a route that doesn't need it.
    if (route.usesSocks()) {
        // Mask any user:pass@ credentials before logging the proxy URL. redactUrl
        // is credential-safe even if this buffer is too small (it then returns
        // the bare host:port), so a fixed buffer can't leak the password.
        var rbuf: [512]u8 = undefined;
        const safe_socks = carl.proxy.redactUrl(socks, &rbuf);
        if (carl.proxy.parseUrl(socks)) |px| {
            const probe = carl.proxy.classifySocks5(io, allocator, px, 5);
            switch (probe.state) {
                .ok => log.info("SOCKS proxy {s} reachable", .{safe_socks}),
                .not_running => log.warn("SOCKS proxy {s} unreachable (connection refused) -- is Tor/your proxy running?", .{safe_socks}),
                .timeout => log.warn("SOCKS proxy {s} timed out -- check the address/port and that the proxy is up", .{safe_socks}),
                .rejected => log.warn("SOCKS proxy {s} rejected the SOCKS5 handshake -- check it's a SOCKS5 proxy (auth may be required)", .{safe_socks}),
            }
        } else |_| {
            log.warn("invalid --socks URL '{s}' for the {s} route", .{ safe_socks, route_str });
        }
    }

    daemon.serve(port) catch |err| {
        log.err("daemon error: {}", .{err});
        std.process.exit(1);
    };

    // Connection/WebSocket threads and the relay prober are detached; give them
    // a brief window to observe the shutdown flag and finish touching the
    // allocator before `daemon.deinit()`, `mgr.deinit()`, and the GPA teardown
    // run. (A full join of background threads is a follow-up; see
    // docs/daemon-api.md.)
    io.sleep(.fromMilliseconds(400), .awake) catch {};
    daemon.deinit();
}

// -------------------------------------------------------------------------
// Nostr helpers for seed/download
// -------------------------------------------------------------------------

/// Fetch the most recent kind-2003 (NIP-35) torrent event for `info_hash`,
/// returning its parsed entry (title, trackers, files). Caller owns the result
/// and must `deinit` it. Returns null if no matching event is found.
fn fetchNip35Entry(
    ctx: carl.nostr_config.Context,
    allocator: std.mem.Allocator,
    info_hash: [20]u8,
    proxy: ?carl.proxy.Proxy,
) ?carl.nip35.TorrentEntry {
    var ih_hex: [40]u8 = undefined;
    carl.secp.toHex(&info_hash, &ih_hex);

    var values_arr = [_][]const u8{&ih_hex};
    var tag_filters = [_]carl.nostr.Filter.TagFilter{.{ .letter = 'x', .values = &values_arr }};
    const filter: carl.nostr.Filter = .{
        .kinds = &[_]u32{carl.nip35.kind_torrent},
        .tags = &tag_filters,
        .limit = 20,
    };

    const relay_urls = carl.nostr_config.readRelays(ctx, allocator) catch return null;
    defer carl.nostr_config.freeRelays(allocator, relay_urls);

    var best: ?carl.nip35.TorrentEntry = null;
    var best_created: i64 = std.math.minInt(i64);

    // One-shot metadata enrichment during a download: oneShotGate.
    const gate = carl.relay.oneShotGate(
        ctx.io,
        relay_urls,
        proxy,
    );
    for (relay_urls) |url| {
        var r = carl.relay.dial(
            ctx.io,
            allocator,
            url,
            proxy,
            gate,
        ) catch continue;
        defer r.deinit();
        const events = carl.relay.subscribeAndCollect(allocator, &r, filter, .{
            .timeout_ms = 10_000,
            .max_events = 20,
            .verify_signatures = true,
        }) catch continue;
        defer {
            for (events) |e| e.deinit(allocator);
            allocator.free(events);
        }
        for (events) |ev| {
            const entry = carl.nip35.parseEvent(allocator, ev) catch continue;
            if (!std.mem.eql(u8, &entry.info_hash, &info_hash)) {
                entry.deinit(allocator);
                continue;
            }
            if (entry.created_at > best_created) {
                if (best) |b| b.deinit(allocator);
                best_created = entry.created_at;
                best = entry;
            } else {
                entry.deinit(allocator);
            }
        }
    }
    return best;
}

/// `Session.PeerDiscovery` callback: re-run Nostr discovery when the download
/// has zero peers. The session carries everything we need (allocator +
/// info_hash), so the loop can keep retrying without extra state.
const CliPeerDiscoveryCtx = struct {
    session: *carl.session.Session,
    nostr_ctx: carl.nostr_config.Context,
};
fn cliRediscoverPeersCb(ctx: *anyopaque) void {
    const discovery_ctx: *CliPeerDiscoveryCtx =
        @ptrCast(@alignCast(ctx));

    collectNostrPeers(
        discovery_ctx.nostr_ctx,
        discovery_ctx.session.allocator,
        discovery_ctx.session.info_hash,
        discovery_ctx.session,
    );
}

fn collectNostrPeers(
    nostr_ctx: carl.nostr_config.Context,
    allocator: std.mem.Allocator,
    info_hash: [20]u8,
    session: *carl.session.Session,
) void {
    var ih_hex: [40]u8 = undefined;
    carl.secp.toHex(&info_hash, &ih_hex);

    const relay_urls = carl.nostr_config.readRelays(
        nostr_ctx,
        allocator,
    ) catch return;
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
        // Bail promptly on shutdown: this also runs as the periodic re-discovery
        // callback inside the session loop, so a Ctrl-C mid-query must be honored
        // without waiting out every relay's timeout.
        if (!session.running) return;
        // Periodic re-discovery: honor the health gate so a down or unusable
        // relay isn't re-dialed on every round.
        var r = carl.relay.dial(
            session.io,
            allocator,
            url,
            session.proxy,
            .honor,
        ) catch |err| {
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
            if (added >= 50) break;
            switch (ann.endpoint) {
                .ipv4 => |ep| {
                    const addr: std.Io.net.IpAddress = .{
                        .ip4 = .{
                            .bytes = ep.ip,
                            .port = ep.port,
                        },
                    };
                    session.connectDirectPeer(addr) catch continue;
                    added += 1;
                },
                .onion => |ep| {
                    if (session.proxy == null) {
                        log.warn(
                            "nostr peer {s}:{d} is a .onion host; use --proxy socks5h://127.0.0.1:9050 to connect",
                            .{ ep.host, ep.port },
                        );
                        continue;
                    }
                    session.connectOnionPeer(ep.host, ep.port) catch continue;
                    added += 1;
                },
                .i2p => |ep| {
                    // I2P peers need the daemon's `--route i2p` (a SAM session);
                    // the bare CLI download path has no I2P transport wired.
                    log.warn(
                        "nostr peer {s} is an I2P destination; run the daemon with --route i2p to connect",
                        .{ep.host},
                    );
                    continue;
                },
            }
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

fn parseFlag(extra_args: []const [:0]const u8, flag: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < extra_args.len) : (i += 1) {
        if (std.mem.eql(u8, extra_args[i], flag)) {
            return extra_args[i + 1];
        }
    }
    return null;
}

fn parsePort(extra_args: []const [:0]const u8) u16 {
    const port_str = parseFlag(extra_args, "--port") orelse return 6881;
    return std.fmt.parseUnsigned(u16, port_str, 10) catch 6881;
}

fn parsePortFlag(extra_args: []const [:0]const u8, flag: []const u8, default: u16) u16 {
    const port_str = parseFlag(extra_args, flag) orelse return default;
    return std.fmt.parseUnsigned(u16, port_str, 10) catch default;
}

/// Parse `--proxy <url>`. Exits with an error if the URL is malformed or the
/// flag is given without a value, so a typo never silently falls back to a
/// direct (de-anonymized) connection.
fn parseProxy(extra_args: []const [:0]const u8) ?carl.proxy.Proxy {
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

fn parseFlagPresent(extra_args: []const [:0]const u8, flag: []const u8) bool {
    for (extra_args) |a| if (std.mem.eql(u8, a, flag)) return true;
    return false;
}

fn parseUnsignedFlag(extra_args: []const [:0]const u8, flag: []const u8, default: u32) u32 {
    const s = parseFlag(extra_args, flag) orelse return default;
    return std.fmt.parseUnsigned(u32, s, 10) catch default;
}

test {
    _ = @import("carl");
}
