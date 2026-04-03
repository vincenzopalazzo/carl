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
        try cmdAnnounce(allocator, stdout, args[2]);
    } else if (std.mem.eql(u8, command, "download")) {
        if (args.len < 3) {
            log.err("usage: carl download <file.torrent> [--output-dir <dir>] [--port <port>]", .{});
            std.process.exit(1);
        }
        const output_dir = parseFlag(args[3..], "--output-dir") orelse ".";
        const port = parsePort(args[3..]);
        try cmdDownload(allocator, args[2], output_dir, port);
    } else if (std.mem.eql(u8, command, "seed")) {
        if (args.len < 4) {
            log.err("usage: carl seed <file.torrent> <data-dir> [--port <port>]", .{});
            std.process.exit(1);
        }
        const port = parsePort(args[4..]);
        try cmdSeed(allocator, args[2], args[3], port);
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
        \\  info <file.torrent>                      show torrent metadata
        \\  announce <file.torrent>                  query tracker for peers
        \\  download <file.torrent> [--output-dir d] [--port p] download torrent
        \\  seed <file.torrent> <data-dir> [--port p]          seed existing data
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

fn cmdAnnounce(allocator: std.mem.Allocator, stdout: anytype, path: []const u8) !void {
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
    }) catch |err| {
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

fn cmdDownload(allocator: std.mem.Allocator, torrent_path: []const u8, output_dir: []const u8, port: u16) !void {
    const mi = readTorrent(allocator, torrent_path);
    defer mi.deinit(allocator);

    std.fs.cwd().makePath(output_dir) catch {};

    var session = carl.session.Session.init(allocator, mi, output_dir, .download, port) catch |err| {
        log.err("failed to initialize session: {}", .{err});
        std.process.exit(1);
    };
    defer session.deinit();

    session.run() catch |err| {
        log.err("session failed: {}", .{err});
        std.process.exit(1);
    };
}

fn cmdSeed(allocator: std.mem.Allocator, torrent_path: []const u8, data_dir: []const u8, port: u16) !void {
    const mi = readTorrent(allocator, torrent_path);
    defer mi.deinit(allocator);

    var session = carl.session.Session.init(allocator, mi, data_dir, .seed, port) catch |err| {
        log.err("failed to initialize session: {}", .{err});
        std.process.exit(1);
    };
    defer session.deinit();

    session.run() catch |err| {
        log.err("session failed: {}", .{err});
        std.process.exit(1);
    };
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

test {
    _ = @import("carl");
}
