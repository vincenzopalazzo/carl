//! Native I2P transport via the SAM v3 bridge.
//!
//! I2P exposes a local "Simple Anonymous Messaging" (SAM) bridge — a TCP control
//! protocol (default 127.0.0.1:7656) — through which an application creates a
//! session (its own I2P destination) and opens streams to remote `.b32.i2p`
//! destinations. This is the I2P analog of carl's Tor path: instead of a SOCKS5h
//! proxy plus an onion hostname, we speak SAM v3 and dial destinations.
//!
//! SAM v3 model implemented here:
//!   1. A long-lived CONTROL connection: `HELLO` + `SESSION CREATE` keeps the
//!      I2P session (our destination) alive for as long as the socket is open.
//!   2. Per-stream connections: each outbound peer gets a FRESH socket that does
//!      `HELLO` + `STREAM CONNECT` (referencing the session id); on `RESULT=OK`
//!      the socket becomes a transparent bidirectional stream to the peer, ready
//!      for the BitTorrent handshake — the same "connected stream" contract as
//!      `proxy.zig`.
//!
//! This module covers session setup, outbound dial (`STREAM CONNECT`), inbound
//! seeding (`STREAM FORWARD`), bridge health probing, and `.b32.i2p` address
//! derivation. I2P trackers and the I2P DHT are follow-up phases.
//!
//! Requires a running I2P router (i2pd or Java I2P) with the SAM bridge enabled.
//! See docs/i2p.md. The handshake is synchronous and blocking (bounded by
//! SO_SNDTIMEO/SO_RCVTIMEO), matching proxy.zig.
const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;

const Net = std.Io.net;
const Stream = Net.Stream;
const HostName = Net.HostName;
const IpAddress = Net.IpAddress;

const log = std.log.scoped(.i2p);

pub const SamError = error{
    InvalidBridgeUrl,
    SocketFailed,
    ConnectFailed,
    HandshakeFailed,
    SessionFailed,
    StreamFailed,
    InvalidResponse,
    OutOfMemory,
};

pub const default_host = "127.0.0.1";
pub const default_port: u16 = 7656;

/// SAM bridge location. `host` borrows from the URL buffer passed to parseUrl.
pub const Bridge = struct {
    host: []const u8 = default_host,
    port: u16 = default_port,
};

/// SAM streams traverse multi-hop I2P tunnels; setup is slow, so give the
/// control + connect operations a generous timeout.
const timeout_secs: u32 = 60;

/// Parse a SAM bridge address: `sam://host:port`, `host:port`, or `host`
/// (defaulting the port). Borrows `host` from `url`.
pub fn parseUrl(url: []const u8) SamError!Bridge {
    var rest = url;
    if (std.mem.indexOf(u8, rest, "://")) |idx| {
        if (!std.mem.eql(u8, rest[0..idx], "sam")) return error.InvalidBridgeUrl;
        rest = rest[idx + 3 ..];
    }
    // Strip any trailing path.
    rest = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
    if (rest.len == 0) return error.InvalidBridgeUrl;
    if (std.mem.lastIndexOfScalar(u8, rest, ':')) |colon| {
        const host = rest[0..colon];
        if (host.len == 0) return error.InvalidBridgeUrl;
        const port = std.fmt.parseUnsigned(u16, rest[colon + 1 ..], 10) catch
            return error.InvalidBridgeUrl;
        return .{ .host = host, .port = port };
    }
    return .{ .host = rest, .port = default_port };
}

fn resolveIp4(
    io: std.Io,
    host: []const u8,
    port: u16,
) SamError!IpAddress {
    const host_name =
        HostName.init(host) catch return error.ConnectFailed;

    var canonical_name_buffer: [HostName.max_len]u8 = undefined;
    var lookup_buffer: [16]HostName.LookupResult = undefined;
    var lookup_queue: std.Io.Queue(HostName.LookupResult) =
        .init(&lookup_buffer);

    host_name.lookup(io, &lookup_queue, .{
        .port = port,
        .canonical_name_buffer = &canonical_name_buffer,
    }) catch return error.ConnectFailed;

    while (lookup_queue.getOneUncancelable(io)) |result| {
        switch (result) {
            .address => |address| switch (address) {
                .ip4 => return address,
                .ip6 => {},
            },
            .canonical_name => {},
        }
    } else |err| switch (err) {
        error.Closed => {},
    }

    return error.ConnectFailed;
}

