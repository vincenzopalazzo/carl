/// Outbound proxy support: SOCKS5 / SOCKS5h and HTTP CONNECT tunneling.
///
/// Provides a single tunnel layer so outbound TCP (peer connections and HTTP
/// tracker announces) can be routed through a proxy, hiding the real IP from
/// the swarm. UDP paths (DHT, UDP trackers) and the inbound listener are
/// disabled by callers when a proxy is set -- they cannot be carried safely.
///
/// Supported schemes:
///   - socks5   SOCKS5 with local DNS (we resolve, send IPv4 to the proxy)
///   - socks5h  SOCKS5 with remote DNS (proxy resolves the hostname; no leak)
///   - http     HTTP CONNECT tunneling
///
/// Optional username/password auth (SOCKS5 RFC 1929 / HTTP Basic) is parsed
/// from `user:pass@host` in the proxy URL.
///
/// The handshake is synchronous and blocking (bounded by SO_SNDTIMEO /
/// SO_RCVTIMEO), matching the blocking-connect model in peer.zig: by the time
/// `connectThroughProxyAddr` returns, the stream is a transparent tunnel to the
/// target and is ready for the BitTorrent handshake.
const std = @import("std");
const Allocator = std.mem.Allocator;
const tls = std.crypto.tls;

const Net = std.Io.net;
const Stream = Net.Stream;
const IpAddress = Net.IpAddress;

const log = std.log.scoped(.proxy);

pub const ProxyError = error{
    InvalidProxyUrl,
    UnsupportedScheme,
    UnsupportedAddress,
    TlsFailed,
    InvalidUrl,
    DnsResolveFailed,
    SocketFailed,
    ConnectFailed,
    HandshakeFailed,
    AuthenticationFailed,
    InvalidResponse,
    OutOfMemory,
};

pub const Scheme = enum { socks5, socks5h, http };

/// Health classification of a SOCKS proxy, for the daemon's proxy-health probe.
/// Distinguishes the failure modes a misconfigured Tor setup actually hits so
/// the UI/log can say *why* the route isn't working instead of a generic fail.
pub const ProxyState = enum {
    /// Reachable and speaks SOCKS5 (accepted the no-auth method).
    ok,
    /// Nothing is listening on the SOCKS port (connection refused) — e.g. Tor
    /// isn't running.
    not_running,
    /// The connect or the SOCKS5 greeting timed out.
    timeout,
    /// Reachable but rejected us: not SOCKS5, or no acceptable auth method
    /// (`reply` carries the offending byte, e.g. 0xFF = auth required).
    rejected,

    pub fn jsonName(self: ProxyState) []const u8 {
        return @tagName(self);
    }
};

/// Result of `classifySocks5`. `reply` is the SOCKS5 method-selection / version
/// byte when `state == .rejected` and the server spoke at all; null otherwise.
pub const ProxyProbe = struct {
    state: ProxyState,
    reply: ?u8 = null,
};

