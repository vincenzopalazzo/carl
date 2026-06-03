//! Minimal Tor ControlPort client for creating ephemeral v3 hidden services.
//!
//! Carl uses `ADD_ONION NEW:ED25519-V3` to obtain a `.onion` hostname and
//! tears it down with `DEL_ONION` on shutdown. Authentication uses the
//! cookie file from a local `tor` instance.

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;

const log = std.log.scoped(.tor);

pub const Error = error{
    ConnectFailed,
    AuthFailed,
    CommandFailed,
    InvalidResponse,
    BadOnionHost,
    OutOfMemory,
};

pub const HiddenService = struct {
    allocator: Allocator,
    stream: std.net.Stream,
    service_id: []const u8,
    onion_host: []const u8,
    onion_port: u16,

    pub fn deinit(self: *HiddenService) void {
        self.delOnion() catch |err| {
            log.warn("DEL_ONION failed: {}", .{err});
        };
        self.allocator.free(self.service_id);
        self.allocator.free(self.onion_host);
        self.stream.close();
    }

    fn delOnion(self: *HiddenService) !void {
        var cmd_buf: [128]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "DEL_ONION {s}\r\n", .{self.service_id}) catch return;
        sendCommand(self.stream, cmd) catch return;
        _ = readReply(self.stream) catch return;
    }
};

pub const Options = struct {
    /// `host:port` for the ControlPort (default `127.0.0.1:9051`).
    control_addr: []const u8 = "127.0.0.1:9051",
    /// Path to the control cookie file (default `~/.tor/control_auth_cookie`).
    cookie_path: ?[]const u8 = null,
    /// Local BitTorrent listen port (HiddenServicePort target).
    local_port: u16,
    /// Virtual port exposed on the onion (default 80).
    onion_port: u16 = 80,
};

/// Create a v3 hidden service forwarding `onion_port` → `127.0.0.1:local_port`.
pub fn addOnion(allocator: Allocator, opts: Options) Error!HiddenService {
    const stream = connectControl(allocator, opts.control_addr) catch return error.ConnectFailed;
    errdefer stream.close();

    const cookie_path = opts.cookie_path orelse defaultCookiePath(allocator) catch return error.AuthFailed;
    defer if (opts.cookie_path == null) allocator.free(cookie_path);

    authenticate(allocator, stream, cookie_path) catch return error.AuthFailed;

    var cmd_buf: [256]u8 = undefined;
    const cmd = std.fmt.bufPrint(
        &cmd_buf,
        "ADD_ONION NEW:ED25519-V3 Port={d},127.0.0.1:{d}\r\n",
        .{ opts.onion_port, opts.local_port },
    ) catch return error.CommandFailed;
    sendCommand(stream, cmd) catch return error.CommandFailed;

    const reply = readReplyAlloc(allocator, stream) catch return error.InvalidResponse;
    defer allocator.free(reply);

    const service_id = parseServiceId(allocator, reply) catch return error.InvalidResponse;
    errdefer allocator.free(service_id);

    const onion_host = std.fmt.allocPrint(allocator, "{s}.onion", .{service_id}) catch return error.OutOfMemory;
    errdefer allocator.free(onion_host);

    if (!isValidV3OnionHost(onion_host)) {
        allocator.free(service_id);
        allocator.free(onion_host);
        return error.BadOnionHost;
    }

    log.info("tor hidden service {s}:{d} -> 127.0.0.1:{d}", .{
        onion_host, opts.onion_port, opts.local_port,
    });

    return .{
        .allocator = allocator,
        .stream = stream,
        .service_id = service_id,
        .onion_host = onion_host,
        .onion_port = opts.onion_port,
    };
}

fn defaultCookiePath(allocator: Allocator) ![]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return error.OutOfMemory;
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.tor/control_auth_cookie", .{home});
}