fn connectIp4Bounded(
    addr: IpAddress,
    timeout_s: u32,
) SamError!Stream {
    const ip4 = switch (addr) {
        .ip4 => |a| a,
        .ip6 => return error.ConnectFailed,
    };

    const timeout_ms: i32 =
        if (timeout_s > 600)
            600_000
        else
            @intCast(timeout_s * 1000);

    const sock = std.c.socket(
        std.posix.AF.INET,
        std.posix.SOCK.STREAM,
        std.posix.IPPROTO.TCP,
    );

    if (sock < 0)
        return error.ConnectFailed;

    var socket_owned = true;
    defer {
        if (socket_owned) {
            _ = std.c.close(sock);
        }
    }

    _ = std.c.fcntl(
        sock,
        std.c.F.SETFD,
        @as(c_int, std.posix.FD_CLOEXEC),
    );

    const flags = std.c.fcntl(
        sock,
        std.c.F.GETFL,
        @as(c_int, 0),
    );

    if (flags < 0)
        return error.ConnectFailed;

    var o: std.c.O = @bitCast(@as(u32, @intCast(flags)));
    o.NONBLOCK = true;

    _ = std.c.fcntl(
        sock,
        std.c.F.SETFL,
        @as(c_int, @bitCast(o)),
    );

    const posix_addr: std.posix.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, ip4.port),
        .addr = @bitCast(ip4.bytes),
    };

    const rc = std.c.connect(
        sock,
        @ptrCast(&posix_addr),
        @sizeOf(std.posix.sockaddr.in),
    );

    if (rc != 0) switch (std.posix.errno(rc)) {
        .AGAIN, .INPROGRESS => {
            var pfd = [_]std.posix.pollfd{.{
                .fd = sock,
                .events = std.posix.POLL.OUT,
                .revents = 0,
            }};

            const ready = std.posix.poll(
                &pfd,
                timeout_ms,
            ) catch return error.ConnectFailed;

            if (ready == 0)
                return error.ConnectFailed;

            var socket_error: c_int = 0;
            var socket_error_len: std.c.socklen_t = @sizeOf(c_int);

            if (std.c.getsockopt(
                sock,
                std.c.SOL.SOCKET,
                std.c.SO.ERROR,
                &socket_error,
                &socket_error_len,
            ) != 0 or socket_error != 0) {
                return error.ConnectFailed;
            }
        },
        else => return error.ConnectFailed,
    };

    // Connected. Restore blocking mode.
    o.NONBLOCK = false;

    _ = std.c.fcntl(
        sock,
        std.c.F.SETFL,
        @as(c_int, @bitCast(o)),
    );

    socket_owned = false;

    return .{
        .socket = .{
            .handle = sock,
            .address = addr,
        },
    };
}

// --- low-level socket helpers (blocking, bounded; mirrors proxy.zig) ---

fn dial(io: std.Io, bridge: Bridge) SamError!Stream {
    const addr =
        resolveIp4(io, bridge.host, bridge.port) catch
            return error.ConnectFailed;

    const stream = connectIp4Bounded(
        addr,
        timeout_secs,
    ) catch return error.ConnectFailed;

    const tv = std.c.timeval{
        .sec = @intCast(timeout_secs),
        .usec = 0,
    };

    _ = std.c.setsockopt(
        stream.socket.handle,
        std.c.SOL.SOCKET,
        std.c.SO.SNDTIMEO,
        &tv,
        @intCast(@sizeOf(std.c.timeval)),
    );

    _ = std.c.setsockopt(
        stream.socket.handle,
        std.c.SOL.SOCKET,
        std.c.SO.RCVTIMEO,
        &tv,
        @intCast(@sizeOf(std.c.timeval)),
    );

    return stream;
}

fn writeAll(
    io: std.Io,
    stream: Stream,
    bytes: []const u8,
) SamError!void {
    var write_buffer: [0]u8 = .{};
    var writer = stream.writer(io, &write_buffer);

    var off: usize = 0;
    while (off < bytes.len) {
        const n = writer.interface.write(bytes[off..]) catch return error.HandshakeFailed;

        if (n == 0) return error.HandshakeFailed;
        off += n;
    }
}

/// Read a single newline-terminated SAM reply line into `buf` (without the
/// trailing CR/LF). Reads one byte at a time so we never consume past the line
/// into the subsequent data stream. Errors if the line exceeds `buf`.
fn readLine(
    io: std.Io,
    stream: Stream,
    buf: []u8,
) SamError![]u8 {
    var read_buffer: [0]u8 = .{};
    var reader = stream.reader(io, &read_buffer);

    var i: usize = 0;

    while (true) {
        if (i >= buf.len) return error.InvalidResponse;

        var b: [1]u8 = undefined;

        const n = reader.interface.readSliceShort(&b) catch
            return error.HandshakeFailed;

        if (n == 0)
            return error.HandshakeFailed;

        if (b[0] == '\n') break;

        buf[i] = b[0];
        i += 1;
    }

    if (i > 0 and buf[i - 1] == '\r') i -= 1;

    return buf[0..i];
}

// --- SAM reply parsing (pure; unit-tested) ---

/// Value of a `KEY=VALUE` token in a SAM line (everything after the first '=',
/// so base64 values with '=' padding survive). Null if the key isn't present.
pub fn samField(line: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    while (it.next()) |tok| {
        const eq = std.mem.indexOfScalar(u8, tok, '=') orelse continue;
        if (std.mem.eql(u8, tok[0..eq], key)) return tok[eq + 1 ..];
    }
    return null;
}

/// True if the line carries `RESULT=OK`.
pub fn samOk(line: []const u8) bool {
    const r = samField(line, "RESULT") orelse return false;
    return std.mem.eql(u8, r, "OK");
}

/// A negotiated SAM protocol version (`major.minor`). Used to gate features that
/// only exist in newer SAM revisions (e.g. `TO_PORT`, SAM 3.2+).
pub const Version = struct {
    major: u16,
    minor: u16,

    pub fn atLeast(self: Version, major: u16, minor: u16) bool {
        if (self.major != major) return self.major > major;
        return self.minor >= minor;
    }
};