/// A parsed proxy specification. String fields borrow from the URL passed to
/// `parseUrl` -- that buffer (typically argv) must outlive the Proxy.
pub const Proxy = struct {
    scheme: Scheme,
    host: []const u8,
    port: u16,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Connect + handshake timeout for proxy operations, in seconds.
const proxy_timeout_secs: u32 = 10;
/// Longer timeout for tracker GETs, which traverse the proxy to a remote host.
const http_get_timeout_secs: u32 = 20;
/// Cap on a single proxied HTTP response body (trackers are small).
const max_response_bytes: usize = 4 * 1024 * 1024;

// --- URL parsing ---

/// Parse a proxy URL of the form `scheme://[user:pass@]host:port`.
pub fn parseUrl(url: []const u8) ProxyError!Proxy {
    const sep = "://";
    const sep_idx = std.mem.indexOf(u8, url, sep) orelse return error.InvalidProxyUrl;
    const scheme_str = url[0..sep_idx];
    var rest = url[sep_idx + sep.len ..];

    const scheme: Scheme = if (std.mem.eql(u8, scheme_str, "socks5"))
        .socks5
    else if (std.mem.eql(u8, scheme_str, "socks5h"))
        .socks5h
    else if (std.mem.eql(u8, scheme_str, "http"))
        .http
    else
        return error.UnsupportedScheme;

    // Optional userinfo (user:pass@). Use the last '@' so passwords may contain '@'.
    var username: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| {
        const userinfo = rest[0..at];
        rest = rest[at + 1 ..];
        if (std.mem.indexOfScalar(u8, userinfo, ':')) |colon| {
            username = userinfo[0..colon];
            password = userinfo[colon + 1 ..];
        } else {
            username = userinfo;
        }
    }

    // host:port (strip any trailing path)
    const host_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host_port = rest[0..host_end];
    const colon = std.mem.lastIndexOfScalar(u8, host_port, ':') orelse return error.InvalidProxyUrl;
    const host = host_port[0..colon];
    const port = std.fmt.parseUnsigned(u16, host_port[colon + 1 ..], 10) catch
        return error.InvalidProxyUrl;
    if (host.len == 0) return error.InvalidProxyUrl;

    return .{
        .scheme = scheme,
        .host = host,
        .port = port,
        .username = username,
        .password = password,
    };
}

/// Mask any `user:pass@` userinfo in a proxy URL so it is safe to log or show
/// in the API/UI — SOCKS5 auth credentials must never leak. Returns a slice that
/// is guaranteed credential-free on every path:
///   - no `://` or no userinfo → the input unchanged (already credential-free);
///   - userinfo + room in `out` → the masked `scheme://***@host:port`;
///   - userinfo but `out` too small → the bare `host:port` (still no creds).
/// `out` should be `url.len + 4` bytes to fit the `***@` mask.
pub fn redactUrl(url: []const u8, out: []u8) []const u8 {
    const sep = std.mem.indexOf(u8, url, "://") orelse return url;
    const after = sep + 3;
    // Last '@' matches parseUrl's delimiter choice, so a '@' inside the password
    // doesn't truncate early. (A stray '@' in a credential-free path would only
    // cause harmless over-redaction, never a leak.)
    const rest = url[after..];
    const at_rel = std.mem.lastIndexOfScalar(u8, rest, '@') orelse return url;
    const prefix = url[0..after]; // "scheme://"
    const suffix = rest[at_rel + 1 ..]; // "host:port[/...]"
    const mask = "***@";
    if (out.len < prefix.len + mask.len + suffix.len) return suffix; // credential-free fallback
    @memcpy(out[0..prefix.len], prefix);
    @memcpy(out[prefix.len..][0..mask.len], mask);
    @memcpy(out[prefix.len + mask.len ..][0..suffix.len], suffix);
    return out[0 .. prefix.len + mask.len + suffix.len];
}

// --- Public connect entry points ---

/// Open a TCP tunnel through the proxy to an IPv4 peer address. Returns a
/// connected stream ready for the BitTorrent handshake.
pub fn connectThroughProxyAddr(
    io: std.Io,
    allocator: Allocator,
    proxy: Proxy,
    target: IpAddress,
) ProxyError!Stream {
    const target_ip4 = switch (target) {
        .ip4 => |addr| addr,
        .ip6 => return error.UnsupportedAddress,
    };

    const ip4 = target_ip4.bytes;
    const port = target_ip4.port;

    var stream = try dialProxy(io, allocator, proxy, proxy_timeout_secs);
    errdefer stream.close(io);

    switch (proxy.scheme) {
        .socks5, .socks5h => {
            try socks5Handshake(io, stream, proxy);
            try socks5ConnectIp4(io, stream, ip4, port);
        },
        .http => {
            var host_buf: [16]u8 = undefined;
            const host = std.fmt.bufPrint(&host_buf, "{d}.{d}.{d}.{d}", .{
                ip4[0], ip4[1], ip4[2], ip4[3],
            }) catch return error.HandshakeFailed;
            try httpConnect(io, allocator, stream, proxy, host, port);
        },
    }

    return stream;
}

/// SOCKS5 proxy connect split: TCP connect to the proxy + SOCKS5 auth + send
/// CONNECT request, but DON'T read the reply. The caller polls for readability
/// and then calls `readSocks5ReplyPub`. Lets the Tor circuit-build (1-10s)
/// happen async without blocking the event loop.
pub fn connectThroughProxyAddrStart(
    io: std.Io,
    allocator: Allocator,
    proxy: Proxy,
    target: IpAddress,
) ProxyError!Stream {
    const ip4_addr = switch (target) {
        .ip4 => |addr| addr,
        .ip6 => return error.UnsupportedAddress,
    };

    const ip4 = ip4_addr.bytes;
    const port = ip4_addr.port;

    var stream = try dialProxy(
        io,
        allocator,
        proxy,
        proxy_timeout_secs,
    );
    errdefer stream.close(io);

    switch (proxy.scheme) {
        .socks5, .socks5h => {
            try socks5Handshake(io, stream, proxy);
            const req = buildSocks5ConnectIp4(ip4, port);
            try writeAll(io, stream, &req);
        },
        .http => {
            var host_buf: [16]u8 = undefined;
            const host = std.fmt.bufPrint(&host_buf, "{d}.{d}.{d}.{d}", .{
                ip4[0], ip4[1], ip4[2], ip4[3],
            }) catch return error.HandshakeFailed;
            try httpConnect(io, allocator, stream, proxy, host, port);
        },
    }

    return stream;
}

/// Public wrapper so the async proxy-connect path can read the SOCKS5 CONNECT
/// reply when the socket becomes readable.
pub fn readSocks5ReplyPub(
    io: std.Io,
    stream: Stream,
) ProxyError!void {
    return readSocks5Reply(io, stream);
}

/// Open a TCP tunnel through the proxy to a host:port. With socks5h the
/// hostname is sent to the proxy to resolve (no DNS leak); with socks5 we
/// resolve locally; with http the proxy resolves via CONNECT.
pub fn connectThroughProxyHost(
    io: std.Io,
    allocator: Allocator,
    proxy: Proxy,
    host: []const u8,
    port: u16,
) ProxyError!Stream {
    var stream = try dialProxy(
        io,
        allocator,
        proxy,
        http_get_timeout_secs,
    );
    errdefer stream.close(io);

    switch (proxy.scheme) {
        .socks5 => {
            try socks5Handshake(io, stream, proxy);
            const addr = try resolveIp4(io, host, port);

            const ip4 = switch (addr) {
                .ip4 => |a| a.bytes,
                .ip6 => return error.UnsupportedAddress,
            };
            try socks5ConnectIp4(io, stream, ip4, port);
        },
        .socks5h => {
            try socks5Handshake(io, stream, proxy);
            try socks5ConnectDomain(io, stream, host, port);
        },
        .http => try httpConnect(io, allocator, stream, proxy, host, port),
    }

    return stream;
}

/// Perform an HTTP(S) GET through the proxy and return the response body (owned
/// by the caller). `http://` is tunneled in plaintext; `https://` runs TLS over
/// the proxied stream with certificate verification, so it never leaks via a
/// direct connection.
///
/// We build the request by hand rather than using `std.http.Client`: its proxy
/// support (0.15.2) covers HTTP/HTTPS proxies only, not SOCKS, so routing GETs
/// over our own tunnel keeps a single code path for every proxy scheme.
pub fn httpGet(
    io: std.Io,
    allocator: Allocator,
    proxy: Proxy,
    url: []const u8,
    extra_headers: ?[]const Header,
) ProxyError![]u8 {
    const u = parseHttpUrl(url) orelse return error.InvalidUrl;

    var stream = try connectThroughProxyHost(
        io,
        allocator,
        proxy,
        u.host,
        u.port,
    );
    defer stream.close(io);

    // Build the request by appending directly (tracker paths can be long --
    // info_hash, peer_id, and private-tracker passkeys -- so avoid fixed buffers).
    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(allocator);
    try append(allocator, &req, "GET ");
    // Request target must be origin-form ("/..."). parseHttpUrl may hand back
    // "", "/path[?query]", or "?query"; synthesize the leading slash as needed.
    if (u.path.len == 0 or u.path[0] != '/') try append(allocator, &req, "/");
    try append(allocator, &req, u.path);
    try append(allocator, &req, " HTTP/1.1\r\nHost: ");
    try append(allocator, &req, u.host);
    const default_port: u16 = if (u.is_https) 443 else 80;
    if (u.port != default_port) {
        try append(allocator, &req, ":");
        try appendDecimal(allocator, &req, u.port);
    }
    try append(allocator, &req, "\r\nUser-Agent: carl/0\r\nAccept: */*\r\nConnection: close\r\n");
    if (extra_headers) |hs| for (hs) |h| {
        try append(allocator, &req, h.name);
        try append(allocator, &req, ": ");
        try append(allocator, &req, h.value);
        try append(allocator, &req, "\r\n");
    };
    try append(allocator, &req, "\r\n");

    if (u.is_https) {
        return httpsExchange(io, allocator, stream, u.host, req.items);
    }

    try writeAll(io, stream, req.items);
    return readPlainResponse(allocator, stream);
}

/// Read a plaintext HTTP response to completion and parse it. We sent
/// `Connection: close`, so the server closes at EOF; `responseComplete` lets us
/// stop early once a Content-Length body is fully received.
fn readPlainResponse(allocator: Allocator, stream: Stream) ProxyError![]u8 {
    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(allocator);
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = std.posix.read(
            stream.socket.handle,
            &chunk,
        ) catch break;
        if (n == 0) break;
        resp.appendSlice(allocator, chunk[0..n]) catch return error.OutOfMemory;
        if (resp.items.len > max_response_bytes) break;
        if (responseComplete(resp.items)) break;
    }
    return parseHttpResponse(allocator, resp.items);
}