fn connectControl(allocator: Allocator, addr_str: []const u8) !std.net.Stream {
    const colon = std.mem.lastIndexOfScalar(u8, addr_str, ':') orelse return error.ConnectFailed;
    const host = addr_str[0..colon];
    const port = std.fmt.parseUnsigned(u16, addr_str[colon + 1 ..], 10) catch return error.ConnectFailed;

    const list = std.net.getAddressList(allocator, host, port) catch return error.ConnectFailed;
    defer list.deinit();

    for (list.addrs) |a| {
        if (std.net.tcpConnectToAddress(a)) |s| return s else |_| {}
    }
    return error.ConnectFailed;
}

fn authenticate(allocator: Allocator, stream: std.net.Stream, cookie_path: []const u8) !void {
    const cookie = std.fs.cwd().readFileAlloc(allocator, cookie_path, 256) catch return error.AuthFailed;
    defer allocator.free(cookie);
    if (cookie.len == 0) return error.AuthFailed;

    var hex_buf: std.ArrayList(u8) = .empty;
    defer hex_buf.deinit(allocator);
    for (cookie) |b| {
        hex_buf.writer(allocator).print("{x:0>2}", .{b}) catch return error.AuthFailed;
    }

    var cmd_buf: [512]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "AUTHENTICATE {s}\r\n", .{hex_buf.items}) catch return error.AuthFailed;
    sendCommand(stream, cmd) catch return error.AuthFailed;
    const reply = readReply(stream) catch return error.AuthFailed;
    if (!std.mem.startsWith(u8, reply, "250")) return error.AuthFailed;
}

fn sendCommand(stream: std.net.Stream, cmd: []const u8) !void {
    try stream.writeAll(cmd);
}

fn readReplyAlloc(allocator: Allocator, stream: std.net.Stream) ![]u8 {
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = stream.read(buf[len..]) catch return error.InvalidResponse;
        if (n == 0) break;
        len += n;
        if (std.mem.endsWith(u8, buf[0..len], "\r\n250 OK\r\n") or
            std.mem.endsWith(u8, buf[0..len], "250 OK\r\n"))
        {
            break;
        }
    }
    if (len == 0) return error.InvalidResponse;
    return try allocator.dupe(u8, buf[0..len]);
}

fn readReply(stream: std.net.Stream) ![]const u8 {
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = stream.read(buf[len..]) catch return error.InvalidResponse;
        if (n == 0) break;
        len += n;
        if (std.mem.endsWith(u8, buf[0..len], "\r\n250 OK\r\n") or
            std.mem.endsWith(u8, buf[0..len], "250 OK\r\n"))
        {
            break;
        }
    }
    if (len == 0) return error.InvalidResponse;
    return buf[0..len];
}

/// Extract ServiceID from a multi-line `ADD_ONION` reply.
pub fn parseServiceId(allocator: Allocator, reply: []const u8) Error![]u8 {
    var lines = std.mem.tokenizeAny(u8, reply, "\r\n");
    while (lines.next()) |line| {
        const prefix = "250-ServiceID=";
        if (std.mem.startsWith(u8, line, prefix)) {
            const id = line[prefix.len..];
            if (id.len == 0) return error.InvalidResponse;
            return try allocator.dupe(u8, id);
        }
    }
    return error.InvalidResponse;
}

fn isValidV3OnionHost(host: []const u8) bool {
    return @import("peer_announce.zig").isValidV3OnionHost(host);
}

test "parseServiceId" {
    const allocator = std.testing.allocator;
    var label: [56]u8 = undefined;
    @memset(&label, 'a');
    var reply_buf: [128]u8 = undefined;
    const reply = try std.fmt.bufPrint(&reply_buf, "250-ServiceID={s}\r\n250 OK\r\n", .{&label});
    const id = try parseServiceId(allocator, reply);
    defer allocator.free(id);
    try std.testing.expectEqual(@as(usize, 56), id.len);
    try std.testing.expectEqualStrings(&label, id);
}
