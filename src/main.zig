const std = @import("std");
const carl = @import("carl");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    if (args.len < 2) {
        try stderr.print("usage: carl <command> [args]\n\ncommands:\n  info <file.torrent>    show torrent metadata\n", .{});
        std.process.exit(1);
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "info")) {
        if (args.len < 3) {
            try stderr.print("usage: carl info <file.torrent>\n", .{});
            std.process.exit(1);
        }
        try cmdInfo(allocator, stdout, args[2]);
    } else {
        try stderr.print("unknown command: {s}\n", .{command});
        std.process.exit(1);
    }
}

fn cmdInfo(allocator: std.mem.Allocator, stdout: anytype, path: []const u8) !void {
    const stderr = std.fs.File.stderr().deprecatedWriter();

    const data = std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch |err| {
        try stderr.print("error: cannot read '{s}': {}\n", .{ path, err });
        std.process.exit(1);
    };
    defer allocator.free(data);

    const mi = carl.metainfo.parse(allocator, data) catch |err| {
        try stderr.print("error: invalid torrent file: {}\n", .{err});
        std.process.exit(1);
    };
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

test {
    _ = @import("carl");
}
