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

// --- Public connect entry points ---

/// Open a TCP tunnel through the proxy to an IPv4 peer address. Returns a
/// connected stream ready for the BitTorrent handshake.
pub fn connectThroughProxyAddr(allocator: Allocator, proxy: Proxy, target: std.net.Address) ProxyError!std.net.Stream {
    if (target.any.family != std.posix.AF.INET) return error.UnsupportedAddress;
    const ip4: [4]u8 = @bitCast(target.in.sa.addr);
    const port = target.getPort();

    var stream = try dialProxy(allocator, proxy, proxy_timeout_secs);
    errdefer stream.close();

    switch (proxy.scheme) {
        .socks5, .socks5h => {
            try socks5Handshake(stream, proxy);
            try socks5ConnectIp4(stream, ip4, port);
        },
        .http => {
            var host_buf: [16]u8 = undefined;
            const host = std.fmt.bufPrint(&host_buf, "{d}.{d}.{d}.{d}", .{
                ip4[0], ip4[1], ip4[2], ip4[3],
            }) catch return error.HandshakeFailed;
            try httpConnect(allocator, stream, proxy, host, port);
        },
    }

    return stream;
}

/// Open a TCP tunnel through the proxy to a host:port. With socks5h the
/// hostname is sent to the proxy to resolve (no DNS leak); with socks5 we
/// resolve locally; with http the proxy resolves via CONNECT.
pub fn connectThroughProxyHost(allocator: Allocator, proxy: Proxy, host: []const u8, port: u16) ProxyError!std.net.Stream {
    var stream = try dialProxy(allocator, proxy, http_get_timeout_secs);
    errdefer stream.close();

    switch (proxy.scheme) {
        .socks5 => {
            try socks5Handshake(stream, proxy);
            const addr = try resolveIp4(allocator, host, port);
            const ip4: [4]u8 = @bitCast(addr.in.sa.addr);
            try socks5ConnectIp4(stream, ip4, port);
        },
        .socks5h => {
            try socks5Handshake(stream, proxy);
            try socks5ConnectDomain(stream, host, port);
        },
        .http => try httpConnect(allocator, stream, proxy, host, port),
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
pub fn httpGet(allocator: Allocator, proxy: Proxy, url: []const u8, extra_headers: ?[]const Header) ProxyError![]u8 {
    const u = parseHttpUrl(url) orelse return error.InvalidUrl;

    var stream = try connectThroughProxyHost(allocator, proxy, u.host, u.port);
    defer stream.close();

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

    if (u.is_https) return httpsExchange(allocator, stream, u.host, req.items);

    try writeAll(stream, req.items);
    return readPlainResponse(allocator, stream);
}

/// Read a plaintext HTTP response to completion and parse it. We sent
/// `Connection: close`, so the server closes at EOF; `responseComplete` lets us
/// stop early once a Content-Length body is fully received.
fn readPlainResponse(allocator: Allocator, stream: std.net.Stream) ProxyError![]u8 {
    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(allocator);
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = stream.read(&chunk) catch break;
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
fn httpsExchange(allocator: Allocator, stream: std.net.Stream, host: []const u8, request: []const u8) ProxyError![]u8 {
    var ca_bundle: std.crypto.Certificate.Bundle = .{};
    ca_bundle.rescan(allocator) catch return error.TlsFailed;
    defer ca_bundle.deinit(allocator);

    var sock_read_buf: [tls.max_ciphertext_record_len]u8 = undefined;
    var sock_write_buf: [tls.max_ciphertext_record_len]u8 = undefined;
    var sr = stream.reader(&sock_read_buf);
    var sw = stream.writer(&sock_write_buf);

    var tls_read_buf: [tls.max_ciphertext_record_len]u8 = undefined;
    var tls_write_buf: [tls.max_ciphertext_record_len]u8 = undefined;

    var client = tls.Client.init(sr.interface(), &sw.interface, .{
        .host = .{ .explicit = host },
        .ca = .{ .bundle = ca_bundle },
        .write_buffer = &tls_write_buf,
        .read_buffer = &tls_read_buf,
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

fn dialProxy(allocator: Allocator, proxy: Proxy, timeout_secs: u32) ProxyError!std.net.Stream {
    const proxy_addr = try resolveIp4(allocator, proxy.host, proxy.port);

    const sock = std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        std.posix.IPPROTO.TCP,
    ) catch return error.SocketFailed;
    errdefer std.posix.close(sock);

    // Bound both directions so a malicious/broken proxy cannot hang us forever.
    const tv = std.posix.timeval{ .sec = @intCast(timeout_secs), .usec = 0 };
    std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};
    std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};

    std.posix.connect(sock, &proxy_addr.any, proxy_addr.getOsSockLen()) catch
        return error.ConnectFailed;

    return std.net.Stream{ .handle = sock };
}

fn resolveIp4(allocator: Allocator, host: []const u8, port: u16) ProxyError!std.net.Address {
    const list = std.net.getAddressList(allocator, host, port) catch return error.DnsResolveFailed;
    defer list.deinit();
    for (list.addrs) |a| {
        if (a.any.family == std.posix.AF.INET) return a;
    }
    return error.DnsResolveFailed;
}

// --- Blocking stream I/O helpers ---

fn writeAll(stream: std.net.Stream, bytes: []const u8) ProxyError!void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = stream.write(bytes[off..]) catch return error.HandshakeFailed;
        if (n == 0) return error.HandshakeFailed;
        off += n;
    }
}

fn readN(stream: std.net.Stream, buf: []u8) ProxyError!void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = stream.read(buf[off..]) catch return error.HandshakeFailed;
        if (n == 0) return error.HandshakeFailed; // unexpected EOF
        off += n;
    }
}