/// Parse a SAM `VERSION` value like `3.2`. Anything malformed/missing parses as
/// `0.0`, which compares older than every real version (so version-gated
/// features stay disabled rather than being assumed available).
pub fn parseVersion(s: []const u8) Version {
    var it = std.mem.splitScalar(u8, s, '.');
    const major = std.fmt.parseUnsigned(u16, it.first(), 10) catch return .{ .major = 0, .minor = 0 };
    const minor = std.fmt.parseUnsigned(u16, it.next() orelse "0", 10) catch 0;
    return .{ .major = major, .minor = minor };
}

/// Perform the SAM `HELLO` version handshake and return the version the bridge
/// negotiated (the highest within our MIN..MAX it supports).
fn hello(io: std.Io, stream: Stream) SamError!Version {
    try writeAll(io, stream, "HELLO VERSION MIN=3.0 MAX=3.3\n");

    var buf: [256]u8 = undefined;
    const line = try readLine(io, stream, &buf);

    if (!std.mem.startsWith(u8, line, "HELLO REPLY") or !samOk(line))
        return error.HandshakeFailed;

    return parseVersion(samField(line, "VERSION") orelse "3.0");
}

// --- bridge health probe -----------------------------------------------------

/// Health of the SAM bridge, the I2P analog of `proxy.ProxyState`. Lets the
/// daemon/GUI say *why* the i2p route isn't working, the same way the Tor route
/// reports SOCKS health, instead of failing silently.
pub const Health = enum {
    /// Reachable and speaks SAM v3 (`HELLO REPLY RESULT=OK`).
    ok,
    /// Nothing is listening on the SAM port (connection refused) — the I2P
    /// router isn't running, or the SAM bridge is disabled.
    not_running,
    /// The connect or the `HELLO` handshake timed out.
    timeout,
    /// Reachable but did not speak SAM (no `HELLO REPLY RESULT=OK`) — e.g. the
    /// port points at something that isn't a SAM bridge.
    handshake_failed,

    pub fn jsonName(self: Health) []const u8 {
        return @tagName(self);
    }
};

/// Probe the SAM bridge once: non-blocking connect (so a filtered/dead host
/// yields a real timeout and a refused port is distinguished from a timeout —
/// `SO_SNDTIMEO` does not bound `connect()` on macOS), then a `HELLO VERSION`
/// handshake. Never creates a session or leaks; greeting only. Mirrors
/// `proxy.classifySocks5`.
pub fn classifyBridge(
    io: std.Io,
    bridge: Bridge,
    timeout_s: u32,
) Health {
    const addr =
        resolveIp4(io, bridge.host, bridge.port) catch
            return .not_running;

    const timeout_ms: i32 =
        if (timeout_s > 600) 600_000 else @intCast(timeout_s * 1000);

    const sock = std.c.socket(
        std.posix.AF.INET,
        std.posix.SOCK.STREAM,
        std.posix.IPPROTO.TCP,
    );

    if (sock < 0)
        return .timeout;

    defer _ = std.c.close(sock);

    _ = std.c.fcntl(
        sock,
        std.c.F.SETFD,
        @as(c_int, std.posix.FD_CLOEXEC),
    );

    const flags = std.c.fcntl(
        sock,
        std.c.F.GETFL,
        @as(c_int, 0),
    );

    if (flags < 0)
        return .timeout;

    var o: std.c.O = @bitCast(@as(u32, @intCast(flags)));
    o.NONBLOCK = true;

    _ = std.c.fcntl(
        sock,
        std.c.F.SETFL,
        @as(c_int, @bitCast(o)),
    );

    const ip4 = switch (addr) {
        .ip4 => |a| a,
        .ip6 => return .not_running,
    };

    const posix_addr: std.posix.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, ip4.port),
        .addr = @bitCast(ip4.bytes),
    };

    const rc = std.c.connect(
        sock,
        @ptrCast(&posix_addr),
        @sizeOf(std.posix.sockaddr.in),
    );

    if (rc != 0) switch (std.posix.errno(rc)) {
        .AGAIN, .INPROGRESS => {
            var pfd = [_]std.posix.pollfd{.{
                .fd = sock,
                .events = std.posix.POLL.OUT,
                .revents = 0,
            }};

            const ready = std.posix.poll(
                &pfd,
                timeout_ms,
            ) catch return .timeout;

            if (ready == 0)
                return .timeout;

            var socket_error: c_int = 0;
            var socket_error_len: std.c.socklen_t = @sizeOf(c_int);

            if (std.c.getsockopt(
                sock,
                std.c.SOL.SOCKET,
                std.c.SO.ERROR,
                &socket_error,
                &socket_error_len,
            ) != 0) {
                return .timeout;
            }

            if (socket_error != 0) {
                if (socket_error == @intFromEnum(std.c.E.CONNREFUSED))
                    return .not_running;

                return .timeout;
            }
        },
        .CONNREFUSED => return .not_running,
        else => return .timeout,
    };

    // Connected. Restore blocking mode for the SAM greeting.
    o.NONBLOCK = false;

    _ = std.c.fcntl(
        sock,
        std.c.F.SETFL,
        @as(c_int, @bitCast(o)),
    );

    const tv = std.c.timeval{
        .sec = @intCast(timeout_s),
        .usec = 0,
    };

    _ = std.c.setsockopt(
        sock,
        std.c.SOL.SOCKET,
        std.c.SO.SNDTIMEO,
        &tv,
        @intCast(@sizeOf(std.c.timeval)),
    );

    _ = std.c.setsockopt(
        sock,
        std.c.SOL.SOCKET,
        std.c.SO.RCVTIMEO,
        &tv,
        @intCast(@sizeOf(std.c.timeval)),
    );

    const stream: Stream = .{
        .socket = .{
            .handle = sock,
            .address = addr,
        },
    };

    _ = hello(io, stream) catch
        return .handshake_failed;

    return .ok;
}