/// Run an HTTPS exchange over the already-proxied stream: TLS handshake with
/// certificate verification against the system CA bundle, send `request`, then
/// read and parse the response. The proxy only ever sees encrypted bytes.
fn httpsExchange(
    io: std.Io,
    allocator: Allocator,
    stream: Stream,
    host: []const u8,
    request: []const u8,
) ProxyError![]u8 {
    var ca_bundle: std.crypto.Certificate.Bundle = .empty;
    defer ca_bundle.deinit(allocator);

    const now = std.Io.Clock.real.now(io);

    ca_bundle.rescan(allocator, io, now) catch
        return error.TlsFailed;

    var sock_read_buf: [tls.max_ciphertext_record_len]u8 = undefined;
    var sock_write_buf: [tls.max_ciphertext_record_len]u8 = undefined;
    var sr = stream.reader(io, &sock_read_buf);
    var sw = stream.writer(io, &sock_write_buf);

    var tls_read_buf: [tls.max_ciphertext_record_len]u8 = undefined;
    var tls_write_buf: [tls.max_ciphertext_record_len]u8 = undefined;

    var ca_lock: std.Io.RwLock = .init;

    var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
    io.random(&entropy);

    var client = tls.Client.init(&sr.interface, &sw.interface, .{
        .host = .{ .explicit = host },
        .ca = .{
            .bundle = .{
                .gpa = allocator,
                .io = io,
                .lock = &ca_lock,
                .bundle = &ca_bundle,
            },
        },
        .write_buffer = &tls_write_buf,
        .read_buffer = &tls_read_buf,
        .entropy = &entropy,
        .realtime_now = now,
    }) catch return error.TlsFailed;

    // Both layers must flush: the TLS writer stages a record, the socket writer
    // pushes it onto the wire.
    client.writer.writeAll(request) catch return error.TlsFailed;
    client.writer.flush() catch return error.TlsFailed;
    sw.interface.flush() catch return error.TlsFailed;

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(allocator);
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = client.reader.readSliceShort(&chunk) catch break;
        if (n == 0) break;
        resp.appendSlice(allocator, chunk[0..n]) catch return error.OutOfMemory;
        if (resp.items.len > max_response_bytes) break;
        if (responseComplete(resp.items)) break;
    }
    return parseHttpResponse(allocator, resp.items);
}

/// True if `buf` already holds a complete HTTP response, so the read loop can
/// stop instead of waiting for the connection to close. Only the Content-Length
/// case is treated as complete -- chunked / unframed responses read to EOF
/// (safe, since we send `Connection: close`).
fn responseComplete(buf: []const u8) bool {
    const sep = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return false;
    const head = buf[0..sep];
    const body = buf[sep + 4 ..];
    if (headerHasToken(head, "transfer-encoding", "chunked")) return false;
    if (contentLength(head)) |len| return body.len >= len;
    return false;
}

/// Parse the `Content-Length` header value, if present.
fn contentLength(head: []const u8) ?usize {
    var lines = std.mem.tokenizeSequence(u8, head, "\r\n");
    _ = lines.next(); // status line
    while (lines.next()) |line| {
        const c = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..c], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            return std.fmt.parseUnsigned(usize, std.mem.trim(u8, line[c + 1 ..], " \t"), 10) catch null;
        }
    }
    return null;
}

// --- Proxy socket setup ---

fn dialProxy(
    io: std.Io,
    allocator: Allocator,
    proxy: Proxy,
    timeout_secs: u32,
) ProxyError!Stream {
    _ = allocator;

    const addr = try resolveIp4(
        io,
        proxy.host,
        proxy.port,
    );

    var stream = try connectIp4Bounded(
        addr,
        timeout_secs,
    );

    errdefer stream.close(io);

    const sock = stream.socket.handle;

    // Keep Carl's existing read/write socket timeouts.
    const tv = std.posix.timeval{
        .sec = @intCast(timeout_secs),
        .usec = 0,
    };

    std.posix.setsockopt(
        sock,
        std.posix.SOL.SOCKET,
        std.posix.SO.SNDTIMEO,
        std.mem.asBytes(&tv),
    ) catch {};

    std.posix.setsockopt(
        sock,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&tv),
    ) catch {};

    return stream;
}
fn resolveIp4(
    io: std.Io,
    host: []const u8,
    port: u16,
) ProxyError!IpAddress {
    const host_name = Net.HostName.init(host) catch
        return error.DnsResolveFailed;

    var canonical_name_buffer: [Net.HostName.max_len]u8 = undefined;
    var lookup_buffer: [16]Net.HostName.LookupResult = undefined;
    var lookup_queue: std.Io.Queue(Net.HostName.LookupResult) =
        .init(&lookup_buffer);

    host_name.lookup(io, &lookup_queue, .{
        .port = port,
        .canonical_name_buffer = &canonical_name_buffer,
    }) catch return error.DnsResolveFailed;

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

    return error.DnsResolveFailed;
}

