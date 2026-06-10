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
//! Inbound (`STREAM ACCEPT`/`FORWARD` for seeding), I2P trackers, and I2P DHT
//! are follow-up phases; this module covers session setup + outbound dial.
//!
//! Requires a running I2P router (i2pd or Java I2P) with the SAM bridge enabled.
//! See docs/i2p.md. The handshake is synchronous and blocking (bounded by
//! SO_SNDTIMEO/SO_RCVTIMEO), matching proxy.zig.
const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;

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

// --- low-level socket helpers (blocking, bounded; mirrors proxy.zig) ---

fn dial(allocator: Allocator, bridge: Bridge) SamError!std.net.Stream {
    const list = std.net.getAddressList(allocator, bridge.host, bridge.port) catch
        return error.ConnectFailed;
    defer list.deinit();
    var target: ?std.net.Address = null;
    for (list.addrs) |a| {
        if (a.any.family == posix.AF.INET) {
            target = a;
            break;
        }
    }
    const addr = target orelse return error.ConnectFailed;

    const sock = posix.socket(
        posix.AF.INET,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
        posix.IPPROTO.TCP,
    ) catch return error.SocketFailed;
    errdefer posix.close(sock);

    const tv = posix.timeval{ .sec = @intCast(timeout_secs), .usec = 0 };
    posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};
    posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    posix.connect(sock, &addr.any, addr.getOsSockLen()) catch return error.ConnectFailed;
    return std.net.Stream{ .handle = sock };
}

fn writeAll(stream: std.net.Stream, bytes: []const u8) SamError!void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = stream.write(bytes[off..]) catch return error.HandshakeFailed;
        if (n == 0) return error.HandshakeFailed;
        off += n;
    }
}

