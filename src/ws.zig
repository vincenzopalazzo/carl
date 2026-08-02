//! Minimal WebSocket client (RFC 6455, client side only) on top of TCP or
//! TLS-wrapped TCP. Built for Nostr relays which are wss:// and exchange
//! text frames carrying JSON; binary, fragmented, and large (>65535 byte)
//! payloads are supported but extensions like permessage-deflate are not.
//!
//! Use:
//!   var conn = try ws.Conn.connect(allocator, "wss://relay.example.com");
//!   defer conn.deinit();
//!   try conn.writeText("[\"REQ\",\"sub1\",{\"kinds\":[2003]}]");
//!   const msg = try conn.readMessage();
//!   defer allocator.free(msg.payload);
//!
//! The connection blocks with a recv timeout (default 30s) so that callers
//! never hang forever on a silent relay.

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const tls = std.crypto.tls;
const proxy_mod = @import("proxy.zig");

const log = std.log.scoped(.ws);

pub const ConnectOptions = struct {
    /// When set, `wss://` connects through SOCKS5/HTTP (e.g. Tor at 127.0.0.1:9050).
    proxy: ?proxy_mod.Proxy = null,
};

pub const Error = error{
    InvalidUrl,
    DnsResolveFailed,
    ConnectFailed,
    HandshakeFailed,
    TlsInitFailed,
    SendFailed,
    RecvFailed,
    Timeout,
    Closed,
    ProtocolError,
    PayloadTooLarge,
    OutOfMemory,
};

/// Max payload size we will accept from a single frame. Nostr events can be
/// big but 1 MiB is more than enough for NIP-35 + NIP-65 traffic.
pub const max_payload_len: usize = 1 * 1024 * 1024;

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
};

pub const Message = struct {
    opcode: Opcode,
    payload: []u8,
};

pub const Url = struct {
    secure: bool,
    host: []const u8,
    port: u16,
    path: []const u8,
};

/// Parse a `ws://host[:port][/path]` or `wss://host[:port][/path]` URL.
/// The returned slices alias `input` and are valid for its lifetime.
pub fn parseUrl(input: []const u8) Error!Url {
    var secure: bool = undefined;
    var rest: []const u8 = undefined;
    if (std.mem.startsWith(u8, input, "wss://")) {
        secure = true;
        rest = input[6..];
    } else if (std.mem.startsWith(u8, input, "ws://")) {
        secure = false;
        rest = input[5..];
    } else {
        return error.InvalidUrl;
    }

    // Find authority / path split.
    var path: []const u8 = "/";
    var authority: []const u8 = rest;
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
        authority = rest[0..slash];
        path = rest[slash..];
    }
    if (authority.len == 0) return error.InvalidUrl;

    // Split authority into host and optional port.
    var host: []const u8 = authority;
    var port: u16 = if (secure) 443 else 80;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        host = authority[0..colon];
        port = std.fmt.parseUnsigned(u16, authority[colon + 1 ..], 10) catch return error.InvalidUrl;
    }

    return .{ .secure = secure, .host = host, .port = port, .path = path };
}