fn connectIp4Bounded(
    addr: IpAddress,
    timeout_secs: u32,
) ProxyError!Stream {
    const ip4 = switch (addr) {
        .ip4 => |a| a,
        .ip6 => return error.ConnectFailed,
    };

    const timeout_ms: i32 =
        if (timeout_secs > 600)
            600_000
        else
            @intCast(timeout_secs * 1000);

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

/// Health-check a SOCKS5 proxy using only the method-negotiation greeting — we
/// never send a CONNECT, so the proxy is not asked to open any upstream
/// connection and this probe leaks no traffic from the privacy tool. The connect
/// and greeting phases are bounded by `timeout_secs`; the initial DNS resolve is
/// not (typical SOCKS hosts are IP literals like 127.0.0.1, so no DNS happens).
/// Pure classification: never returns an error, it maps every failure into a
/// `ProxyState`. (Full CONNECT reply codes only arise on real peer dials —
/// surfacing those per-transfer is a documented follow-up.)
pub fn classifySocks5(
    io: std.Io,
    allocator: Allocator,
    proxy: Proxy,
    timeout_secs: u32,
) ProxyProbe {
    _ = allocator;

    const addr = resolveIp4(io, proxy.host, proxy.port) catch
        return .{ .state = .not_running };

    const timeout_ms: i32 =
        if (timeout_secs > 600) 600_000 else @intCast(timeout_secs * 1000);

    const sock = std.c.socket(
        std.posix.AF.INET,
        std.posix.SOCK.STREAM,
        std.posix.IPPROTO.TCP,
    );

    if (sock < 0)
        return .{ .state = .timeout };

    defer _ = std.c.close(sock);

    // macOS does not accept SOCK.CLOEXEC in the socket type here.
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
        return .{ .state = .timeout };

    var o: std.c.O = @bitCast(@as(u32, @intCast(flags)));
    o.NONBLOCK = true;

    _ = std.c.fcntl(
        sock,
        std.c.F.SETFL,
        @as(c_int, @bitCast(o)),
    );

    const ip4 = switch (addr) {
        .ip4 => |a| a,
        .ip6 => return .{ .state = .not_running },
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
            ) catch return .{ .state = .timeout };

            if (ready == 0)
                return .{ .state = .timeout };

            var socket_error: c_int = 0;
            var socket_error_len: std.c.socklen_t = @sizeOf(c_int);

            if (std.c.getsockopt(
                sock,
                std.c.SOL.SOCKET,
                std.c.SO.ERROR,
                &socket_error,
                &socket_error_len,
            ) != 0) {
                return .{ .state = .timeout };
            }

            if (socket_error != 0) {
                if (socket_error == @intFromEnum(std.c.E.CONNREFUSED))
                    return .{ .state = .not_running };

                return .{ .state = .timeout };
            }
        },
        .CONNREFUSED => return .{ .state = .not_running },
        else => return .{ .state = .timeout },
    };

    // Connected. Restore blocking mode.
    o.NONBLOCK = false;

    _ = std.c.fcntl(
        sock,
        std.c.F.SETFL,
        @as(c_int, @bitCast(o)),
    );

    // Bound the SOCKS greeting reads/writes too.
    const tv = std.c.timeval{
        .sec = @intCast(timeout_secs),
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

    writeAll(
        io,
        stream,
        &[_]u8{ 0x05, 0x01, 0x00 },
    ) catch return .{ .state = .timeout };

    var reply: [2]u8 = undefined;

    readN(
        io,
        stream,
        &reply,
    ) catch return .{ .state = .timeout };

    if (reply[0] != 0x05)
        return .{ .state = .rejected, .reply = reply[0] };

    if (reply[1] == 0x00)
        return .{ .state = .ok };

    return .{ .state = .rejected, .reply = reply[1] };
}

// --- Blocking stream I/O helpers ---

fn writeAll(
    io: std.Io,
    stream: Stream,
    bytes: []const u8,
) ProxyError!void {
    var buffer: [0]u8 = .{};
    var writer = stream.writer(io, &buffer);

    writer.interface.writeAll(bytes) catch
        return error.HandshakeFailed;
}

fn readN(
    io: std.Io,
    stream: Stream,
    buf: []u8,
) ProxyError!void {
    var buffer: [0]u8 = .{};
    var reader = stream.reader(io, &buffer);

    reader.interface.readSliceAll(buf) catch
        return error.HandshakeFailed;
}

// --- SOCKS5 (RFC 1928) + user/pass auth (RFC 1929) ---

fn socks5Handshake(
    io: std.Io,
    stream: Stream,
    proxy: Proxy,
) ProxyError!void {
    const have_auth = proxy.username != null;

    var greeting: [4]u8 = undefined;
    const greeting_len = buildSocks5Greeting(&greeting, have_auth);
    try writeAll(io, stream, greeting[0..greeting_len]);

    var sel: [2]u8 = undefined;
    try readN(io, stream, &sel);
    if (sel[0] != 0x05) return error.InvalidResponse;
    switch (sel[1]) {
        // No-auth accepted. We allow this even when credentials were supplied:
        // the proxy doesn't require them, and withholding creds from a proxy
        // that didn't ask avoids leaking them to a misconfigured endpoint.
        0x00 => {},
        0x02 => try socks5UserPassAuth(io, stream, proxy),
        else => return error.AuthenticationFailed, // includes 0xFF (no acceptable method)
    }
}

