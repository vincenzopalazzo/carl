/// Magnet link parser.
///
/// Parses magnet:?xt=urn:btih:<40-char-hex>&dn=<name>&tr=<tracker>
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const MagnetLink = struct {
    info_hash: [20]u8,
    name: ?[]const u8,
    trackers: []const []const u8,

    pub fn deinit(self: MagnetLink, allocator: Allocator) void {
        if (self.name) |n| allocator.free(n);
        for (self.trackers) |t| allocator.free(t);
        allocator.free(self.trackers);
    }
};

pub const ParseError = error{
    InvalidMagnet,
    InvalidInfoHash,
    OutOfMemory,
};

/// Parse a magnet URI. Caller owns the returned MagnetLink.
pub fn parse(allocator: Allocator, uri: []const u8) ParseError!MagnetLink {
    const prefix = "magnet:?";
    if (!std.mem.startsWith(u8, uri, prefix)) return error.InvalidMagnet;

    var info_hash: ?[20]u8 = null;
    var name: ?[]const u8 = null;
    errdefer if (name) |n| allocator.free(n);

    var trackers: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (trackers.items) |t| allocator.free(t);
        trackers.deinit(allocator);
    }

    var params = std.mem.splitScalar(u8, uri[prefix.len..], '&');
    while (params.next()) |param| {
        if (std.mem.startsWith(u8, param, "xt=urn:btih:")) {
            const hex = param["xt=urn:btih:".len..];
            if (hex.len != 40) return error.InvalidInfoHash;
            info_hash = parseHex(hex) orelse return error.InvalidInfoHash;
        } else if (std.mem.startsWith(u8, param, "dn=")) {
            const raw = param["dn=".len..];
            name = percentDecode(allocator, raw) catch return error.OutOfMemory;
        } else if (std.mem.startsWith(u8, param, "tr=")) {
            const raw = param["tr=".len..];
            const decoded = percentDecode(allocator, raw) catch return error.OutOfMemory;
            trackers.append(allocator, decoded) catch {
                allocator.free(decoded);
                return error.OutOfMemory;
            };
        }
    }

    if (info_hash == null) return error.InvalidMagnet;

    return .{
        .info_hash = info_hash.?,
        .name = name,
        .trackers = trackers.toOwnedSlice(allocator) catch return error.OutOfMemory,
    };
}

fn parseHex(hex: []const u8) ?[20]u8 {
    if (hex.len != 40) return null;
    var result: [20]u8 = undefined;
    for (0..20) |i| {
        const hi = hexVal(hex[i * 2]) orelse return null;
        const lo = hexVal(hex[i * 2 + 1]) orelse return null;
        result[i] = (hi << 4) | lo;
    }
    return result;
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn percentDecode(allocator: Allocator, input: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = hexVal(input[i + 1]) orelse {
                try buf.append(allocator, input[i]);
                i += 1;
                continue;
            };
            const lo = hexVal(input[i + 2]) orelse {
                try buf.append(allocator, input[i]);
                i += 1;
                continue;
            };
            try buf.append(allocator, (hi << 4) | lo);
            i += 3;
        } else if (input[i] == '+') {
            try buf.append(allocator, ' ');
            i += 1;
        } else {
            try buf.append(allocator, input[i]);
            i += 1;
        }
    }

    return buf.toOwnedSlice(allocator);
}

// --- Tests ---

test "parse magnet link" {
    const allocator = std.testing.allocator;

    const ml = try parse(allocator, "magnet:?xt=urn:btih:157e0a57e1af0e1cfd46258ba6c62938c21b6ee8&dn=archlinux-2026.04.01-x86_64.iso&tr=https%3A%2F%2Ftracker.example.com%2Fannounce");
    defer ml.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0x15), ml.info_hash[0]);
    try std.testing.expectEqual(@as(u8, 0x7e), ml.info_hash[1]);
    try std.testing.expectEqual(@as(u8, 0xe8), ml.info_hash[19]);
    try std.testing.expectEqualStrings("archlinux-2026.04.01-x86_64.iso", ml.name.?);
    try std.testing.expectEqual(@as(usize, 1), ml.trackers.len);
    try std.testing.expectEqualStrings("https://tracker.example.com/announce", ml.trackers[0]);
}

test "parse magnet link without name or tracker" {
    const allocator = std.testing.allocator;

    const ml = try parse(allocator, "magnet:?xt=urn:btih:0000000000000000000000000000000000000000");
    defer ml.deinit(allocator);

    try std.testing.expect(ml.name == null);
    try std.testing.expectEqual(@as(usize, 0), ml.trackers.len);
}

test "parse magnet link with multiple trackers" {
    const allocator = std.testing.allocator;

    const ml = try parse(allocator, "magnet:?xt=urn:btih:0000000000000000000000000000000000000000&tr=udp%3A%2F%2Fone.example.com%3A6969&tr=http%3A%2F%2Ftwo.example.com%2Fannounce");
    defer ml.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), ml.trackers.len);
    try std.testing.expectEqualStrings("udp://one.example.com:6969", ml.trackers[0]);
    try std.testing.expectEqualStrings("http://two.example.com/announce", ml.trackers[1]);
}

test "reject invalid magnet" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.InvalidMagnet, parse(allocator, "http://example.com"));
    try std.testing.expectError(error.InvalidMagnet, parse(allocator, "magnet:?foo=bar"));
    try std.testing.expectError(error.InvalidInfoHash, parse(allocator, "magnet:?xt=urn:btih:tooshort"));
}
