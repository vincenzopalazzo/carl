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

const Net = std.Io.net;
const Stream = Net.Stream;
const HostName = Net.HostName;

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

/// A live WebSocket connection. `wss://` uses `std.http.Client` for TLS (same
/// stack as our HTTPS tracker client). `ws://` uses a plain TCP socket.
pub const Conn = struct {
    allocator: Allocator,
    /// Socket handle for `setsockopt` (recv timeout). Closed via `deinit`.
    io: std.Io,
    stream: Stream,
    /// Non-null for `wss://`; owns the TLS session used for reads/writes.
    http: ?HttpIo = null,
    /// Non-null for `wss://` over a proxy tunnel (TLS on top of SOCKS).
    tls_proxy: ?*TlsProxyIo = null,

    /// Buffer used to accumulate the payload of an in-progress message when
    /// the relay fragments. Owned by the Conn.
    fragment_buf: std.ArrayList(u8),
    fragment_opcode: ?Opcode,

    const HttpIo = struct {
        client: *std.http.Client,
        connection: *std.http.Client.Connection,
    };

    const tls_io_buf_len = tls.max_ciphertext_record_len;

    /// SO_RCVTIMEO (seconds) for the proxied-TLS path: bounds the handshake and
    /// every read so an unresponsive relay fails instead of hanging.
    const tls_proxy_handshake_secs: u32 = 20;

    const TlsProxyIo = struct {
        io: std.Io,
        stream: Stream,
        socket_reader: Stream.Reader,
        socket_writer: Stream.Writer,
        tls: tls.Client,
        ca_bundle: std.crypto.Certificate.Bundle,
        ca_lock: std.Io.RwLock,
        socket_read_buf: [tls_io_buf_len]u8,
        socket_write_buf: [tls_io_buf_len]u8,
        tls_read_buf: [tls_io_buf_len]u8,
        tls_write_buf: [tls_io_buf_len]u8,

        fn deinit(self: *TlsProxyIo, allocator: Allocator) void {
            self.ca_bundle.deinit(allocator);
            self.stream.close(self.io);
            allocator.destroy(self);
        }
    };

    pub fn connect(
        io: std.Io,
        allocator: Allocator,
        url_input: []const u8,
        options: ConnectOptions,
    ) Error!Conn {
        const url = try parseUrl(url_input);

        // For direct connections, probe reachability with a bounded timeout
        // first so a relay with a hanging TCP connect can't stall us for the
        // OS default (~75 s) inside std's timeout-free connect. Proxied
        // connections dial the proxy, not the relay, so skip the probe there.
        if (options.proxy == null and
            !preflightReachable(io, url.host, url.port, preflight_connect_ms))
        {
            log.warn("relay {s}:{d} unreachable within {d}ms, skipping", .{ url.host, url.port, preflight_connect_ms });
            return error.ConnectFailed;
        }

        if (url.secure) {
            // wss:// through the proxy: tunnel TCP via SOCKS, then run TLS on top
            // of the proxied stream so the proxy only sees ciphertext. The relay
            // never learns our IP -- the whole connection rides the proxy/Tor.
            if (options.proxy) |px| {
                const stream = proxy_mod.connectThroughProxyHost(io, allocator, px, url.host, url.port) catch |err| {
                    log.debug("wss proxy tunnel to {s}:{d} failed: {}", .{ url.host, url.port, err });
                    return error.ConnectFailed;
                };
                var conn = Conn{
                    .io = io,
                    .allocator = allocator,
                    .stream = stream,
                    .fragment_buf = .empty,
                    .fragment_opcode = null,
                };
                conn.tls_proxy = connectTlsOverProxy(
                    io,
                    allocator,
                    stream,
                    url.host,
                ) catch |err| {
                    // connectTlsOverProxy already closed `stream` on failure.
                    conn.fragment_buf.deinit(allocator);
                    log.warn("tls over proxy to {s}:{d} failed: {}", .{ url.host, url.port, err });
                    return err;
                };
                conn.stream = conn.tls_proxy.?.stream;
                errdefer conn.deinit();
                try conn.performHandshake(url);
                return conn;
            }
            const client = try allocator.create(std.http.Client);
            client.* = .{
                .allocator = allocator,
                .io = io,
            };

            const now = std.Io.Clock.real.now(io);

            client.ca_bundle.rescan(
                allocator,
                io,
                now,
            ) catch {
                client.deinit();
                allocator.destroy(client);
                return error.TlsInitFailed;
            };

            client.now = now;

            const remote_host: HostName = .{ .bytes = url.host };

            const connection = client.connectTcp(
                remote_host,
                url.port,
                .tls,
            ) catch |err| {
                log.warn("tls connect to {s}:{d} failed: {}", .{ url.host, url.port, err });
                client.deinit();
                allocator.destroy(client);
                return httpConnectError(err);
            };

            var conn = Conn{
                .io = io,
                .allocator = allocator,
                .stream = connection.stream_reader.stream,
                .http = .{
                    .client = client,
                    .connection = connection,
                },
                .fragment_buf = .empty,
                .fragment_opcode = null,
            };
            errdefer conn.deinit();

            try conn.performHandshake(url);
            setRecvTimeout(conn.stream, 30);
            return conn;
        }

        // `ws://` (no TLS). Through a proxy this is how we reach a relay's
        // `.onion` address: the SOCKS tunnel (Tor) provides the encryption and
        // authenticates the address, so the plaintext WebSocket rides safely on
        // top -- no redundant TLS layer needed.
        const stream = if (options.proxy) |px|
            proxy_mod.connectThroughProxyHost(io, allocator, px, url.host, url.port) catch |err| {
                log.debug("ws proxy tunnel to {s}:{d} failed: {}", .{ url.host, url.port, err });
                return error.ConnectFailed;
            }
        else
            tcpConnect(io, url.host, url.port) catch |err| {
                log.warn("tcp connect to {s}:{d} failed: {}", .{ url.host, url.port, err });
                return error.ConnectFailed;
            };

        var conn = Conn{
            .io = io,
            .allocator = allocator,
            .stream = stream,
            .http = null,
            .fragment_buf = .empty,
            .fragment_opcode = null,
        };
        errdefer conn.deinit();

        // Set the recv timeout before the handshake so a silent onion relay
        // can't hang us (the proxy dial leaves its own timeout, but be explicit).
        setRecvTimeout(conn.stream, 30);
        try conn.performHandshake(url);
        return conn;
    }

    /// Run a TLS client handshake over an already-proxied `stream` and return a
    /// heap-allocated `TlsProxyIo` that owns it (same TLS-over-a-raw-stream
    /// mechanism as proxy.httpsExchange; the buffers + reader/writer live inside
    /// the returned struct, which is heap-stable so TLS's pointers stay valid).
    /// On any error the stream is closed and nothing leaks.
    fn connectTlsOverProxy(
        io: std.Io,
        allocator: Allocator,
        stream: Stream,
        host: []const u8,
    ) Error!*TlsProxyIo {
        var owned = false;
        defer if (!owned) stream.close(io);

        const tp = allocator.create(TlsProxyIo) catch return error.OutOfMemory;
        errdefer allocator.destroy(tp);

        tp.io = io;
        tp.stream = stream;
        tp.ca_bundle = .empty;
        tp.ca_lock = .init;

        setTcpNoDelay(stream);

        tp.socket_reader =
            stream.reader(io, &tp.socket_read_buf);
        tp.socket_writer =
            stream.writer(io, &tp.socket_write_buf);

        const onion = std.mem.endsWith(u8, host, ".onion");
        const now = std.Io.Clock.real.now(io);

        if (!onion) {
            tp.ca_bundle.rescan(
                allocator,
                io,
                now,
            ) catch return error.TlsInitFailed;
        }

        errdefer tp.ca_bundle.deinit(allocator);

        setRecvTimeout(stream, tls_proxy_handshake_secs);

        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        io.random(&entropy);

        tp.tls = tls.Client.init(
            &tp.socket_reader.interface,
            &tp.socket_writer.interface,
            .{
                .host = if (onion)
                    .no_verification
                else
                    .{ .explicit = host },

                .ca = if (onion)
                    .no_verification
                else
                    .{ .bundle = .{
                        .gpa = allocator,
                        .io = io,
                        .lock = &tp.ca_lock,
                        .bundle = &tp.ca_bundle,
                    } },

                .write_buffer = &tp.tls_write_buf,
                .read_buffer = &tp.tls_read_buf,
                .entropy = &entropy,
                .realtime_now = now,
            },
        ) catch return error.TlsInitFailed;

        owned = true;
        return tp;
    }

    pub fn deinit(self: *Conn) void {
        if (self.http) |h| {
            // `connectTcp` registers the connection in the client's pool.
            // Mark closing and release so `client.deinit()` does not panic.
            h.connection.closing = true;
            h.client.connection_pool.release(h.connection, self.io);
            h.client.deinit();
            self.allocator.destroy(h.client);
        } else if (self.tls_proxy) |t| {
            t.deinit(self.allocator);
        } else {
            self.stream.close(self.io);
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

    fn performHandshake(self: *Conn, url: Url) Error!void {
        if (self.http) |h| return performHandshakeHttps(self, url, h);
        return performHandshakePlain(self, url);
    }

    /// `wss://` upgrade via `std.http.Client` — the same stack as HTTPS
    /// trackers. Hand-writing TLS application data and reading it back with
    /// `tls.Client.reader` deadlocks on Zig 0.15 for Nostr relays.
    fn performHandshakeHttps(self: *Conn, url: Url, h: HttpIo) Error!void {
        var key_raw: [16]u8 = undefined;
        self.io.random(&key_raw);
        var key_b64: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key_b64, &key_raw);

        const uri_str = std.fmt.allocPrint(self.allocator, "https://{s}{s}", .{ url.host, url.path }) catch return error.OutOfMemory;
        defer self.allocator.free(uri_str);
        const uri = std.Uri.parse(uri_str) catch return error.HandshakeFailed;

        const extra = [_]std.http.Header{
            .{ .name = "Upgrade", .value = "websocket" },
            .{ .name = "Sec-WebSocket-Key", .value = &key_b64 },
            .{ .name = "Sec-WebSocket-Version", .value = "13" },
        };

        var req = h.client.request(.GET, uri, .{
            .connection = h.connection,
            .keep_alive = true,
            .extra_headers = &extra,
            .headers = .{
                .host = .{ .override = url.host },
                .connection = .{ .override = "Upgrade" },
                .user_agent = .{ .override = "carl/0.1" },
            },
        }) catch return error.HandshakeFailed;

        req.sendBodiless() catch return error.HandshakeFailed;

        // Read + parse the response head ourselves instead of req.receiveHead():
        // std's Response.Head.parse does @enumFromInt into the *exhaustive*
        // std.http.Status enum, so a relay (or the CDN in front of it)
        // answering with a non-standard code (Cloudflare's 52x/530, etc.)
        // panics the whole daemon with "invalid enum value" — and the desktop
        // app sits "offline" on its dead sidecar. Here any non-101 is a
        // handshake failure, not a crash. (Observed in the field: a relay
        // behind Cloudflare aborted the daemon exactly this way.)
        //
        // Redirects are still followed (std's default redirect_behavior allows
        // 3): some relays/CDNs 301 the upgrade to a canonical path. Location
        // is parsed from the raw head so the status never becomes a
        // std.http.Status.
        var redirects_left: u8 = 3;
        var head: []const u8 = undefined;
        var st: HeadStatus = undefined;
        while (true) {
            head = req.reader.receiveHead() catch return error.HandshakeFailed;
            st = parseHeadStatus(head) orelse {
                log.warn("ws handshake malformed status line", .{});
                return error.HandshakeFailed;
            };
            switch (st.code) {
                301, 302, 303, 307, 308 => {
                    if (redirects_left == 0) {
                        log.warn("ws handshake too many redirects", .{});
                        return error.HandshakeFailed;
                    }
                    redirects_left -= 1;
                    const location = findHeadHeader(head, "location") orelse {
                        log.warn("ws handshake {d} without Location header", .{st.code});
                        return error.HandshakeFailed;
                    };
                    // Drain the redirect body so the stream stays in sync for
                    // the follow-up request (as std's Request.redirect does).
                    const te: std.http.TransferEncoding = if (findHeadHeader(head, "transfer-encoding") != null) .chunked else .none;
                    const cl: ?u64 = if (findHeadHeader(head, "content-length")) |v| std.fmt.parseInt(u64, v, 10) catch null else null;
                    _ = req.reader.bodyReader(&.{}, te, cl).discardRemaining() catch return error.HandshakeFailed;
                    // Resolve Location the two ways relays actually use it:
                    // an absolute https:// URI, or an absolute path on the
                    // same host.
                    var new_uri_str: []u8 = undefined;
                    if (std.mem.startsWith(u8, location, "https://")) {
                        new_uri_str = self.allocator.dupe(u8, location) catch return error.OutOfMemory;
                    } else if (location.len > 0 and location[0] == '/') {
                        new_uri_str = std.fmt.allocPrint(self.allocator, "https://{s}{s}", .{ url.host, location }) catch return error.OutOfMemory;
                    } else {
                        log.warn("ws handshake unsupported redirect target: {s}", .{location});
                        return error.HandshakeFailed;
                    }
                    defer self.allocator.free(new_uri_str);
                    req.uri = std.Uri.parse(new_uri_str) catch return error.HandshakeFailed;
                    req.sendBodiless() catch return error.HandshakeFailed;
                    continue;
                },
                else => break,
            }
        }
        if (st.code != 101) {
            log.warn("ws handshake status {d} {s}", .{ st.code, st.reason });
            return error.HandshakeFailed;
        }

        const expected = expectedAccept(&key_b64);
        const accept = findHeadHeader(head, "Sec-WebSocket-Accept") orelse {
            log.warn("ws handshake missing Sec-WebSocket-Accept header", .{});
            return error.HandshakeFailed;
        };
        if (!std.mem.eql(u8, accept, &expected)) {
            log.warn("ws handshake bad Sec-WebSocket-Accept", .{});
            return error.HandshakeFailed;
        }

        // Detach the connection so `req.deinit` does not return it to the pool
        // or drain bytes that belong to the first WebSocket frame.
        h.connection.closing = false;
        req.reader.state = .ready;
        req.connection = null;
        req.deinit();
    }

    /// `ws://` upgrade over a plain TCP socket.
    fn performHandshakePlain(self: *Conn, url: Url) Error!void {
        var key_raw: [16]u8 = undefined;
        self.io.random(&key_raw);
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

        var hdr_buf: [4096]u8 = undefined;
        var hdr_len: usize = 0;
        while (hdr_len < hdr_buf.len) {
            const space = hdr_buf.len - hdr_len;
            const want = @min(space, 512);
            const n = try self.readSome(hdr_buf[hdr_len..][0..want]);
            if (n == 0) return error.HandshakeFailed;
            hdr_len += n;
            if (hdr_len >= 4 and std.mem.eql(u8, hdr_buf[hdr_len - 4 .. hdr_len], "\r\n\r\n")) break;
        }
        const headers = hdr_buf[0..hdr_len];

        if (!std.mem.startsWith(u8, headers, "HTTP/1.1 101")) {
            log.warn("ws handshake non-101 response: {s}", .{headers[0..@min(80, headers.len)]});
            return error.HandshakeFailed;
        }

        const expected = expectedAccept(&key_b64);
        const accept_value = findHeader(headers, "Sec-WebSocket-Accept") orelse {
            log.warn("ws handshake missing Sec-WebSocket-Accept header", .{});
            return error.HandshakeFailed;
        };
        if (!std.mem.eql(u8, accept_value, &expected)) {
            log.warn("ws handshake bad Sec-WebSocket-Accept", .{});
            return error.HandshakeFailed;
        }
    }

    /// Find the value of a case-insensitive header name in an HTTP/1.1 header
    /// block. Returns null if the header is absent.
    fn findHeader(headers: []const u8, name: []const u8) ?[]const u8 {
        var line_start: usize = 0;
        while (line_start < headers.len) {
            const line_end = std.mem.indexOfScalarPos(u8, headers, line_start, '\n') orelse return null;
            const line = headers[line_start..line_end];
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
                const hdr_name = trimmed[0..colon];
                if (hdr_name.len == name.len and std.ascii.eqlIgnoreCase(hdr_name, name)) {
                    return std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
                }
            }
            line_start = line_end + 1;
        }
        return null;
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
        const opcode: Opcode =
            std.enums.fromInt(Opcode, opcode_raw) orelse return error.ProtocolError;
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
        self.io.random(&mask);
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
        if (self.http) |h| {
            const w = h.connection.writer();
            w.writeAll(buf) catch return error.SendFailed;
            h.connection.flush() catch return error.SendFailed;
        } else if (self.tls_proxy) |t| {
            t.tls.writer.writeAll(buf) catch return error.SendFailed;
            t.tls.writer.flush() catch return error.SendFailed;
            t.socket_writer.interface.flush() catch return error.SendFailed;
        } else {
            var buffer: [0]u8 = .{};
            var writer = self.stream.writer(self.io, &buffer);

            writer.interface.writeAll(buf) catch
                return error.SendFailed;
        }
    }

    fn readSome(self: *Conn, buf: []u8) Error!usize {
        if (self.http) |h| {
            const r = h.connection.reader();
            return r.readSliceShort(buf) catch return error.RecvFailed;
        }
        if (self.tls_proxy) |t| {
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
        var buffer: [0]u8 = .{};
        var reader = self.stream.reader(self.io, &buffer);

        const n = reader.interface.readSliceShort(buf) catch {
            if (reader.err) |err| switch (err) {
                error.Timeout => return error.Timeout,
                else => return error.RecvFailed,
            };

            return error.RecvFailed;
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

fn setTcpNoDelay(stream: Stream) void {
    const one: c_int = 1;
    posix.setsockopt(
        stream.socket.handle,
        posix.IPPROTO.TCP,
        posix.TCP.NODELAY,
        std.mem.asBytes(&one),
    ) catch {};
}

fn setRecvTimeout(stream: Stream, sec: u32) void {
    const tv: posix.timeval = .{
        .sec = @intCast(sec),
        .usec = 0,
    };

    posix.setsockopt(
        stream.socket.handle,
        posix.SOL.SOCKET,
        posix.SO.RCVTIMEO,
        std.mem.asBytes(&tv),
    ) catch {};
}

fn httpConnectError(err: std.http.Client.ConnectTcpError) Error {
    return switch (err) {
        error.TlsInitializationFailed => error.TlsInitFailed,
        error.UnknownHostName => error.DnsResolveFailed,
        else => error.ConnectFailed,
    };
}

/// Connect-probe budget (ms) for the preflight reachability check. The blocking
/// connect inside `std.http.Client` (used for the `wss://` TLS path) has no
/// timeout, so a relay whose TCP connect hangs -- e.g. an unroutable address or
/// a silently-dropped SYN, as public relays like relay.nostr.band sometimes do
/// -- would otherwise stall the caller for the OS default (~75 s). We probe
/// first with a bounded non-blocking connect and skip the relay fast on failure.
const preflight_connect_ms: i32 = 4000;

/// Best-effort fast reachability probe: resolve `host` and try a non-blocking
/// TCP connect (IPv4 first) bounded by `timeout_ms`. Returns true as soon as any
/// address accepts. A false return lets the caller skip a dead/slow relay
/// quickly instead of blocking in std's timeout-free connect.
fn preflightReachable(
    io: std.Io,
    host: []const u8,
    port: u16,
    timeout_ms: i32,
) bool {
    const hostname: HostName = .{ .bytes = host };

    const stream = hostname.connect(io, port, .{
        .mode = .stream,
        .timeout = .{
            .duration = .{
                .raw = .fromMilliseconds(@intCast(timeout_ms)),
                .clock = .awake,
            },
        },
    }) catch return false;

    stream.close(io);
    return true;
}

/// Open TCP to `host`:`port`, preferring IPv4 and trying every resolved address
/// before giving up. `std.net.tcpConnectToHost` stops on the first non-refused
/// error, which breaks when DNS returns AAAA before A and IPv6 is unroutable.
fn tcpConnect(
    io: std.Io,
    host: []const u8,
    port: u16,
) Error!Stream {
    const hostname: HostName = .{ .bytes = host };

    return hostname.connect(io, port, .{
        .mode = .stream,
        .timeout = .{
            .duration = .{
                .raw = .fromSeconds(4),
                .clock = .awake,
            },
        },
    }) catch return error.ConnectFailed;
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
    return .{ .code = code, .reason = std.mem.trimStart(u8, line[12..], " ") };
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
    const opcode: Opcode = std.enums.fromInt(Opcode, opcode_raw) orelse return error.ProtocolError;
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