/// Build the SOCKS5 greeting. Offers no-auth, plus user/pass when `have_auth`.
/// Returns the number of bytes written into `out` (3 or 4).
fn buildSocks5Greeting(out: *[4]u8, have_auth: bool) usize {
    out[0] = 0x05; // version
    if (have_auth) {
        out[1] = 0x02; // 2 methods
        out[2] = 0x00; // no auth
        out[3] = 0x02; // user/pass
        return 4;
    }
    out[1] = 0x01; // 1 method
    out[2] = 0x00; // no auth
    return 3;
}

fn socks5UserPassAuth(
    io: std.Io,
    stream: Stream,
    proxy: Proxy,
) ProxyError!void {
    const user = proxy.username orelse return error.AuthenticationFailed;
    const pass = proxy.password orelse "";
    if (user.len > 255 or pass.len > 255) return error.AuthenticationFailed;

    var buf: [513]u8 = undefined; // 1 + 1 + 255 + 1 + 255
    var i: usize = 0;
    buf[i] = 0x01; // sub-negotiation version
    i += 1;
    buf[i] = @intCast(user.len);
    i += 1;
    @memcpy(buf[i .. i + user.len], user);
    i += user.len;
    buf[i] = @intCast(pass.len);
    i += 1;
    @memcpy(buf[i .. i + pass.len], pass);
    i += pass.len;
    try writeAll(io, stream, buf[0..i]);

    var reply: [2]u8 = undefined;
    try readN(io, stream, &reply);
    if (reply[1] != 0x00) return error.AuthenticationFailed;
}

fn socks5ConnectIp4(
    io: std.Io,
    stream: Stream,
    ip4: [4]u8,
    port: u16,
) ProxyError!void {
    const req = buildSocks5ConnectIp4(ip4, port);
    try writeAll(io, stream, &req);
    try readSocks5Reply(io, stream);
}

/// Build a SOCKS5 CONNECT request for an IPv4 destination (10 bytes).
fn buildSocks5ConnectIp4(ip4: [4]u8, port: u16) [10]u8 {
    var req: [10]u8 = undefined;
    req[0] = 0x05; // version
    req[1] = 0x01; // CONNECT
    req[2] = 0x00; // reserved
    req[3] = 0x01; // ATYP = IPv4
    @memcpy(req[4..8], &ip4);
    req[8] = @intCast((port >> 8) & 0xff);
    req[9] = @intCast(port & 0xff);
    return req;
}

fn socks5ConnectDomain(
    io: std.Io,
    stream: Stream,
    host: []const u8,
    port: u16,
) ProxyError!void {
    if (host.len == 0 or host.len > 255) return error.InvalidProxyUrl;
    var req: [262]u8 = undefined; // 4 + 1 + 255 + 2
    req[0] = 0x05; // version
    req[1] = 0x01; // CONNECT
    req[2] = 0x00; // reserved
    req[3] = 0x03; // ATYP = domain
    req[4] = @intCast(host.len);
    @memcpy(req[5 .. 5 + host.len], host);
    req[5 + host.len] = @intCast((port >> 8) & 0xff);
    req[6 + host.len] = @intCast(port & 0xff);
    try writeAll(io, stream, req[0 .. 7 + host.len]);
    try readSocks5Reply(io, stream);
}

/// Read and validate a SOCKS5 CONNECT reply, discarding the variable-length
/// BND.ADDR / BND.PORT trailer.
fn readSocks5Reply(
    io: std.Io,
    stream: Stream,
) ProxyError!void {
    var head: [4]u8 = undefined;
    try readN(io, stream, &head);
    if (head[0] != 0x05) return error.InvalidResponse;
    if (head[1] != 0x00) {
        // REP != succeeded: log the reason (0x05 refused, 0x04 host unreachable,
        // 0x02 not allowed by ruleset, ...) so proxy failures are debuggable.
        log.debug("SOCKS5 CONNECT rejected: REP=0x{x:0>2}", .{head[1]});
        return error.HandshakeFailed;
    }

    // BND.ADDR length depends on ATYP, then 2 bytes of BND.PORT.
    var trailer: usize = switch (head[3]) {
        0x01 => 4, // IPv4
        0x04 => 16, // IPv6
        0x03 => blk: {
            var l: [1]u8 = undefined;
            try readN(io, stream, &l);
            break :blk l[0];
        },
        else => return error.InvalidResponse,
    };
    trailer += 2; // BND.PORT

    var scratch: [256]u8 = undefined;
    while (trailer > 0) {
        const take = @min(trailer, scratch.len);
        try readN(io, stream, scratch[0..take]);
        trailer -= take;
    }
}

// --- HTTP CONNECT ---

fn httpConnect(
    io: std.Io,
    allocator: Allocator,
    stream: Stream,
    proxy: Proxy,
    host: []const u8,
    port: u16,
) ProxyError!void {
    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(allocator);

    try append(allocator, &req, "CONNECT ");
    try append(allocator, &req, host);
    try append(allocator, &req, ":");
    try appendDecimal(allocator, &req, port);
    try append(allocator, &req, " HTTP/1.1\r\nHost: ");
    try append(allocator, &req, host);
    try append(allocator, &req, ":");
    try appendDecimal(allocator, &req, port);
    try append(allocator, &req, "\r\n");

    if (proxy.username) |user| {
        try appendBasicProxyAuth(allocator, &req, user, proxy.password orelse "");
    }
    try append(allocator, &req, "\r\n");

    try writeAll(io, stream, req.items);
    try readHttpConnectStatus(io, stream);
}

/// Append a byte slice to `req`, mapping allocation failure to ProxyError.
fn append(allocator: Allocator, req: *std.ArrayList(u8), bytes: []const u8) ProxyError!void {
    req.appendSlice(allocator, bytes) catch return error.OutOfMemory;
}

/// Append the decimal text of a u16 to `req`.
fn appendDecimal(allocator: Allocator, req: *std.ArrayList(u8), n: u16) ProxyError!void {
    var buf: [8]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable; // u16 fits in 8 digits
    req.appendSlice(allocator, s) catch return error.OutOfMemory;
}