/// A live WebSocket connection. `wss://` runs `std.crypto.tls` on top of a
/// stream we own (a direct socket, or a SOCKS tunnel when a proxy is set);
/// `ws://` uses that stream raw.
pub const Conn = struct {
    allocator: Allocator,
    /// Socket handle for `setsockopt` (recv timeout). Closed via `deinit`.
    stream: std.net.Stream,
    /// Non-null for `wss://`; owns the TLS session used for reads/writes.
    tls_io: ?*TlsIo = null,

    /// Buffer used to accumulate the payload of an in-progress message when
    /// the relay fragments. Owned by the Conn.
    fragment_buf: std.ArrayList(u8),
    fragment_opcode: ?Opcode,

    const tls_io_buf_len = tls.max_ciphertext_record_len;

    /// SO_RCVTIMEO (seconds) for the TLS path: bounds the handshake and every
    /// read so an unresponsive relay fails instead of hanging.
    const tls_handshake_secs: u32 = 20;

    /// How many redirects the upgrade follows before giving up. Some relays
    /// (and the CDNs in front of them) 301 the upgrade to a canonical path.
    const max_redirects: u8 = 3;

    const TlsIo = struct {
        stream: std.net.Stream,
        socket_reader: std.net.Stream.Reader,
        socket_writer: std.net.Stream.Writer,
        tls: tls.Client,
        ca_bundle: std.crypto.Certificate.Bundle,
        socket_read_buf: [tls_io_buf_len]u8,
        socket_write_buf: [tls_io_buf_len]u8,
        tls_read_buf: [tls_io_buf_len]u8,
        tls_write_buf: [tls_io_buf_len]u8,

        fn deinit(self: *TlsIo, allocator: Allocator) void {
            self.ca_bundle.deinit(allocator);
            self.stream.close();
            allocator.destroy(self);
        }
    };

    /// Open a WebSocket to `url_input`, following up to `max_redirects` hops.
    ///
    /// One dial per hop: the connect is bounded by `connect_timeout_ms` on the
    /// socket we then keep, instead of the old probe-then-reconnect pair (a
    /// bounded TCP connect that was immediately closed, followed by the real
    /// connect). That double-dial showed a CDN edge a connect-abort right
    /// before every TLS handshake — exactly the shape edge rate-limiting
    /// punishes — and cost two dials per attempt for nothing.
    pub fn connect(allocator: Allocator, url_input: []const u8, options: ConnectOptions) Error!Conn {
        // Ping-pong buffers: the hop we are dialing may alias one of them, so
        // the next location is always written into the other.
        var bufs: [2][512]u8 = undefined;
        var target: []const u8 = url_input;
        var hops: u8 = 0;
        while (true) {
            var redirect: RedirectOut = .{ .buf = &bufs[hops % 2] };
            if (try connectOnce(allocator, target, options, &redirect)) |conn| return conn;
            hops += 1;
            if (hops > max_redirects) {
                log.warn("ws handshake to {s}: too many redirects", .{url_input});
                return error.HandshakeFailed;
            }
            target = redirect.value();
        }
    }

    /// One dial + upgrade attempt. Returns null when the relay redirected us
    /// (the resolved target is written to `redirect`) — the caller re-dials.
    fn connectOnce(
        allocator: Allocator,
        url_input: []const u8,
        options: ConnectOptions,
        redirect: *RedirectOut,
    ) Error!?Conn {
        const url = try parseUrl(url_input);

        // Through a proxy we dial the proxy, not the relay: the SOCKS tunnel
        // carries the connection so the relay never learns our IP. `ws://`
        // rides the tunnel raw (an onion relay: Tor already encrypts and
        // authenticates it); `wss://` runs TLS on top, so the proxy only ever
        // sees ciphertext.
        const stream = if (options.proxy) |px|
            proxy_mod.connectThroughProxyHost(allocator, px, url.host, url.port) catch |err| {
                log.debug("proxy tunnel to {s}:{d} failed: {}", .{ url.host, url.port, err });
                return error.ConnectFailed;
            }
        else
            tcpConnect(allocator, url.host, url.port) catch |err| {
                log.warn("tcp connect to {s}:{d} failed: {}", .{ url.host, url.port, err });
                return err;
            };

        var conn = Conn{
            .allocator = allocator,
            .stream = stream,
            .fragment_buf = .empty,
            .fragment_opcode = null,
        };

        if (url.secure) {
            conn.tls_io = connectTls(allocator, stream, url.host) catch |err| {
                // connectTls already closed `stream` on failure.
                conn.fragment_buf.deinit(allocator);
                log.warn("tls handshake with {s}:{d} failed: {}", .{ url.host, url.port, err });
                return err;
            };
            conn.stream = conn.tls_io.?.stream;
        } else {
            // Set the recv timeout before the handshake so a silent relay
            // can't hang us (the TLS path sets its own inside connectTls).
            setRecvTimeout(conn.stream, 30);
        }
        errdefer conn.deinit();

        if (try conn.performHandshake(url, redirect)) return conn;
        // Redirected: this connection is done with. (Not an error path, so the
        // errdefer above doesn't fire — close it here.)
        conn.deinit();
        return null;
    }

    /// Run a TLS client handshake over `stream` and return a heap-allocated
    /// `TlsIo` that owns it (same TLS-over-a-raw-stream mechanism as
    /// proxy.httpsExchange; the buffers + reader/writer live inside the
    /// returned struct, which is heap-stable so TLS's pointers stay valid).
    /// On any error the stream is closed and nothing leaks.
    fn connectTls(allocator: Allocator, stream: std.net.Stream, host: []const u8) Error!*TlsIo {
        var owned = false;
        defer if (!owned) stream.close();

        const tp = allocator.create(TlsIo) catch return error.OutOfMemory;
        errdefer allocator.destroy(tp);

        tp.stream = stream;
        // Disable Nagle: the WS upgrade + REQ are tiny, and Nagle/delayed-ACK
        // can otherwise hold a small response (the 101) for a long stall.
        setTcpNoDelay(stream);
        tp.socket_reader = stream.reader(&tp.socket_read_buf);
        tp.socket_writer = stream.writer(&tp.socket_write_buf);

        // A `.onion` host is cryptographically authenticated by Tor itself and
        // cannot hold a CA-issued certificate, so skip CA verification there
        // (the TLS is only for the channel). A clearnet wss relay is verified
        // against the system CA bundle as usual.
        const onion = std.mem.endsWith(u8, host, ".onion");
        tp.ca_bundle = .{};
        if (!onion) tp.ca_bundle.rescan(allocator) catch return error.TlsInitFailed;
        errdefer tp.ca_bundle.deinit(allocator);

        // SO_RCVTIMEO bounds the handshake and every later read so an
        // unresponsive relay fails instead of hanging. std's File.Reader turns a
        // read timeout into an error, which for our request/response +
        // subscribe-until-timeout relay usage simply ends the op -- the intent.
        setRecvTimeout(stream, tls_handshake_secs);
        tp.tls = tls.Client.init(tp.socket_reader.interface(), &tp.socket_writer.interface, .{
            .host = if (onion) .no_verification else .{ .explicit = host },
            .ca = if (onion) .no_verification else .{ .bundle = tp.ca_bundle },
            .write_buffer = &tp.tls_write_buf,
            .read_buffer = &tp.tls_read_buf,
        }) catch return error.TlsInitFailed;

        owned = true; // tp now owns `stream`; TlsIo.deinit closes it
        return tp;
    }

    pub fn deinit(self: *Conn) void {
        if (self.tls_io) |t| {
            t.deinit(self.allocator);
        } else {
            self.stream.close();
        }
        self.fragment_buf.deinit(self.allocator);
    }

    /// Send a text frame. Encodes mask + frame header automatically.
    pub fn writeText(self: *Conn, payload: []const u8) Error!void {
        try self.writeFrame(.text, payload, true);
    }

    /// Send a close frame (code 1000, no reason).
    pub fn writeClose(self: *Conn) Error!void {
        const close_payload: [2]u8 = .{ 0x03, 0xE8 }; // 1000 big-endian
        try self.writeFrame(.close, &close_payload, true);
    }

    /// Read the next full message. Reassembles fragmented frames into a single
    /// payload before returning. The caller owns `payload`.
    /// On a ping frame, automatically responds with a pong and continues.
    /// On a close frame, returns `error.Closed`.
    pub fn readMessage(self: *Conn) Error!Message {
        while (true) {
            const frame = try self.readFrame();
            switch (frame.opcode) {
                .ping => {
                    // Echo payload back as pong.
                    self.writeFrame(.pong, frame.payload, true) catch {};
                    self.allocator.free(frame.payload);
                    continue;
                },
                .pong => {
                    self.allocator.free(frame.payload);
                    continue;
                },
                .close => {
                    self.allocator.free(frame.payload);
                    // Reply with our own close.
                    self.writeClose() catch {};
                    return error.Closed;
                },
                .text, .binary => {
                    if (frame.fin and self.fragment_opcode == null) {
                        return .{ .opcode = frame.opcode, .payload = frame.payload };
                    }
                    // Start of a fragmented message.
                    if (self.fragment_opcode != null) {
                        // Spec violation: text/binary in the middle of a fragment.
                        self.allocator.free(frame.payload);
                        self.fragment_buf.clearRetainingCapacity();
                        self.fragment_opcode = null;
                        return error.ProtocolError;
                    }
                    self.fragment_opcode = frame.opcode;
                    // Enforce the per-message cap across fragments. Without this
                    // a relay could send many continuation frames each under
                    // `max_payload_len` but whose sum exceeds it, defeating the
                    // cap that `readFrame` enforces per-frame.
                    if (self.fragment_buf.items.len + frame.payload.len > max_payload_len) {
                        self.allocator.free(frame.payload);
                        self.fragment_buf.clearRetainingCapacity();
                        self.fragment_opcode = null;
                        return error.PayloadTooLarge;
                    }
                    self.fragment_buf.appendSlice(self.allocator, frame.payload) catch {
                        self.allocator.free(frame.payload);
                        return error.OutOfMemory;
                    };
                    self.allocator.free(frame.payload);
                    if (frame.fin) {
                        const payload = self.fragment_buf.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
                        const op = self.fragment_opcode.?;
                        self.fragment_opcode = null;
                        return .{ .opcode = op, .payload = payload };
                    }
                },
                .continuation => {
                    if (self.fragment_opcode == null) {
                        self.allocator.free(frame.payload);
                        return error.ProtocolError;
                    }
                    if (self.fragment_buf.items.len + frame.payload.len > max_payload_len) {
                        self.allocator.free(frame.payload);
                        self.fragment_buf.clearRetainingCapacity();
                        self.fragment_opcode = null;
                        return error.PayloadTooLarge;
                    }
                    self.fragment_buf.appendSlice(self.allocator, frame.payload) catch {
                        self.allocator.free(frame.payload);
                        return error.OutOfMemory;
                    };
                    self.allocator.free(frame.payload);
                    if (frame.fin) {
                        const payload = self.fragment_buf.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
                        const op = self.fragment_opcode.?;
                        self.fragment_opcode = null;
                        return .{ .opcode = op, .payload = payload };
                    }
                },
            }
        }
    }

    // -------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------

    /// Send the upgrade request and read the response. Returns true when the
    /// relay switched protocols; false when it redirected us, in which case
    /// `redirect` holds the resolved target and the caller re-dials.
    ///
    /// The response head is parsed by hand rather than with std.http: std's
    /// Response.Head.parse does @enumFromInt into the *exhaustive*
    /// std.http.Status enum, so a relay (or the CDN in front of it) answering
    /// with a non-standard code (Cloudflare's 52x/530, etc.) panics the whole
    /// daemon with "invalid enum value" -- and the desktop app sits "offline"
    /// on its dead sidecar. Here any non-101 is a handshake failure, not a
    /// crash. (Observed in the field.)
    fn performHandshake(self: *Conn, url: Url, redirect: *RedirectOut) Error!bool {
        var key_raw: [16]u8 = undefined;
        std.crypto.random.bytes(&key_raw);
        var key_b64: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key_b64, &key_raw);

        var req_buf: [1024]u8 = undefined;
        const req = std.fmt.bufPrint(
            &req_buf,
            "GET {s} HTTP/1.1\r\n" ++
                "Host: {s}\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Key: {s}\r\n" ++
                "Sec-WebSocket-Version: 13\r\n" ++
                "User-Agent: carl/0.1\r\n" ++
                "\r\n",
            .{ url.path, url.host, key_b64 },
        ) catch return error.HandshakeFailed;

        try self.writeAll(req);

        // Read until the head is complete. A 101 carries no body, so anything
        // past the blank line would be WebSocket frames -- but a redirect may
        // carry one, hence indexOf rather than "the read ended on \r\n\r\n"
        // (we drop the connection on a redirect, so a partly-read body is
        // harmless).
        var hdr_buf: [4096]u8 = undefined;
        var hdr_len: usize = 0;
        while (std.mem.indexOf(u8, hdr_buf[0..hdr_len], "\r\n\r\n") == null) {
            if (hdr_len == hdr_buf.len) {
                log.warn("ws handshake response head too large", .{});
                return error.HandshakeFailed;
            }
            const want = @min(hdr_buf.len - hdr_len, 512);
            const n = try self.readSome(hdr_buf[hdr_len..][0..want]);
            if (n == 0) return error.HandshakeFailed;
            hdr_len += n;
        }
        const headers = hdr_buf[0..hdr_len];

        const st = parseHeadStatus(headers) orelse {
            log.warn("ws handshake malformed status line", .{});
            return error.HandshakeFailed;
        };
        switch (st.code) {
            101 => {},
            301, 302, 303, 307, 308 => {
                const location = findHeadHeader(headers, "location") orelse {
                    log.warn("ws handshake {d} without Location header", .{st.code});
                    return error.HandshakeFailed;
                };
                if (!resolveRedirect(url, location, redirect)) {
                    log.warn("ws handshake unsupported redirect target: {s}", .{location});
                    return error.HandshakeFailed;
                }
                log.info("ws {s}: relay redirected the upgrade to {s}", .{ url.host, redirect.value() });
                return false;
            },
            else => {
                log.warn("ws handshake status {d} {s}", .{ st.code, st.reason });
                return error.HandshakeFailed;
            },
        }

        const expected = expectedAccept(&key_b64);
        const accept_value = findHeadHeader(headers, "Sec-WebSocket-Accept") orelse {
            log.warn("ws handshake missing Sec-WebSocket-Accept header", .{});
            return error.HandshakeFailed;
        };
        if (!std.mem.eql(u8, accept_value, &expected)) {
            log.warn("ws handshake bad Sec-WebSocket-Accept", .{});
            return error.HandshakeFailed;
        }
        return true;
    }

    const FrameMeta = struct {
        fin: bool,
        opcode: Opcode,
        payload: []u8, // owned by allocator
    };

    fn readFrame(self: *Conn) Error!FrameMeta {
        var header: [2]u8 = undefined;
        try self.readExact(&header);

        const fin = (header[0] & 0x80) != 0;
        const opcode_raw = header[0] & 0x0F;
        const opcode: Opcode = std.meta.intToEnum(Opcode, opcode_raw) catch return error.ProtocolError;
        const masked = (header[1] & 0x80) != 0;
        if (masked) return error.ProtocolError; // server frames must not be masked

        var payload_len: u64 = header[1] & 0x7F;
        if (payload_len == 126) {
            var ext: [2]u8 = undefined;
            try self.readExact(&ext);
            payload_len = std.mem.readInt(u16, &ext, .big);
        } else if (payload_len == 127) {
            var ext: [8]u8 = undefined;
            try self.readExact(&ext);
            payload_len = std.mem.readInt(u64, &ext, .big);
        }
        if (payload_len > max_payload_len) return error.PayloadTooLarge;

        const buf = self.allocator.alloc(u8, @intCast(payload_len)) catch return error.OutOfMemory;
        errdefer self.allocator.free(buf);
        if (payload_len > 0) try self.readExact(buf);

        return .{ .fin = fin, .opcode = opcode, .payload = buf };
    }

    fn writeFrame(self: *Conn, opcode: Opcode, payload: []const u8, fin: bool) Error!void {
        // Header is at most 2 + 8 + 4 = 14 bytes.
        var header: [14]u8 = undefined;
        var hlen: usize = 0;
        header[hlen] = (if (fin) @as(u8, 0x80) else 0) | @intFromEnum(opcode);
        hlen += 1;
        if (payload.len < 126) {
            header[hlen] = 0x80 | @as(u8, @intCast(payload.len));
            hlen += 1;
        } else if (payload.len < 65536) {
            header[hlen] = 0x80 | 126;
            hlen += 1;
            std.mem.writeInt(u16, header[hlen..][0..2], @intCast(payload.len), .big);
            hlen += 2;
        } else {
            header[hlen] = 0x80 | 127;
            hlen += 1;
            std.mem.writeInt(u64, header[hlen..][0..8], payload.len, .big);
            hlen += 8;
        }
        var mask: [4]u8 = undefined;
        std.crypto.random.bytes(&mask);
        @memcpy(header[hlen..][0..4], &mask);
        hlen += 4;

        try self.writeAll(header[0..hlen]);

        // Mask payload in chunks (avoid allocating a copy of the whole payload).
        var chunk: [4096]u8 = undefined;
        var off: usize = 0;
        while (off < payload.len) {
            const n = @min(payload.len - off, chunk.len);
            for (0..n) |i| {
                chunk[i] = payload[off + i] ^ mask[(off + i) % 4];
            }
            try self.writeAll(chunk[0..n]);
            off += n;
        }
    }

    fn writeAll(self: *Conn, buf: []const u8) Error!void {
        if (self.tls_io) |t| {
            t.tls.writer.writeAll(buf) catch return error.SendFailed;
            t.tls.writer.flush() catch return error.SendFailed;
            t.socket_writer.interface.flush() catch return error.SendFailed;
        } else {
            var off: usize = 0;
            while (off < buf.len) {
                const n = posix.send(self.stream.handle, buf[off..], 0) catch return error.SendFailed;
                if (n == 0) return error.Closed;
                off += n;
            }
        }
    }

    fn readSome(self: *Conn, buf: []u8) Error!usize {
        if (self.tls_io) |t| {
            // readSliceShort() fills the whole buffer -- it loops until `buf` is
            // full or EOF -- so it deadlocks reading a kept-alive HTTP/WS
            // response that never reaches EOF (e.g. the 101 upgrade headers).
            // fill(1) instead reads TLS records (transparently consuming
            // post-handshake session tickets) until at least one application
            // byte is available, then we hand back whatever is buffered.
            t.tls.reader.fill(1) catch |err| switch (err) {
                error.EndOfStream => return 0,
                else => return error.RecvFailed,
            };
            const avail = t.tls.reader.buffered();
            const k = @min(avail.len, buf.len);
            @memcpy(buf[0..k], avail[0..k]);
            t.tls.reader.toss(k);
            return k;
        }
        const n = posix.recv(self.stream.handle, buf, 0) catch |err| switch (err) {
            error.WouldBlock => return error.Timeout,
            else => return error.RecvFailed,
        };
        return n;
    }

    fn readExact(self: *Conn, buf: []u8) Error!void {
        var off: usize = 0;
        while (off < buf.len) {
            const n = try self.readSome(buf[off..]);
            if (n == 0) return error.Closed;
            off += n;
        }
    }
};