// --- destination address derivation -----------------------------------------

/// I2P's base64 alphabet: standard base64 with `-` and `~` replacing `+`/`/`.
const i2p_b64 = std.base64.Base64Decoder.init(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-~".*,
    '=',
);

/// RFC 4648 base32 alphabet, lowercase — the form used in `.b32.i2p` hostnames.
const b32_alphabet = "abcdefghijklmnopqrstuvwxyz234567";

/// Encode `in` as unpadded lowercase base32 into `out`. Returns the slice
/// written. `out` must hold ceil(in.len * 8 / 5) bytes (52 for a SHA-256).
fn base32Encode(out: []u8, in: []const u8) []const u8 {
    var acc: u32 = 0;
    var bits: u5 = 0;
    var n: usize = 0;
    for (in) |b| {
        acc = (acc << 8) | b;
        bits += 8;
        while (bits >= 5) {
            bits -= 5;
            out[n] = b32_alphabet[@as(u5, @truncate(acc >> bits))];
            n += 1;
        }
    }
    if (bits > 0) {
        out[n] = b32_alphabet[@as(u5, @truncate(acc << (5 - bits)))];
        n += 1;
    }
    return out[0..n];
}

/// Length of a `.b32.i2p` hostname: 52 base32 chars + the suffix.
pub const b32_host_len: usize = 52 + ".b32.i2p".len;

/// Derive the public `.b32.i2p` hostname from a destination in I2P base64 —
/// either the full private key a SESSION CREATE returns (the public
/// destination is its prefix) or a bare public destination. The address is
/// `base32(SHA-256(destination bytes))`; the destination length is
/// 387 + cert-length (384 key bytes, then a 3-byte certificate header whose
/// last two bytes are the big-endian payload length).
pub fn b32Address(allocator: Allocator, dest_b64: []const u8) SamError![]u8 {
    const max = i2p_b64.calcSizeUpperBound(dest_b64.len) catch return error.InvalidResponse;
    const blob = allocator.alloc(u8, max) catch return error.OutOfMemory;
    defer allocator.free(blob);
    const n = blk: {
        i2p_b64.decode(blob, dest_b64) catch return error.InvalidResponse;
        break :blk i2p_b64.calcSizeForSlice(dest_b64) catch return error.InvalidResponse;
    };
    if (n < 387) return error.InvalidResponse;
    const cert_len = std.mem.readInt(u16, blob[385..387], .big);
    const dest_len = 387 + @as(usize, cert_len);
    if (n < dest_len) return error.InvalidResponse;

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(blob[0..dest_len], &digest, .{});

    const host = allocator.alloc(u8, b32_host_len) catch return error.OutOfMemory;
    errdefer allocator.free(host);
    var b32buf: [52]u8 = undefined;
    const enc = base32Encode(&b32buf, &digest);
    @memcpy(host[0..enc.len], enc);
    @memcpy(host[enc.len..], ".b32.i2p");
    return host;
}

// --- public API ---