fn appendBasicProxyAuth(allocator: Allocator, req: *std.ArrayList(u8), user: []const u8, pass: []const u8) ProxyError!void {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);
    raw.appendSlice(allocator, user) catch return error.OutOfMemory;
    raw.append(allocator, ':') catch return error.OutOfMemory;
    raw.appendSlice(allocator, pass) catch return error.OutOfMemory;

    const enc = std.base64.standard.Encoder;
    const b64 = allocator.alloc(u8, enc.calcSize(raw.items.len)) catch return error.OutOfMemory;
    defer allocator.free(b64);
    _ = enc.encode(b64, raw.items);

    try append(allocator, req, "Proxy-Authorization: Basic ");
    try append(allocator, req, b64);
    try append(allocator, req, "\r\n");
}

/// Read the HTTP CONNECT response headers and require a 2xx status.
fn readHttpConnectStatus(
    io: std.Io,
    stream: Stream,
) ProxyError!void {
    var read_buffer: [0]u8 = .{};
    var reader = stream.reader(io, &read_buffer);

    var buf: [1024]u8 = undefined;
    var len: usize = 0;

    while (len < buf.len) {
        reader.interface.readSliceAll(buf[len .. len + 1]) catch
            return error.HandshakeFailed;

        len += 1;

        if (len >= 4 and
            std.mem.eql(u8, buf[len - 4 .. len], "\r\n\r\n"))
        {
            break;
        }
    } else {
        return error.InvalidResponse;
    }

    const status = parseStatusCode(buf[0..len]) orelse
        return error.InvalidResponse;

    if (status < 200 or status >= 300)
        return error.HandshakeFailed;
}

// --- HTTP response parsing (for httpGet) ---

const HttpUrl = struct {
    is_https: bool,
    host: []const u8,
    port: u16,
    path: []const u8,
};

fn parseHttpUrl(url: []const u8) ?HttpUrl {
    var is_https = false;
    var rest: []const u8 = undefined;
    if (std.mem.startsWith(u8, url, "http://")) {
        rest = url[7..];
    } else if (std.mem.startsWith(u8, url, "https://")) {
        is_https = true;
        rest = url[8..];
    } else return null;

    // Authority ends at the first '/' or '?'. A query-only URL (no path),
    // e.g. http://tracker/?-less host + "?passkey=...", must keep its query in
    // the request target rather than folding it into the host.
    const slash = std.mem.indexOfScalar(u8, rest, '/');
    const quest = std.mem.indexOfScalar(u8, rest, '?');
    const auth_end = if (slash != null and quest != null)
        @min(slash.?, quest.?)
    else
        slash orelse quest orelse rest.len;
    const authority = rest[0..auth_end];
    const path = rest[auth_end..]; // "", "/path[?query]", or "?query"

    var host = authority;
    var port: u16 = if (is_https) 443 else 80;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |c| {
        host = authority[0..c];
        port = std.fmt.parseUnsigned(u16, authority[c + 1 ..], 10) catch return null;
    }
    if (host.len == 0) return null;

    return .{ .is_https = is_https, .host = host, .port = port, .path = path };
}

/// Split an HTTP response into status + headers + body, validate a 2xx status,
/// and return the (de-chunked) body as an owned slice.
fn parseHttpResponse(allocator: Allocator, raw: []const u8) ProxyError![]u8 {
    const sep = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.InvalidResponse;
    const head = raw[0..sep];
    const body = raw[sep + 4 ..];

    const status = parseStatusCode(head) orelse return error.InvalidResponse;
    if (status < 200 or status >= 300) return error.InvalidResponse;

    if (headerHasToken(head, "transfer-encoding", "chunked")) {
        return dechunk(allocator, body);
    }
    return allocator.dupe(u8, body) catch error.OutOfMemory;
}

/// Parse the numeric status code from an HTTP status line ("HTTP/1.1 200 OK").
fn parseStatusCode(head: []const u8) ?u16 {
    const line_end = std.mem.indexOf(u8, head, "\r\n") orelse head.len;
    const status_line = head[0..line_end];
    var it = std.mem.tokenizeScalar(u8, status_line, ' ');
    _ = it.next() orelse return null; // "HTTP/1.x"
    const code_str = it.next() orelse return null;
    return std.fmt.parseUnsigned(u16, code_str, 10) catch null;
}

/// Case-insensitive check that header `name` exists and its value contains `token`.
fn headerHasToken(head: []const u8, name: []const u8, token: []const u8) bool {
    var lines = std.mem.tokenizeSequence(u8, head, "\r\n");
    _ = lines.next(); // skip status line
    while (lines.next()) |line| {
        const c = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const hname = std.mem.trim(u8, line[0..c], " \t");
        if (!std.ascii.eqlIgnoreCase(hname, name)) continue;
        if (std.ascii.indexOfIgnoreCase(line[c + 1 ..], token) != null) return true;
    }
    return false;
}

/// Decode HTTP/1.1 chunked transfer encoding into a flat owned buffer.
fn dechunk(allocator: Allocator, body: []const u8) ProxyError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var rest = body;
    while (true) {
        const nl = std.mem.indexOf(u8, rest, "\r\n") orelse break;
        const size_field = rest[0..nl];
        const semi = std.mem.indexOfScalar(u8, size_field, ';') orelse size_field.len;
        const size = std.fmt.parseUnsigned(usize, std.mem.trim(u8, size_field[0..semi], " \t"), 16) catch break;
        if (size == 0) break; // last chunk
        const data_start = nl + 2;
        if (data_start + size > rest.len) break; // truncated
        out.appendSlice(allocator, rest[data_start .. data_start + size]) catch return error.OutOfMemory;
        rest = rest[data_start + size ..];
        if (std.mem.startsWith(u8, rest, "\r\n")) rest = rest[2..];
    }

    return out.toOwnedSlice(allocator) catch error.OutOfMemory;
}

// --- Tests (no network) ---