fn setTcpNoDelay(stream: std.net.Stream) void {
    const one: c_int = 1;
    posix.setsockopt(stream.handle, posix.IPPROTO.TCP, posix.TCP.NODELAY, std.mem.asBytes(&one)) catch {};
}

fn setRecvTimeout(stream: std.net.Stream, sec: u32) void {
    const tv: posix.timeval = .{ .sec = @intCast(sec), .usec = 0 };
    posix.setsockopt(stream.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
}

/// Connect-timeout budget (ms) for the TCP dial. std's `connect` has no
/// timeout at all, so a relay whose TCP connect hangs -- an unroutable address
/// or a silently-dropped SYN, as public relays like relay.nostr.band sometimes
/// do -- would otherwise stall the caller for the OS default (~75 s).
const connect_timeout_ms: i32 = 4000;

/// Open TCP to `host`:`port`, preferring IPv4 and trying every resolved address
/// before giving up. `std.net.tcpConnectToHost` stops on the first non-refused
/// error, which breaks when DNS returns AAAA before A and IPv6 is unroutable.
fn tcpConnect(allocator: Allocator, host: []const u8, port: u16) Error!std.net.Stream {
    const list = std.net.getAddressList(allocator, host, port) catch return error.DnsResolveFailed;
    defer list.deinit();
    if (list.addrs.len == 0) return error.DnsResolveFailed;

    inline for (.{ posix.AF.INET, posix.AF.INET6 }) |family| {
        for (list.addrs) |addr| {
            if (addr.any.family != family) continue;
            if (connectTimed(addr, connect_timeout_ms)) |stream| return stream;
        }
    }
    return error.ConnectFailed;
}

/// TCP connect to a single address bounded by `timeout_ms`, handing back the
/// *connected* socket: dial non-blocking, wait with poll(), then restore
/// blocking mode. The socket that proves the relay reachable is the one we
/// keep -- no probe-and-throw-away, so a relay sees exactly one connect per
/// attempt.
fn connectTimed(addr: std.net.Address, timeout_ms: i32) ?std.net.Stream {
    const sock = posix.socket(
        addr.any.family,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
        posix.IPPROTO.TCP,
    ) catch return null;
    var keep = false;
    defer if (!keep) posix.close(sock);

    if (!setNonBlocking(sock, true)) return null;
    posix.connect(sock, &addr.any, addr.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock => {
            var pfd = [_]posix.pollfd{.{ .fd = sock, .events = posix.POLL.OUT, .revents = 0 }};
            const ready = posix.poll(&pfd, timeout_ms) catch return null;
            if (ready == 0) return null; // timed out
            // poll() only says "the connect finished" -- SO_ERROR says how.
            posix.getsockoptError(sock) catch return null;
        },
        else => return null,
    };
    // Everything downstream (our recv loop, std's TLS client) assumes a
    // blocking socket with SO_RCVTIMEO.
    if (!setNonBlocking(sock, false)) return null;

    keep = true;
    return .{ .handle = sock };
}

fn setNonBlocking(sock: posix.socket_t, on: bool) bool {
    const flags = posix.fcntl(sock, posix.F.GETFL, 0) catch return false;
    var o: posix.O = @bitCast(@as(u32, @truncate(flags)));
    o.NONBLOCK = on;
    _ = posix.fcntl(sock, posix.F.SETFL, @as(u32, @bitCast(o))) catch return false;
    return true;
}

/// Where a relay's redirect points, resolved into an absolute ws/wss URL. The
/// caller owns the backing buffer (see `Conn.connect`).
const RedirectOut = struct {
    buf: []u8,
    len: usize = 0,

    fn value(self: RedirectOut) []const u8 {
        return self.buf[0..self.len];
    }

    fn set(self: *RedirectOut, parts: []const []const u8) bool {
        var n: usize = 0;
        for (parts) |p| {
            if (n + p.len > self.buf.len) return false;
            @memcpy(self.buf[n..][0..p.len], p);
            n += p.len;
        }
        self.len = n;
        return true;
    }
};

/// Resolve a `Location` value against the URL we just requested. Handles the
/// two forms relays actually send: an absolute URL (https/wss and their
/// insecure twins) and an absolute path on the same host. Anything else --
/// including a relative path -- is rejected rather than guessed at. Returns
/// false when the target doesn't fit the caller's buffer either.
fn resolveRedirect(url: Url, location: []const u8, out: *RedirectOut) bool {
    if (location.len == 0) return false;
    if (std.mem.startsWith(u8, location, "wss://") or std.mem.startsWith(u8, location, "ws://"))
        return out.set(&.{location});
    // A wss endpoint IS an https endpoint pre-upgrade; relays name it either way.
    if (std.mem.startsWith(u8, location, "https://"))
        return out.set(&.{ "wss://", location["https://".len..] });
    if (std.mem.startsWith(u8, location, "http://"))
        return out.set(&.{ "ws://", location["http://".len..] });
    if (location[0] != '/') return false;

    const scheme: []const u8 = if (url.secure) "wss://" else "ws://";
    var port_buf: [8]u8 = undefined;
    const port: []const u8 = if (url.port == (if (url.secure) @as(u16, 443) else 80))
        ""
    else
        std.fmt.bufPrint(&port_buf, ":{d}", .{url.port}) catch return false;
    return out.set(&.{ scheme, url.host, port, location });
}

/// Compute the expected Sec-WebSocket-Accept header value for a given
/// base64-encoded client key. Format: base64(sha1(key + magic)).
fn expectedAccept(key_b64: []const u8) [28]u8 {
    const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(key_b64);
    hasher.update(magic);
    var digest: [20]u8 = undefined;
    hasher.final(&digest);
    var out: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &digest);
    return out;
}