// --- SOCKS5 (RFC 1928) + user/pass auth (RFC 1929) ---

fn socks5Handshake(stream: std.net.Stream, proxy: Proxy) ProxyError!void {
    const have_auth = proxy.username != null;

    var greeting: [4]u8 = undefined;
    const greeting_len = buildSocks5Greeting(&greeting, have_auth);
    try writeAll(stream, greeting[0..greeting_len]);

    var sel: [2]u8 = undefined;
    try readN(stream, &sel);
    if (sel[0] != 0x05) return error.InvalidResponse;
    switch (sel[1]) {
        // No-auth accepted. We allow this even when credentials were supplied:
        // the proxy doesn't require them, and withholding creds from a proxy
        // that didn't ask avoids leaking them to a misconfigured endpoint.
        0x00 => {},
        0x02 => try socks5UserPassAuth(stream, proxy),
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

fn socks5UserPassAuth(stream: std.net.Stream, proxy: Proxy) ProxyError!void {
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
    try writeAll(stream, buf[0..i]);

    var reply: [2]u8 = undefined;
    try readN(stream, &reply);
    if (reply[1] != 0x00) return error.AuthenticationFailed;
}

fn socks5ConnectIp4(stream: std.net.Stream, ip4: [4]u8, port: u16) ProxyError!void {
    const req = buildSocks5ConnectIp4(ip4, port);
    try writeAll(stream, &req);
    try readSocks5Reply(stream);
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

fn socks5ConnectDomain(stream: std.net.Stream, host: []const u8, port: u16) ProxyError!void {
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
    try writeAll(stream, req[0 .. 7 + host.len]);
    try readSocks5Reply(stream);
}

/// Read and validate a SOCKS5 CONNECT reply, discarding the variable-length
/// BND.ADDR / BND.PORT trailer.
fn readSocks5Reply(stream: std.net.Stream) ProxyError!void {
    var head: [4]u8 = undefined;
    try readN(stream, &head);
    if (head[0] != 0x05) return error.InvalidResponse;
    if (head[1] != 0x00) {
        // REP != succeeded: log the reason (0x05 refused, 0x04 host unreachable,
        // 0x02 not allowed by ruleset, ...) so proxy failures are debuggable.
        log.warn("SOCKS5 CONNECT rejected: REP=0x{x:0>2}", .{head[1]});
        return error.HandshakeFailed;
    }

    // BND.ADDR length depends on ATYP, then 2 bytes of BND.PORT.
    var trailer: usize = switch (head[3]) {
        0x01 => 4, // IPv4
        0x04 => 16, // IPv6
        0x03 => blk: {
            var l: [1]u8 = undefined;
            try readN(stream, &l);
            break :blk l[0];
        },
        else => return error.InvalidResponse,
    };
    trailer += 2; // BND.PORT

    var scratch: [256]u8 = undefined;
    while (trailer > 0) {
        const take = @min(trailer, scratch.len);
        try readN(stream, scratch[0..take]);
        trailer -= take;
    }
}

// --- HTTP CONNECT ---

fn httpConnect(allocator: Allocator, stream: std.net.Stream, proxy: Proxy, host: []const u8, port: u16) ProxyError!void {
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

    try writeAll(stream, req.items);
    try readHttpConnectStatus(stream);
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
fn readHttpConnectStatus(stream: std.net.Stream) ProxyError!void {
    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = stream.read(buf[len .. len + 1]) catch return error.HandshakeFailed;
        if (n == 0) return error.HandshakeFailed;
        len += 1;
        if (len >= 4 and std.mem.eql(u8, buf[len - 4 .. len], "\r\n\r\n")) break;
    } else {
        return error.InvalidResponse; // headers too long
    }

    const status = parseStatusCode(buf[0..len]) orelse return error.InvalidResponse;
    if (status < 200 or status >= 300) return error.HandshakeFailed;
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