test "parseUrl socks5h with auth" {
    const p = try parseUrl("socks5h://alice:s3cret@127.0.0.1:1080");
    try std.testing.expectEqual(Scheme.socks5h, p.scheme);
    try std.testing.expectEqualStrings("127.0.0.1", p.host);
    try std.testing.expectEqual(@as(u16, 1080), p.port);
    try std.testing.expectEqualStrings("alice", p.username.?);
    try std.testing.expectEqualStrings("s3cret", p.password.?);
}

test "parseUrl socks5 without auth" {
    const p = try parseUrl("socks5://10.0.0.1:9050");
    try std.testing.expectEqual(Scheme.socks5, p.scheme);
    try std.testing.expectEqualStrings("10.0.0.1", p.host);
    try std.testing.expectEqual(@as(u16, 9050), p.port);
    try std.testing.expect(p.username == null);
    try std.testing.expect(p.password == null);
}

test "parseUrl http proxy" {
    const p = try parseUrl("http://proxy.example.com:8080");
    try std.testing.expectEqual(Scheme.http, p.scheme);
    try std.testing.expectEqualStrings("proxy.example.com", p.host);
    try std.testing.expectEqual(@as(u16, 8080), p.port);
}

test "parseUrl username only" {
    const p = try parseUrl("socks5h://justuser@host:1080");
    try std.testing.expectEqualStrings("justuser", p.username.?);
    try std.testing.expect(p.password == null);
}

test "parseUrl rejects bad input" {
    try std.testing.expectError(error.InvalidProxyUrl, parseUrl("no-scheme-sep"));
    try std.testing.expectError(error.UnsupportedScheme, parseUrl("ftp://host:1"));
    try std.testing.expectError(error.InvalidProxyUrl, parseUrl("socks5://hostnoport"));
    try std.testing.expectError(error.UnsupportedScheme, parseUrl("socks4://host:1080"));
}

test "buildSocks5Greeting" {
    var buf: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), buildSocks5Greeting(&buf, false));
    try std.testing.expectEqualSlices(u8, &.{ 0x05, 0x01, 0x00 }, buf[0..3]);
    try std.testing.expectEqual(@as(usize, 4), buildSocks5Greeting(&buf, true));
    try std.testing.expectEqualSlices(u8, &.{ 0x05, 0x02, 0x00, 0x02 }, buf[0..4]);
}

test "buildSocks5ConnectIp4" {
    const req = buildSocks5ConnectIp4(.{ 1, 2, 3, 4 }, 6881);
    try std.testing.expectEqualSlices(u8, &.{
        0x05, 0x01, 0x00, 0x01, // ver, connect, rsv, atyp=ipv4
        1, 2, 3, 4, // address
        0x1a, 0xe1, // port 6881 big-endian
    }, &req);
}

test "parseHttpUrl http with path and query" {
    const u = parseHttpUrl("http://tracker.example.com/announce?info_hash=x").?;
    try std.testing.expect(!u.is_https);
    try std.testing.expectEqualStrings("tracker.example.com", u.host);
    try std.testing.expectEqual(@as(u16, 80), u.port);
    try std.testing.expectEqualStrings("/announce?info_hash=x", u.path);
}

test "parseHttpUrl with explicit port" {
    const u = parseHttpUrl("http://10.0.0.5:6969/announce").?;
    try std.testing.expectEqualStrings("10.0.0.5", u.host);
    try std.testing.expectEqual(@as(u16, 6969), u.port);
    try std.testing.expectEqualStrings("/announce", u.path);
}

test "parseHttpUrl https flagged" {
    const u = parseHttpUrl("https://secure.tracker/announce").?;
    try std.testing.expect(u.is_https);
    try std.testing.expectEqual(@as(u16, 443), u.port);
}

test "parseHttpUrl query-only authority keeps query out of host" {
    // No '/' before the query (bare-host announce URL + appended params).
    const u = parseHttpUrl("http://tracker.example.com?passkey=abc&info_hash=x").?;
    try std.testing.expectEqualStrings("tracker.example.com", u.host);
    try std.testing.expectEqual(@as(u16, 80), u.port);
    try std.testing.expectEqualStrings("?passkey=abc&info_hash=x", u.path);
}

test "parseHttpUrl bare host has empty path" {
    const u = parseHttpUrl("http://tracker.example.com:6969").?;
    try std.testing.expectEqualStrings("tracker.example.com", u.host);
    try std.testing.expectEqual(@as(u16, 6969), u.port);
    try std.testing.expectEqualStrings("", u.path);
}