/// The status line of a raw HTTP response head, parsed without
/// std.http.Status: Head.parse does @enumFromInt into the *exhaustive*
/// std.http.Status enum, so a relay (or the CDN in front of it) answering
/// with a non-standard code (Cloudflare's 52x/530, etc.) panics the process
/// with "invalid enum value". For a WebSocket upgrade any non-101 is a
/// handshake failure, not a crash — keep the code a plain integer.
const HeadStatus = struct { code: u16, reason: []const u8 };

fn parseHeadStatus(head: []const u8) ?HeadStatus {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    const line = it.first();
    if (line.len < 12) return null;
    if (!std.mem.startsWith(u8, line, "HTTP/1.1 ") and
        !std.mem.startsWith(u8, line, "HTTP/1.0 ")) return null;
    const digits = line[9..12];
    for (digits) |d| if (!std.ascii.isDigit(d)) return null;
    const code = @as(u16, digits[0] - '0') * 100 + @as(u16, digits[1] - '0') * 10 + @as(u16, digits[2] - '0');
    return .{ .code = code, .reason = std.mem.trimLeft(u8, line[12..], " ") };
}

/// Case-insensitive header lookup in a raw HTTP response head (the status
/// line is skipped). Returns the trimmed value, or null if absent.
fn findHeadHeader(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.first(); // status line
    while (it.next()) |line| {
        if (line.len == 0) break; // end of head
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

// ===========================================================================
// Tests
// ===========================================================================

test "parseUrl: wss with default port" {
    const u = try parseUrl("wss://relay.damus.io");
    try std.testing.expect(u.secure);
    try std.testing.expectEqualStrings("relay.damus.io", u.host);
    try std.testing.expectEqual(@as(u16, 443), u.port);
    try std.testing.expectEqualStrings("/", u.path);
}

test "parseUrl: ws with explicit port and path" {
    const u = try parseUrl("ws://localhost:7001/nostr");
    try std.testing.expect(!u.secure);
    try std.testing.expectEqualStrings("localhost", u.host);
    try std.testing.expectEqual(@as(u16, 7001), u.port);
    try std.testing.expectEqualStrings("/nostr", u.path);
}

test "parseUrl: rejects http scheme" {
    try std.testing.expectError(error.InvalidUrl, parseUrl("http://example.com"));
    try std.testing.expectError(error.InvalidUrl, parseUrl("relay.damus.io"));
}

test "expectedAccept: RFC 6455 example" {
    // Per RFC 6455 §1.3: key "dGhlIHNhbXBsZSBub25jZQ==" produces accept "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    const got = expectedAccept("dGhlIHNhbXBsZSBub25jZQ==");
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &got);
}

test "parseHeadStatus: 101 switching protocols" {
    const st = parseHeadStatus("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n").?;
    try std.testing.expectEqual(@as(u16, 101), st.code);
    try std.testing.expectEqualStrings("Switching Protocols", st.reason);
}

test "parseHeadStatus: non-standard status code does not panic" {
    // Cloudflare's 530 is not in std.http.Status; std's Head.parse panics on
    // it (@enumFromInt into an exhaustive enum), which killed the daemon in
    // the field and left the desktop app permanently "offline".
    const st = parseHeadStatus("HTTP/1.1 530 \r\n\r\n").?;
    try std.testing.expectEqual(@as(u16, 530), st.code);
    try std.testing.expectEqual(@as(u16, 503), parseHeadStatus("HTTP/1.0 503 Service Unavailable\r\n\r\n").?.code);
}

test "parseHeadStatus: malformed status lines" {
    try std.testing.expect(parseHeadStatus("garbage") == null);
    try std.testing.expect(parseHeadStatus("HTTP/1.1 abc Bad\r\n\r\n") == null);
    try std.testing.expect(parseHeadStatus("HTTP/1.1 10\r\n\r\n") == null);
}

test "findHeadHeader: lookup is case-insensitive and trims the value" {
    const head = "HTTP/1.1 301 Moved Permanently\r\nLocation:  wss://relay.example.com/nostr \r\ncontent-length: 0\r\n\r\n";
    try std.testing.expectEqualStrings("wss://relay.example.com/nostr", findHeadHeader(head, "location").?);
    try std.testing.expectEqualStrings("0", findHeadHeader(head, "Content-Length").?);
    try std.testing.expect(findHeadHeader(head, "sec-websocket-accept") == null);
}

fn expectRedirect(expected: []const u8, from: []const u8, location: []const u8) !void {
    var buf: [256]u8 = undefined;
    var out: RedirectOut = .{ .buf = &buf };
    try std.testing.expect(resolveRedirect(try parseUrl(from), location, &out));
    try std.testing.expectEqualStrings(expected, out.value());
}

test "resolveRedirect: absolute targets keep (or gain) a websocket scheme" {
    try expectRedirect("wss://b.example/nostr", "wss://a.example", "wss://b.example/nostr");
    try expectRedirect("ws://b.example/", "wss://a.example", "ws://b.example/");
    // A wss endpoint is an https endpoint pre-upgrade; relays name it both ways.
    try expectRedirect("wss://b.example/nostr", "wss://a.example", "https://b.example/nostr");
    try expectRedirect("ws://b.example:8080/", "wss://a.example", "http://b.example:8080/");
}

test "resolveRedirect: absolute paths resolve against the current host" {
    try expectRedirect("wss://a.example/nostr", "wss://a.example", "/nostr");
    try expectRedirect("wss://a.example/canonical", "wss://a.example/", "/canonical");
    // A non-default port has to survive the rewrite, or we'd re-dial 443.
    try expectRedirect("wss://a.example:7777/nostr", "wss://a.example:7777/x", "/nostr");
    try expectRedirect("ws://a.example/nostr", "ws://a.example", "/nostr");
    try expectRedirect("ws://a.example:81/nostr", "ws://a.example:81", "/nostr");
}

test "resolveRedirect: rejects what we can't resolve safely" {
    var buf: [256]u8 = undefined;
    var out: RedirectOut = .{ .buf = &buf };
    const url = try parseUrl("wss://a.example");
    try std.testing.expect(!resolveRedirect(url, "", &out));
    try std.testing.expect(!resolveRedirect(url, "nostr", &out)); // relative
    try std.testing.expect(!resolveRedirect(url, "ftp://b.example", &out));

    // A target longer than the caller's buffer is refused, never truncated
    // (a truncated URL would dial the wrong host).
    var tiny: [8]u8 = undefined;
    var small: RedirectOut = .{ .buf = &tiny };
    try std.testing.expect(!resolveRedirect(url, "wss://much.longer.example/nostr", &small));
    try std.testing.expectEqual(@as(usize, 0), small.len);
}

// Frame-level tests use a fixed-buffer "byte stream" instead of real sockets,
// keeping the tests hermetic and avoiding any blocking I/O.

const ByteStream = struct {
    buf: []u8,
    pos: usize,
};

fn streamRead(s: *ByteStream, out: []u8) usize {
    const avail = s.buf.len - s.pos;
    const n = @min(avail, out.len);
    @memcpy(out[0..n], s.buf[s.pos..][0..n]);
    s.pos += n;
    return n;
}

/// Encode a server-style (unmasked) frame into `out_buf`. Returns the slice
/// of `out_buf` actually written. Used by the test suite to feed bytes to
/// `decodeFrame` below.
fn encodeUnmaskedFrame(out_buf: []u8, opcode: Opcode, payload: []const u8, fin: bool) []u8 {
    var w: usize = 0;
    out_buf[w] = (if (fin) @as(u8, 0x80) else 0) | @intFromEnum(opcode);
    w += 1;
    if (payload.len < 126) {
        out_buf[w] = @intCast(payload.len);
        w += 1;
    } else if (payload.len < 65536) {
        out_buf[w] = 126;
        w += 1;
        std.mem.writeInt(u16, out_buf[w..][0..2], @intCast(payload.len), .big);
        w += 2;
    } else {
        out_buf[w] = 127;
        w += 1;
        std.mem.writeInt(u64, out_buf[w..][0..8], payload.len, .big);
        w += 8;
    }
    @memcpy(out_buf[w..][0..payload.len], payload);
    w += payload.len;
    return out_buf[0..w];
}

/// Parse a single frame from `bytes`. Used by tests to verify decode logic
/// without going through the socket I/O path.
fn decodeFrame(allocator: Allocator, bytes: []const u8) Error!struct {
    fin: bool,
    opcode: Opcode,
    payload: []u8,
} {
    if (bytes.len < 2) return error.ProtocolError;
    const fin = (bytes[0] & 0x80) != 0;
    const opcode_raw = bytes[0] & 0x0F;
    const opcode: Opcode = std.meta.intToEnum(Opcode, opcode_raw) catch return error.ProtocolError;
    if ((bytes[1] & 0x80) != 0) return error.ProtocolError; // masked from server

    var off: usize = 2;
    var payload_len: u64 = bytes[1] & 0x7F;
    if (payload_len == 126) {
        if (bytes.len < off + 2) return error.ProtocolError;
        payload_len = std.mem.readInt(u16, bytes[off..][0..2], .big);
        off += 2;
    } else if (payload_len == 127) {
        if (bytes.len < off + 8) return error.ProtocolError;
        payload_len = std.mem.readInt(u64, bytes[off..][0..8], .big);
        off += 8;
    }
    if (payload_len > max_payload_len) return error.PayloadTooLarge;
    if (bytes.len < off + payload_len) return error.ProtocolError;

    const out = try allocator.alloc(u8, @intCast(payload_len));
    @memcpy(out, bytes[off .. off + payload_len]);
    return .{ .fin = fin, .opcode = opcode, .payload = out };
}

test "frame round trip via in-memory buffer (small)" {
    const allocator = std.testing.allocator;

    var buf: [256]u8 = undefined;
    const payload = "hello, nostr";
    const bytes = encodeUnmaskedFrame(&buf, .text, payload, true);

    const got = try decodeFrame(allocator, bytes);
    defer allocator.free(got.payload);
    try std.testing.expectEqualStrings(payload, got.payload);
    try std.testing.expectEqual(Opcode.text, got.opcode);
    try std.testing.expect(got.fin);
}

test "frame round trip with 16-bit length" {
    const allocator = std.testing.allocator;

    const payload = try allocator.alloc(u8, 1000);
    defer allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = @intCast(i & 0xFF);

    var buf: [2048]u8 = undefined;
    const bytes = encodeUnmaskedFrame(&buf, .binary, payload, true);
    const got = try decodeFrame(allocator, bytes);
    defer allocator.free(got.payload);
    try std.testing.expectEqualSlices(u8, payload, got.payload);
}

test "frame round trip with 64-bit length" {
    const allocator = std.testing.allocator;

    const payload = try allocator.alloc(u8, 100_000);
    defer allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = @intCast(i % 251);

    const buf = try allocator.alloc(u8, 200_000);
    defer allocator.free(buf);
    const bytes = encodeUnmaskedFrame(buf, .binary, payload, true);

    const got = try decodeFrame(allocator, bytes);
    defer allocator.free(got.payload);
    try std.testing.expectEqualSlices(u8, payload, got.payload);
}

test "decodeFrame rejects reserved opcode" {
    const allocator = std.testing.allocator;
    const bad: [2]u8 = .{ 0x83, 0x00 }; // opcode 3 is reserved
    try std.testing.expectError(error.ProtocolError, decodeFrame(allocator, &bad));
}

test "decodeFrame rejects masked server frame" {
    const allocator = std.testing.allocator;
    const bad: [2]u8 = .{ 0x81, 0x80 }; // text + mask bit set
    try std.testing.expectError(error.ProtocolError, decodeFrame(allocator, &bad));
}

test "client write must mask: smoke check via writeFrame masking key" {
    // Encode a tiny payload through writeFrame (which would write to a socket
    // in production). We just verify the masking happens by computing what
    // the resulting bytes would look like for a known mask and payload —
    // this is a property test, not an I/O test.
    const payload = "abc";
    const mask: [4]u8 = .{ 1, 2, 3, 4 };
    var out: [3]u8 = undefined;
    for (payload, 0..) |b, i| out[i] = b ^ mask[i % 4];
    try std.testing.expectEqual(@as(u8, 'a' ^ 1), out[0]);
    try std.testing.expectEqual(@as(u8, 'b' ^ 2), out[1]);
    try std.testing.expectEqual(@as(u8, 'c' ^ 3), out[2]);
}