/// A live SAM STREAM session. Owns the control connection that keeps the I2P
/// session (and our destination) alive — closing it tears the session down.
pub const Session = struct {
    io: std.Io,
    allocator: Allocator,
    bridge: Bridge,
    id: []u8,
    /// Our private destination (base64). The SESSION CREATE reply always echoes
    /// the full private key, so persisting this value and passing it back as
    /// `.{ .priv = ... }` recreates the same destination (stable `.b32.i2p`).
    destination: []u8,
    control: Stream,
    /// Open `STREAM FORWARD` registration (inbound). The bridge cancels the
    /// forward when this socket closes, so it lives as long as the session.
    forward_conn: ?Stream = null,

    /// Which destination keys back the session: a fresh transient one (the
    /// bridge generates Ed25519 keys and returns the private key), or a
    /// previously-persisted private key, giving a stable `.b32.i2p` address.
    pub const Dest = union(enum) {
        transient,
        priv: []const u8,
    };

    /// Create a SAM STREAM session with a transient destination. `id_prefix` is
    /// a human label; a random suffix makes the SAM session id unique.
    pub fn create(
        io: std.Io,
        allocator: Allocator,
        bridge: Bridge,
        id_prefix: []const u8,
    ) SamError!Session {
        return createWithDest(
            io,
            allocator,
            bridge,
            id_prefix,
            .transient,
        );
    }

    /// Create a SAM STREAM session backed by `dest`. With `.transient` the
    /// bridge generates new Ed25519 keys (`SIGNATURE_TYPE=7` — the SAM default
    /// for transient destinations is the legacy DSA-SHA1 on some routers);
    /// with `.priv` the session reuses persisted keys and is reachable at the
    /// same `.b32.i2p` address across restarts.
    pub fn createWithDest(
        io: std.Io,
        allocator: Allocator,
        bridge: Bridge,
        id_prefix: []const u8,
        dest: Dest,
    ) SamError!Session {
        var control = try dial(io, bridge);
        errdefer control.close(io);
        _ = try hello(io, control); // control connection sends no version-gated commands

        var rnd: [4]u8 = undefined;
        io.random(&rnd);
        const suffix = std.mem.readInt(u32, &rnd, .little);
        const id = std.fmt.allocPrint(allocator, "{s}-{x:0>8}", .{ id_prefix, suffix }) catch
            return error.OutOfMemory;
        errdefer allocator.free(id);

        const cmd = switch (dest) {
            .transient => std.fmt.allocPrint(
                allocator,
                "SESSION CREATE STYLE=STREAM ID={s} DESTINATION=TRANSIENT SIGNATURE_TYPE=7\n",
                .{id},
            ),
            .priv => |p| std.fmt.allocPrint(
                allocator,
                "SESSION CREATE STYLE=STREAM ID={s} DESTINATION={s}\n",
                .{ id, p },
            ),
        };
        const cmd_buf = cmd catch return error.OutOfMemory;
        defer allocator.free(cmd_buf);
        try writeAll(io, control, cmd_buf);

        var buf: [4096]u8 = undefined; // destination keys are long
        const line = try readLine(io, control, &buf);
        if (!std.mem.startsWith(u8, line, "SESSION STATUS") or !samOk(line))
            return error.SessionFailed;
        const dest_b64 = samField(line, "DESTINATION") orelse return error.SessionFailed;
        const destination = allocator.dupe(u8, dest_b64) catch return error.OutOfMemory;

        return .{
            .io = io,
            .allocator = allocator,
            .bridge = bridge,
            .id = id,
            .destination = destination,
            .control = control,
        };
    }

    pub fn deinit(self: *Session) void {
        if (self.forward_conn) |f| f.close(self.io);
        self.control.close(self.io);
        self.allocator.free(self.id);
        self.allocator.free(self.destination);
    }

    /// Register inbound forwarding: every stream a remote peer opens to our
    /// destination is delivered by the bridge as a fresh TCP connection to
    /// `127.0.0.1:port` (`SILENT=true` → no SAM header line, the socket starts
    /// directly with peer data — so a plain loopback listener, like the Tor
    /// hidden-service seed's, can accept BitTorrent handshakes unmodified).
    /// The registration socket is owned by the session and held open until
    /// `deinit`; closing it cancels the forward. One forward per session.
    pub fn forward(self: *Session, port: u16) SamError!void {
        if (self.forward_conn != null) return error.StreamFailed; // already armed
        var stream = try dial(self.io, self.bridge);
        errdefer stream.close(self.io);
        _ = try hello(self.io, stream);

        const cmd = std.fmt.allocPrint(
            self.allocator,
            "STREAM FORWARD ID={s} PORT={d} HOST=127.0.0.1 SILENT=true\n",
            .{ self.id, port },
        ) catch return error.OutOfMemory;
        defer self.allocator.free(cmd);
        try writeAll(self.io, stream, cmd);

        var buf: [512]u8 = undefined;
        const line = try readLine(self.io, stream, &buf);
        if (!std.mem.startsWith(u8, line, "STREAM STATUS") or !samOk(line))
            return error.StreamFailed;
        self.forward_conn = stream;
    }

    /// Open a stream to a remote destination (`*.b32.i2p` or a full base64
    /// destination). Returns a connected stream ready for the BitTorrent
    /// handshake. A fresh socket per stream (SAM v3), referencing this session.
    ///
    /// `port` is the I2CP destination port the peer advertised (BitTorrent peer
    /// announces carry one). A destination can multiplex services by port, so a
    /// non-zero port is passed through as `TO_PORT` — but only when the bridge
    /// negotiated **SAM 3.2+**, which introduced `TO_PORT`. Sending it to a
    /// 3.0/3.1 bridge can have the CONNECT rejected, so on older bridges we omit
    /// it and dial the destination's default port (best effort). `port == 0`
    /// always omits it.
    pub fn connect(
        self: *Session,
        dest: []const u8,
        port: u16,
    ) SamError!Stream {
        var stream = try dial(self.io, self.bridge);
        errdefer stream.close(self.io);
        const ver = try hello(self.io, stream);

        const cmd = if (port != 0 and ver.atLeast(3, 2))
            std.fmt.allocPrint(
                self.allocator,
                "STREAM CONNECT ID={s} DESTINATION={s} TO_PORT={d} SILENT=false\n",
                .{ self.id, dest, port },
            )
        else
            std.fmt.allocPrint(
                self.allocator,
                "STREAM CONNECT ID={s} DESTINATION={s} SILENT=false\n",
                .{ self.id, dest },
            );
        const cmd_buf = cmd catch return error.OutOfMemory;
        defer self.allocator.free(cmd_buf);
        try writeAll(self.io, stream, cmd_buf);

        var buf: [512]u8 = undefined;
        const line = try readLine(self.io, stream, &buf);
        if (!std.mem.startsWith(u8, line, "STREAM STATUS") or !samOk(line))
            return error.StreamFailed;
        // On RESULT=OK the rest of the socket is the bidirectional peer stream.
        return stream;
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "i2p_sam: samField extracts values incl. base64 padding" {
    try testing.expectEqualStrings("OK", samField("STREAM STATUS RESULT=OK", "RESULT").?);
    try testing.expectEqualStrings(
        "3.1",
        samField("HELLO REPLY RESULT=OK VERSION=3.1", "VERSION").?,
    );
    // base64 value with '=' padding must survive (split on first '=' only).
    try testing.expectEqualStrings(
        "ZmFrZQ==",
        samField("SESSION STATUS RESULT=OK DESTINATION=ZmFrZQ==", "DESTINATION").?,
    );
    try testing.expect(samField("HELLO REPLY RESULT=OK", "MISSING") == null);
}

test "i2p_sam: samOk" {
    try testing.expect(samOk("HELLO REPLY RESULT=OK VERSION=3.1"));
    try testing.expect(!samOk("STREAM STATUS RESULT=CANT_REACH_PEER"));
    try testing.expect(!samOk("STREAM STATUS")); // no RESULT
}

test "i2p_sam: parseUrl forms" {
    const a = try parseUrl("sam://127.0.0.1:7656");
    try testing.expectEqualStrings("127.0.0.1", a.host);
    try testing.expectEqual(@as(u16, 7656), a.port);

    const b = try parseUrl("10.0.0.5:2600");
    try testing.expectEqualStrings("10.0.0.5", b.host);
    try testing.expectEqual(@as(u16, 2600), b.port);

    const c = try parseUrl("127.0.0.1"); // bare host → default port
    try testing.expectEqual(default_port, c.port);

    try testing.expectError(error.InvalidBridgeUrl, parseUrl("socks5://x:1"));
    try testing.expectError(error.InvalidBridgeUrl, parseUrl("sam://:7656"));
    try testing.expectError(error.InvalidBridgeUrl, parseUrl(""));
}

// --- mock SAM bridge: exercises the real wire format end-to-end ---

fn mockHandleConn(stream: std.Io.net.Stream, version: []const u8) void {
    defer stream.close(std.testing.io);
    var buf: [4096]u8 = undefined;
    _ = readLine(std.testing.io, stream, &buf) catch return;

    var hbuf: [64]u8 = undefined;
    const hello_reply = std.fmt.bufPrint(
        &hbuf,
        "HELLO REPLY RESULT=OK VERSION={s}\n",
        .{version},
    ) catch return;

    writeAll(std.testing.io, stream, hello_reply) catch return;

    const cmd = readLine(std.testing.io, stream, &buf) catch return;
    if (std.mem.startsWith(u8, cmd, "SESSION CREATE")) {
        // Echo a persisted private key back verbatim so the stable-destination
        // round-trip is exercised; otherwise hand out a canned transient dest.
        if (samField(cmd, "DESTINATION")) |d| {
            if (!std.mem.eql(u8, d, "TRANSIENT")) {
                var rbuf: [256]u8 = undefined;
                const reply = std.fmt.bufPrint(&rbuf, "SESSION STATUS RESULT=OK DESTINATION={s}\n", .{d}) catch return;
                writeAll(std.testing.io, stream, reply) catch return;
                return;
            }
        }
        writeAll(std.testing.io, stream, "SESSION STATUS RESULT=OK DESTINATION=ZmFrZWRlc3Q=\n") catch return;
    } else if (std.mem.startsWith(u8, cmd, "STREAM FORWARD")) {
        // A real bridge requires ID + PORT; assert both are present.
        const ok = std.mem.indexOf(u8, cmd, "ID=") != null and
            std.mem.indexOf(u8, cmd, "PORT=") != null;
        writeAll(std.testing.io, stream, if (ok) "STREAM STATUS RESULT=OK\n" else "STREAM STATUS RESULT=I2P_ERROR\n") catch return;
    } else if (std.mem.startsWith(u8, cmd, "STREAM CONNECT")) {
        // Reject any destination containing "bad" to exercise the error path.
        if (std.mem.indexOf(u8, cmd, "bad") != null) {
            writeAll(std.testing.io, stream, "STREAM STATUS RESULT=CANT_REACH_PEER\n") catch return;
        } else {
            // The success-path tests dial with a non-zero port. TO_PORT is SAM
            // 3.2+, so it must appear on the wire iff the negotiated version is
            // >= 3.2. Assert both directions by failing closed on a mismatch.
            const has_to_port = std.mem.indexOf(u8, cmd, "TO_PORT=6881") != null;
            const want_to_port = parseVersion(version).atLeast(3, 2);
            if (has_to_port != want_to_port) {
                writeAll(std.testing.io, stream, "STREAM STATUS RESULT=I2P_ERROR\n") catch return;
                return;
            }
            writeAll(std.testing.io, stream, "STREAM STATUS RESULT=OK\n") catch return;
            writeAll(std.testing.io, stream, "BTpayload") catch return; // simulated peer data
        }
    }
}

const MockCtx = struct {
    server: *std.Io.net.Server,
    stop: std.atomic.Value(bool),
    /// SAM version the mock bridge advertises in its HELLO REPLY.
    version: []const u8 = "3.3",
};

fn mockRun(ctx: *MockCtx) void {
    // poll() the listen socket with a timeout so we only accept() when a
    // connection is ready, and otherwise loop to observe `stop`. This is the
    // portable way to make the thread exit (neither closing the listener nor
    // SO_RCVTIMEO reliably unblocks a parked accept() across Linux + macOS) and
    // mirrors the daemon's own serve loop.
    var pfd = [_]std.posix.pollfd{.{ .fd = ctx.server.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    while (!ctx.stop.load(.acquire)) {
        const ready = std.posix.poll(&pfd, 200) catch 0;
        if (ready == 0) continue; // timeout → re-check stop
        const conn = ctx.server.accept(std.testing.io) catch continue;
        mockHandleConn(conn, ctx.version);
    }
}

test "i2p_sam: session create + stream connect against a mock SAM bridge" {
    const allocator = testing.allocator;
    const addr: std.Io.net.IpAddress = .{
        .ip4 = .loopback(0),
    };

    var server = try addr.listen(
        std.testing.io,
        .{ .reuse_address = true },
    );

    const port = server.socket.address.getPort();
    var ctx = MockCtx{ .server = &server, .stop = std.atomic.Value(bool).init(false) };
    const t = try std.Thread.spawn(.{}, mockRun, .{&ctx});
    // Stop the thread (it polls `stop` between accept timeouts), join, then close
    // — runs on both success and assertion-failure paths, so the test never hangs.
    defer {
        ctx.stop.store(true, .release);
        t.join();
        server.deinit(std.testing.io);
    }

    const bridge = Bridge{ .host = "127.0.0.1", .port = port };

    var sess = try Session.create(std.testing.io, allocator, bridge, "carltest");
    defer sess.deinit();
    try testing.expectEqualStrings("ZmFrZWRlc3Q=", sess.destination);
    try testing.expect(std.mem.startsWith(u8, sess.id, "carltest-"));

    // Successful CONNECT: the advertised port is threaded as TO_PORT (the mock
    // rejects the connect if it's missing), and the returned stream carries the
    // simulated peer bytes.
    var peer = try sess.connect("examplepeer.b32.i2p", 6881);
    var rbuf: [32]u8 = undefined;
    var read_buffer: [0]u8 = .{};
    var reader = peer.reader(std.testing.io, &read_buffer);

    var got: usize = 0;
    while (got < "BTpayload".len) {
        const n = reader.interface.readSliceShort(rbuf[got..]) catch break;
        if (n == 0) break;
        got += n;
    }
    peer.close(std.testing.io);
    try testing.expectEqualStrings("BTpayload", rbuf[0..got]);

    // Failed CONNECT surfaces as StreamFailed (port 0 → no TO_PORT on the wire).
    try testing.expectError(error.StreamFailed, sess.connect("bad.b32.i2p", 0));
}

test "i2p_sam: base32Encode matches a known vector" {
    // base32(SHA-256("")) — RFC 4648 lowercase, unpadded.
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("", &digest, .{});
    var buf: [52]u8 = undefined;
    const enc = base32Encode(&buf, &digest);
    try testing.expectEqual(@as(usize, 52), enc.len);
    try testing.expectEqualStrings("4oymiquy7qobjgx36tejs35zeqt24qpemsnzgtfeswmrw6csxbkq", enc);
}

test "i2p_sam: b32Address derives base32(sha256(dest)) over the full dest" {
    const allocator = testing.allocator;
    // 387 zero bytes (384-byte key block + 3-byte null certificate, cert_len=0)
    // encoded in I2P base64. SHA-256 of those 387 zeros base32s to this host.
    var dest_bytes: [387]u8 = .{0} ** 387;
    var b64buf: [516]u8 = undefined;
    const enc = std.base64.Base64Encoder.init(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-~".*,
        '=',
    );
    const dest_b64 = enc.encode(&b64buf, &dest_bytes);

    const host = try b32Address(allocator, dest_b64);
    defer allocator.free(host);
    try testing.expectEqual(b32_host_len, host.len);
    try testing.expect(std.mem.endsWith(u8, host, ".b32.i2p"));
    try testing.expectEqualStrings("gem7z2yovuoqqbg3sd5qzb5dhaiit6osezfdo3cbuonanzjsuzaq.b32.i2p", host);
    // A derived host must be a valid `.b32.i2p` per peer_announce's validator.
    const pa = @import("peer_announce.zig");
    try testing.expect(pa.isValidI2pB32Host(host));
}

test "i2p_sam: b32Address honors a non-zero certificate length" {
    const allocator = testing.allocator;
    // 387 base bytes but cert_len=5 -> the real destination is 392 bytes, so
    // five extra payload bytes must be hashed too. A truncated read (387) would
    // produce a different address; assert the longer one is used.
    var dest_bytes: [392]u8 = .{0} ** 392;
    std.mem.writeInt(u16, dest_bytes[385..387], 5, .big);
    dest_bytes[387] = 0xAB; // cert payload (arbitrary, just must be hashed)
    var full_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&dest_bytes, &full_digest, .{});
    var want: [52]u8 = undefined;
    const want_label = base32Encode(&want, &full_digest);

    var b64buf: [536]u8 = undefined;
    const benc = std.base64.Base64Encoder.init(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-~".*,
        '=',
    );
    const dest_b64 = benc.encode(&b64buf, &dest_bytes);
    const host = try b32Address(allocator, dest_b64);
    defer allocator.free(host);
    try testing.expectEqualStrings(want_label, host[0..52]);
}

test "i2p_sam: parseVersion + atLeast" {
    try testing.expectEqual(@as(u16, 3), parseVersion("3.2").major);
    try testing.expectEqual(@as(u16, 2), parseVersion("3.2").minor);
    try testing.expect(parseVersion("3.2").atLeast(3, 2));
    try testing.expect(parseVersion("3.3").atLeast(3, 2));
    try testing.expect(parseVersion("4.0").atLeast(3, 2));
    try testing.expect(!parseVersion("3.1").atLeast(3, 2));
    try testing.expect(!parseVersion("3.0").atLeast(3, 2));
    try testing.expect(!parseVersion("2.9").atLeast(3, 2));
    // Malformed/missing minor parse as 0 → older than any version-gated feature.
    try testing.expect(!parseVersion("garbage").atLeast(3, 2));
    try testing.expect(parseVersion("3").atLeast(3, 0));
}

test "i2p_sam: TO_PORT omitted on a pre-3.2 bridge (best-effort default port)" {
    const allocator = testing.allocator;
    const addr: std.Io.net.IpAddress = .{
        .ip4 = .loopback(0),
    };

    var server = try addr.listen(
        std.testing.io,
        .{ .reuse_address = true },
    );

    const port = server.socket.address.getPort();
    // 3.1 bridge: the mock fails the CONNECT if TO_PORT appears, so a passing
    // test proves we omit TO_PORT (rather than send an unsupported parameter).
    var ctx = MockCtx{ .server = &server, .stop = std.atomic.Value(bool).init(false), .version = "3.1" };
    const t = try std.Thread.spawn(.{}, mockRun, .{&ctx});
    defer {
        ctx.stop.store(true, .release);
        t.join();
        server.deinit(std.testing.io);
    }

    const bridge = Bridge{ .host = "127.0.0.1", .port = port };
    var sess = try Session.create(std.testing.io, allocator, bridge, "carltest");
    defer sess.deinit();

    // Dials with a non-zero port; on a 3.1 bridge it must still succeed with
    // TO_PORT omitted.
    var peer = try sess.connect("examplepeer.b32.i2p", 6881);
    peer.close(std.testing.io);
}

test "i2p_sam: classifyBridge reports ok against a SAM bridge, not_running on a dead port" {
    const addr: std.Io.net.IpAddress = .{
        .ip4 = .loopback(0),
    };

    var server = try addr.listen(
        std.testing.io,
        .{ .reuse_address = true },
    );

    const port = server.socket.address.getPort();
    var ctx = MockCtx{ .server = &server, .stop = std.atomic.Value(bool).init(false) };
    const t = try std.Thread.spawn(.{}, mockRun, .{&ctx});
    defer {
        ctx.stop.store(true, .release);
        t.join();
        server.deinit(std.testing.io);
    }

    // Live mock bridge → ok (it answers HELLO with RESULT=OK).
    try testing.expectEqual(Health.ok, classifyBridge(std.testing.io, .{ .host = "127.0.0.1", .port = port }, 3));

    // A port with nothing listening → not_running (connection refused). Bind and
    // immediately release a port to get one that's almost certainly free.
    const probe_port = blk: {
        var s = try addr.listen(
            std.testing.io,
            .{ .reuse_address = true },
        );
        const p = s.socket.address.getPort();
        s.deinit(std.testing.io);
        break :blk p;
    };
    try testing.expectEqual(Health.not_running, classifyBridge(std.testing.io, .{ .host = "127.0.0.1", .port = probe_port }, 2));
}

test "i2p_sam: STREAM FORWARD arms inbound and is idempotent-guarded" {
    const allocator = testing.allocator;
    const addr: std.Io.net.IpAddress = .{
        .ip4 = .loopback(0),
    };

    var server = try addr.listen(
        std.testing.io,
        .{ .reuse_address = true },
    );

    const port = server.socket.address.getPort();
    var ctx = MockCtx{ .server = &server, .stop = std.atomic.Value(bool).init(false) };
    const t = try std.Thread.spawn(.{}, mockRun, .{&ctx});
    defer {
        ctx.stop.store(true, .release);
        t.join();
        server.deinit(std.testing.io);
    }

    const bridge = Bridge{ .host = "127.0.0.1", .port = port };
    var sess = try Session.create(std.testing.io, allocator, bridge, "carlseed");
    defer sess.deinit();

    // First FORWARD succeeds and the registration socket is retained.
    try sess.forward(6881);
    try testing.expect(sess.forward_conn != null);
    // A second FORWARD is rejected (one forward per session) without clobbering
    // the live registration.
    try testing.expectError(error.StreamFailed, sess.forward(6882));
    try testing.expect(sess.forward_conn != null);
}

test "i2p_sam: createWithDest reuses a persisted private key (stable address)" {
    const allocator = testing.allocator;
    const addr: std.Io.net.IpAddress = .{
        .ip4 = .loopback(0),
    };

    var server = try addr.listen(
        std.testing.io,
        .{ .reuse_address = true },
    );

    const port = server.socket.address.getPort();
    var ctx = MockCtx{ .server = &server, .stop = std.atomic.Value(bool).init(false) };
    const t = try std.Thread.spawn(.{}, mockRun, .{&ctx});
    defer {
        ctx.stop.store(true, .release);
        t.join();
        server.deinit(std.testing.io);
    }

    const bridge = Bridge{ .host = "127.0.0.1", .port = port };
    // The mock echoes a persisted DESTINATION back verbatim, so the session's
    // stored destination must equal what we passed in (proving the key is
    // threaded into SESSION CREATE rather than ignored).
    var sess = try Session.createWithDest(
        std.testing.io,
        allocator,
        bridge,
        "carlseed",
        .{ .priv = "cGVyc2lzdGVk" },
    );
    defer sess.deinit();
    try testing.expectEqualStrings("cGVyc2lzdGVk", sess.destination);
}