test "parseHttpResponse plain body" {
    const body = try parseHttpResponse(std.testing.allocator, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nd1:xe");
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("d1:xe", body);
}

test "parseHttpResponse rejects non-2xx" {
    try std.testing.expectError(
        error.InvalidResponse,
        parseHttpResponse(std.testing.allocator, "HTTP/1.1 404 Not Found\r\n\r\nnope"),
    );
}

test "parseHttpResponse dechunks" {
    const raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n4\r\n you\r\n0\r\n\r\n";
    const body = try parseHttpResponse(std.testing.allocator, raw);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("hello you", body);
}

test "headerHasToken case-insensitive" {
    const head = "HTTP/1.1 200 OK\r\nTransfer-Encoding: Chunked\r\nContent-Type: text/plain";
    try std.testing.expect(headerHasToken(head, "transfer-encoding", "chunked"));
    try std.testing.expect(!headerHasToken(head, "content-length", "5"));
}

test "contentLength parses header" {
    try std.testing.expectEqual(@as(?usize, 42), contentLength("HTTP/1.1 200 OK\r\nContent-Length: 42\r\nX: y"));
    try std.testing.expectEqual(@as(?usize, null), contentLength("HTTP/1.1 200 OK\r\nX: y"));
}

test "responseComplete stops on full Content-Length body" {
    try std.testing.expect(responseComplete("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"));
    try std.testing.expect(!responseComplete("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel")); // body short
    try std.testing.expect(!responseComplete("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n")); // no header terminator
    // chunked is read to EOF, not treated as complete by this check
    try std.testing.expect(!responseComplete("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"));
}

// --- classifySocks5 against a mock SOCKS5 endpoint ---

const MockSocks = struct {
    server: *std.Io.net.Server,
    stop: std.atomic.Value(bool),
    reply: [2]u8,
};

fn mockSocksRun(ctx: *MockSocks) void {
    var pfd = [_]std.posix.pollfd{.{
        .fd = ctx.server.socket.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};

    while (!ctx.stop.load(.acquire)) {
        const ready = std.posix.poll(&pfd, 200) catch 0;
        if (ready == 0) continue;

        const conn = ctx.server.accept(std.testing.io) catch continue;
        defer conn.close(std.testing.io);

        var greeting: [3]u8 = undefined;
        var read_buffer: [0]u8 = .{};
        var reader = conn.reader(std.testing.io, &read_buffer);

        var got: usize = 0;
        while (got < greeting.len) {
            const n = reader.interface.readSliceShort(greeting[got..]) catch break;
            if (n == 0) break;
            got += n;
        }

        var write_buffer: [0]u8 = .{};
        var writer = conn.writer(std.testing.io, &write_buffer);
        writer.interface.writeAll(&ctx.reply) catch break;
    }
}

fn startMockSocks(
    server: *std.Io.net.Server,
    reply: [2]u8,
) !struct { ctx: *MockSocks, thread: std.Thread } {
    const ctx = try std.testing.allocator.create(MockSocks);
    ctx.* = .{
        .server = server,
        .stop = std.atomic.Value(bool).init(false),
        .reply = reply,
    };
    const thread = try std.Thread.spawn(.{}, mockSocksRun, .{ctx});
    return .{ .ctx = ctx, .thread = thread };
}

test "classifySocks5: connection refused => not_running" {
    const a = std.testing.allocator;
    // Bind to grab a free port, then close it so connects are refused.
    const addr: std.Io.net.IpAddress = .{
        .ip4 = .loopback(0),
    };

    var server = try addr.listen(
        std.testing.io,
        .{ .reuse_address = true },
    );

    const port = server.socket.address.getPort();
    server.deinit(std.testing.io);

    const probe = classifySocks5(std.testing.io, a, .{ .scheme = .socks5, .host = "127.0.0.1", .port = port }, 2);
    try std.testing.expectEqual(ProxyState.not_running, probe.state);
}

test "classifySocks5: no-auth accepted => ok" {
    const a = std.testing.allocator;
    const addr: std.Io.net.IpAddress = .{
        .ip4 = .loopback(0),
    };

    var server = try addr.listen(
        std.testing.io,
        .{ .reuse_address = true },
    );

    const port = server.socket.address.getPort();
    const mock = try startMockSocks(&server, .{ 0x05, 0x00 });
    defer {
        mock.ctx.stop.store(true, .release);
        mock.thread.join();
        server.deinit(std.testing.io);
        a.destroy(mock.ctx);
    }

    const probe = classifySocks5(std.testing.io, a, .{ .scheme = .socks5, .host = "127.0.0.1", .port = port }, 2);
    try std.testing.expectEqual(ProxyState.ok, probe.state);
}

test "classifySocks5: no acceptable method => rejected with reply byte" {
    const a = std.testing.allocator;
    const addr: std.Io.net.IpAddress = .{
        .ip4 = .loopback(0),
    };

    var server = try addr.listen(
        std.testing.io,
        .{ .reuse_address = true },
    );

    const port = server.socket.address.getPort();
    const mock = try startMockSocks(&server, .{ 0x05, 0xFF });
    defer {
        mock.ctx.stop.store(true, .release);
        mock.thread.join();
        server.deinit(std.testing.io);
        a.destroy(mock.ctx);
    }

    const probe = classifySocks5(std.testing.io, a, .{ .scheme = .socks5, .host = "127.0.0.1", .port = port }, 2);
    try std.testing.expectEqual(ProxyState.rejected, probe.state);
    try std.testing.expectEqual(@as(?u8, 0xFF), probe.reply);
}

test "classifySocks5: non-SOCKS5 version => rejected" {
    const a = std.testing.allocator;
    const addr: std.Io.net.IpAddress = .{
        .ip4 = .loopback(0),
    };

    var server = try addr.listen(
        std.testing.io,
        .{ .reuse_address = true },
    );

    const port = server.socket.address.getPort();
    const mock = try startMockSocks(&server, .{ 0x04, 0x00 }); // SOCKS4-ish version byte
    defer {
        mock.ctx.stop.store(true, .release);
        mock.thread.join();
        server.deinit(std.testing.io);
        a.destroy(mock.ctx);
    }

    const probe = classifySocks5(std.testing.io, a, .{ .scheme = .socks5, .host = "127.0.0.1", .port = port }, 2);
    try std.testing.expectEqual(ProxyState.rejected, probe.state);
    try std.testing.expectEqual(@as(?u8, 0x04), probe.reply);
}

test "redactUrl masks SOCKS credentials" {
    var buf: [128]u8 = undefined;
    // With userinfo: password is masked.
    try std.testing.expectEqualStrings(
        "socks5h://***@127.0.0.1:9050",
        redactUrl("socks5h://user:pass@127.0.0.1:9050", &buf),
    );
    // user-only (no password) is still masked.
    try std.testing.expectEqualStrings(
        "socks5://***@host:1080",
        redactUrl("socks5://bob@host:1080", &buf),
    );
    // No userinfo: returned unchanged (no copy needed).
    try std.testing.expectEqualStrings(
        "socks5h://127.0.0.1:9050",
        redactUrl("socks5h://127.0.0.1:9050", &buf),
    );
    // '@' inside the password doesn't truncate early (last '@' is the delimiter).
    try std.testing.expectEqualStrings(
        "socks5://***@host:1080",
        redactUrl("socks5://u:p@ss@host:1080", &buf),
    );
    // Buffer too small for the masked form falls back to the bare host:port —
    // still credential-free (never the raw user:pass).
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqualStrings(
        "host:1080",
        redactUrl("socks5://user:pass@host:1080", &tiny),
    );
}