/// Read a single newline-terminated SAM reply line into `buf` (without the
/// trailing CR/LF). Reads one byte at a time so we never consume past the line
/// into the subsequent data stream. Errors if the line exceeds `buf`.
fn readLine(stream: std.net.Stream, buf: []u8) SamError![]u8 {
    var i: usize = 0;
    while (true) {
        if (i >= buf.len) return error.InvalidResponse;
        var b: [1]u8 = undefined;
        const n = stream.read(&b) catch return error.HandshakeFailed;
        if (n == 0) return error.HandshakeFailed; // EOF before newline
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
fn hello(stream: std.net.Stream) SamError!Version {
    try writeAll(stream, "HELLO VERSION MIN=3.0 MAX=3.3\n");
    var buf: [256]u8 = undefined;
    const line = try readLine(stream, &buf);
    if (!std.mem.startsWith(u8, line, "HELLO REPLY") or !samOk(line))
        return error.HandshakeFailed;
    // A 3.x bridge always echoes VERSION; default to 3.0 if it somehow doesn't.
    return parseVersion(samField(line, "VERSION") orelse "3.0");
}

// --- public API ---

/// A live SAM STREAM session. Owns the control connection that keeps the I2P
/// session (and our destination) alive — closing it tears the session down.
pub const Session = struct {
    allocator: Allocator,
    bridge: Bridge,
    id: []u8,
    /// Our private destination (base64). Kept for P2 (seeding/announce); the
    /// public `.b32.i2p` address is derived from it in a later phase.
    destination: []u8,
    control: std.net.Stream,

    /// Create a SAM STREAM session with a transient destination. `id_prefix` is
    /// a human label; a random suffix makes the SAM session id unique.
    pub fn create(allocator: Allocator, bridge: Bridge, id_prefix: []const u8) SamError!Session {
        var control = try dial(allocator, bridge);
        errdefer control.close();
        _ = try hello(control); // control connection sends no version-gated commands

        var rnd: [4]u8 = undefined;
        std.crypto.random.bytes(&rnd);
        const suffix = std.mem.readInt(u32, &rnd, .little);
        const id = std.fmt.allocPrint(allocator, "{s}-{x:0>8}", .{ id_prefix, suffix }) catch
            return error.OutOfMemory;
        errdefer allocator.free(id);

        const cmd = std.fmt.allocPrint(
            allocator,
            "SESSION CREATE STYLE=STREAM ID={s} DESTINATION=TRANSIENT\n",
            .{id},
        ) catch return error.OutOfMemory;
        defer allocator.free(cmd);
        try writeAll(control, cmd);

        var buf: [4096]u8 = undefined; // destination keys are long
        const line = try readLine(control, &buf);
        if (!std.mem.startsWith(u8, line, "SESSION STATUS") or !samOk(line))
            return error.SessionFailed;
        const dest_b64 = samField(line, "DESTINATION") orelse return error.SessionFailed;
        const destination = allocator.dupe(u8, dest_b64) catch return error.OutOfMemory;

        return .{
            .allocator = allocator,
            .bridge = bridge,
            .id = id,
            .destination = destination,
            .control = control,
        };
    }

    pub fn deinit(self: *Session) void {
        self.control.close();
        self.allocator.free(self.id);
        self.allocator.free(self.destination);
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
    pub fn connect(self: *Session, dest: []const u8, port: u16) SamError!std.net.Stream {
        var stream = try dial(self.allocator, self.bridge);
        errdefer stream.close();
        const ver = try hello(stream);

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
        try writeAll(stream, cmd_buf);

        var buf: [512]u8 = undefined;
        const line = try readLine(stream, &buf);
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

fn mockHandleConn(stream: std.net.Stream, version: []const u8) void {
    defer stream.close();
    var buf: [4096]u8 = undefined;
    _ = readLine(stream, &buf) catch return; // HELLO VERSION
    var hbuf: [64]u8 = undefined;
    const hello_reply = std.fmt.bufPrint(&hbuf, "HELLO REPLY RESULT=OK VERSION={s}\n", .{version}) catch return;
    writeAll(stream, hello_reply) catch return;
    const cmd = readLine(stream, &buf) catch return;
    if (std.mem.startsWith(u8, cmd, "SESSION CREATE")) {
        writeAll(stream, "SESSION STATUS RESULT=OK DESTINATION=ZmFrZWRlc3Q=\n") catch return;
    } else if (std.mem.startsWith(u8, cmd, "STREAM CONNECT")) {
        // Reject any destination containing "bad" to exercise the error path.
        if (std.mem.indexOf(u8, cmd, "bad") != null) {
            writeAll(stream, "STREAM STATUS RESULT=CANT_REACH_PEER\n") catch return;
        } else {
            // The success-path tests dial with a non-zero port. TO_PORT is SAM
            // 3.2+, so it must appear on the wire iff the negotiated version is
            // >= 3.2. Assert both directions by failing closed on a mismatch.
            const has_to_port = std.mem.indexOf(u8, cmd, "TO_PORT=6881") != null;
            const want_to_port = parseVersion(version).atLeast(3, 2);
            if (has_to_port != want_to_port) {
                writeAll(stream, "STREAM STATUS RESULT=I2P_ERROR\n") catch return;
                return;
            }
            writeAll(stream, "STREAM STATUS RESULT=OK\n") catch return;
            writeAll(stream, "BTpayload") catch return; // simulated peer data
        }
    }
}

const MockCtx = struct {
    server: *std.net.Server,
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
    var pfd = [_]std.posix.pollfd{.{ .fd = ctx.server.stream.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    while (!ctx.stop.load(.acquire)) {
        const ready = std.posix.poll(&pfd, 200) catch 0;
        if (ready == 0) continue; // timeout → re-check stop
        const conn = ctx.server.accept() catch continue;
        mockHandleConn(conn.stream, ctx.version);
    }
}

test "i2p_sam: session create + stream connect against a mock SAM bridge" {
    const allocator = testing.allocator;
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    var server = try addr.listen(.{ .reuse_address = true });
    const port = server.listen_address.getPort();
    var ctx = MockCtx{ .server = &server, .stop = std.atomic.Value(bool).init(false) };
    const t = try std.Thread.spawn(.{}, mockRun, .{&ctx});
    // Stop the thread (it polls `stop` between accept timeouts), join, then close
    // — runs on both success and assertion-failure paths, so the test never hangs.
    defer {
        ctx.stop.store(true, .release);
        t.join();
        server.deinit();
    }

    const bridge = Bridge{ .host = "127.0.0.1", .port = port };

    var sess = try Session.create(allocator, bridge, "carltest");
    defer sess.deinit();
    try testing.expectEqualStrings("ZmFrZWRlc3Q=", sess.destination);
    try testing.expect(std.mem.startsWith(u8, sess.id, "carltest-"));

    // Successful CONNECT: the advertised port is threaded as TO_PORT (the mock
    // rejects the connect if it's missing), and the returned stream carries the
    // simulated peer bytes.
    var peer = try sess.connect("examplepeer.b32.i2p", 6881);
    var rbuf: [32]u8 = undefined;
    var got: usize = 0;
    while (got < "BTpayload".len) {
        const n = peer.read(rbuf[got..]) catch break;
        if (n == 0) break;
        got += n;
    }
    peer.close();
    try testing.expectEqualStrings("BTpayload", rbuf[0..got]);

    // Failed CONNECT surfaces as StreamFailed (port 0 → no TO_PORT on the wire).
    try testing.expectError(error.StreamFailed, sess.connect("bad.b32.i2p", 0));
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
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    var server = try addr.listen(.{ .reuse_address = true });
    const port = server.listen_address.getPort();
    // 3.1 bridge: the mock fails the CONNECT if TO_PORT appears, so a passing
    // test proves we omit TO_PORT (rather than send an unsupported parameter).
    var ctx = MockCtx{ .server = &server, .stop = std.atomic.Value(bool).init(false), .version = "3.1" };
    const t = try std.Thread.spawn(.{}, mockRun, .{&ctx});
    defer {
        ctx.stop.store(true, .release);
        t.join();
        server.deinit();
    }

    const bridge = Bridge{ .host = "127.0.0.1", .port = port };
    var sess = try Session.create(allocator, bridge, "carltest");
    defer sess.deinit();

    // Dials with a non-zero port; on a 3.1 bridge it must still succeed with
    // TO_PORT omitted.
    var peer = try sess.connect("examplepeer.b32.i2p", 6881);
    peer.close();
}
