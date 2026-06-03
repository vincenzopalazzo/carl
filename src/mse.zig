/// Vuze Message Stream Encryption / Protocol Encryption (MSE/PE) v1.0.
///
/// Obfuscates the BitTorrent wire protocol with a 768-bit DH exchange and RC4
/// stream encryption. See the archived spec:
/// https://web.archive.org/web/20161231215426/http://wiki.vuze.com/w/Message_Stream_Encryption
const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha1 = std.crypto.hash.Sha1;
const Managed = std.math.big.int.Managed;
const Mutable = std.math.big.int.Mutable;
const Const = std.math.big.int.Const;

pub const dh_pubkey_len: usize = 96;
pub const skey_len: usize = 20;
pub const hash_len: usize = Sha1.digest_length;
pub const vc: [8]u8 = .{0} ** 8;
pub const rc4_discard_len: usize = 1024;
pub const max_pad_len: usize = 512;
pub const min_dh_step_bytes: usize = 96;
pub const max_dh_step_bytes: usize = 608;

pub const crypto_plaintext: u32 = 0x01;
pub const crypto_rc4: u32 = 0x02;

/// 768-bit safe prime P (big-endian, 96 bytes).
pub const dh_prime_be: [dh_pubkey_len]u8 = .{
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xC9, 0x0F, 0xDA, 0xA2, 0x21, 0x68, 0xC2, 0x34,
    0xC4, 0xC6, 0x62, 0x8B, 0x80, 0xDC, 0x1C, 0xD1, 0x29, 0x02, 0x4E, 0x08, 0x8A, 0x67, 0xCC, 0x74,
    0x02, 0x0B, 0xBE, 0xA6, 0x3B, 0x13, 0x9B, 0x22, 0x51, 0x4A, 0x08, 0x79, 0x8E, 0x34, 0x04, 0xDD,
    0xEF, 0x95, 0x19, 0xB3, 0xCD, 0x3A, 0x43, 0x1B, 0x30, 0x2B, 0x0A, 0x6D, 0xF2, 0x5F, 0x14, 0x37,
    0x4F, 0xE1, 0x35, 0x6D, 0x6D, 0x51, 0xC2, 0x45, 0xE4, 0x85, 0xB5, 0x76, 0x62, 0x5E, 0x7E, 0xC6,
    0xF4, 0x4C, 0x42, 0xE9, 0xA6, 0x3A, 0x36, 0x21, 0x00, 0x00, 0x00, 0x00, 0x00, 0x09, 0x05, 0x63,
};

pub const CryptoMethod = enum(u32) {
    plaintext = crypto_plaintext,
    rc4 = crypto_rc4,
};

pub const Role = enum {
    initiator, // A
    responder, // B
};

pub const Options = struct {
    skey: [skey_len]u8,
    /// Bitfield of offered methods (typically `crypto_rc4` or `crypto_plaintext | crypto_rc4`).
    crypto_provide: u32 = crypto_rc4,
    /// Optional bytes sent as IA in step 3 (e.g. serialized BEP 3 handshake).
    ia: []const u8 = &.{},
};

/// RC4 stream cipher with Vuze's mandatory 1024-byte keystream discard.
pub const Rc4 = struct {
    s: [256]u8,
    i: u8,
    j: u8,

    pub fn init(key: []const u8) Rc4 {
        var rc: Rc4 = undefined;
        for (0..256) |n| {
            rc.s[n] = @intCast(n);
        }
        var j: u8 = 0;
        for (0..256) |n| {
            j = j +% rc.s[n] +% key[n % key.len];
            std.mem.swap(u8, &rc.s[n], &rc.s[j]);
        }
        rc.i = 0;
        rc.j = 0;
        return rc;
    }

    pub fn discardKeystream(self: *Rc4, count: usize) void {
        var buf: [64]u8 = undefined;
        var left = count;
        while (left > 0) {
            const chunk = @min(left, buf.len);
            @memset(buf[0..chunk], 0);
            self.cryptInPlace(buf[0..chunk]);
            left -= chunk;
        }
    }

    pub fn cryptInPlace(self: *Rc4, buf: []u8) void {
        for (buf) |*byte| {
            self.i +%= 1;
            self.j +%= self.s[self.i];
            std.mem.swap(u8, &self.s[self.i], &self.s[self.j]);
            const idx = self.s[self.i] +% self.s[self.j];
            byte.* ^= self.s[idx];
        }
    }
};

/// Established MSE session over a TCP stream.
///
/// `close()` shuts down the underlying socket. Do not close the same
/// `std.net.Stream` again after a successful handshake.
pub const Stream = struct {
    inner: std.net.Stream,
    encrypt: Rc4,
    decrypt: Rc4,
    method: CryptoMethod,

    pub fn read(self: *Stream, buf: []u8) !usize {
        const n = try self.inner.read(buf);
        if (n > 0 and self.method == .rc4) {
            self.decrypt.cryptInPlace(buf[0..n]);
        }
        return n;
    }

    pub fn write(self: *Stream, buf: []const u8) !usize {
        if (buf.len == 0) return 0;
        if (self.method == .rc4) {
            var stack_buf: [4096]u8 = undefined;
            if (buf.len <= stack_buf.len) {
                @memcpy(stack_buf[0..buf.len], buf);
                self.encrypt.cryptInPlace(stack_buf[0..buf.len]);
                return self.inner.write(stack_buf[0..buf.len]);
            }
            const tmp = try std.heap.page_allocator.alloc(u8, buf.len);
            defer std.heap.page_allocator.free(tmp);
            @memcpy(tmp, buf);
            self.encrypt.cryptInPlace(tmp);
            return self.inner.write(tmp);
        }
        return self.inner.write(buf);
    }

    pub fn writeAll(self: *Stream, buf: []const u8) !void {
        var index: usize = 0;
        while (index < buf.len) {
            const n = try self.write(buf[index..]);
            if (n == 0) return error.EndOfStream;
            index += n;
        }
    }

    pub fn close(self: Stream) void {
        self.inner.close();
    }
};

/// SHA1 HASH(label, parts...) per Vuze MSE.
pub fn hashParts(out: *[hash_len]u8, parts: []const []const u8) void {
    var h = Sha1.init(.{});
    for (parts) |p| h.update(p);
    h.final(out);
}

pub fn hashReq1(s_be: *const [dh_pubkey_len]u8, out: *[hash_len]u8) void {
    hashParts(out, &.{ "req1", s_be[0..] });
}

pub fn hashReq2(skey: *const [skey_len]u8, out: *[hash_len]u8) void {
    hashParts(out, &.{ "req2", skey[0..] });
}

pub fn hashReq3(s_be: *const [dh_pubkey_len]u8, out: *[hash_len]u8) void {
    hashParts(out, &.{ "req3", s_be[0..] });
}

pub fn hashStreamKey(role: Role, s_be: *const [dh_pubkey_len]u8, skey: *const [skey_len]u8, out: *[hash_len]u8) void {
    const label = switch (role) {
        .initiator => "keyA",
        .responder => "keyB",
    };
    hashParts(out, &.{ label, s_be[0..], skey[0..] });
}

pub fn initRc4FromShared(role: Role, s_be: *const [dh_pubkey_len]u8, skey: *const [skey_len]u8) Rc4 {
    var key: [hash_len]u8 = undefined;
    hashStreamKey(role, s_be, skey, &key);
    var rc = Rc4.init(&key);
    rc.discardKeystream(rc4_discard_len);
    return rc;
}

fn readManagedBe(allocator: Allocator, bytes: []const u8) !Managed {
    var m = try Managed.initCapacity(allocator, (bytes.len + 7) / 8 + 1);
    var mut = m.toMutable();
    mut.readTwosComplement(bytes, bytes.len * 8, .big, .unsigned);
    m.setMetadata(mut.positive, mut.len);
    return m;
}

fn writeManagedBe(m: Const, out: *[dh_pubkey_len]u8) void {
    @memset(out, 0);
    Const.writeTwosComplement(m, out, .big);
}

fn loadDhPrime(allocator: Allocator) !Managed {
    return readManagedBe(allocator, &dh_prime_be);
}

pub fn modPow(
    allocator: Allocator,
    result: *Managed,
    base: *const Managed,
    exponent: *const Managed,
    modulus: *const Managed,
) !void {
    var acc = try Managed.initSet(allocator, @as(u32, 1));
    defer acc.deinit();
    var b = try base.clone();
    defer b.deinit();
    var e = try exponent.clone();
    defer e.deinit();
    var tmp = try Managed.initCapacity(allocator, modulus.len() * 2 + 4);
    defer tmp.deinit();
    var rem = try Managed.initCapacity(allocator, modulus.len() + 2);
    defer rem.deinit();
    var q = try Managed.initCapacity(allocator, modulus.len() + 2);
    defer q.deinit();

    try Managed.divTrunc(&q, &rem, base, modulus);
    try b.copy(rem.toConst());

    while (!e.eqlZero()) {
        if (e.isOdd()) {
            try Managed.mul(&tmp, &acc, &b);
            try Managed.divTrunc(&q, &rem, &tmp, modulus);
            try acc.copy(rem.toConst());
        }
        try Managed.mul(&tmp, &b, &b);
        try Managed.divTrunc(&q, &rem, &tmp, modulus);
        try b.copy(rem.toConst());
        try Managed.shiftRight(&e, &e, 1);
    }
    try result.copy(acc.toConst());
}

/// Generate a 160-bit private DH exponent (20 random bytes).
pub fn generatePrivateKey(allocator: Allocator) !Managed {
    var bytes: [20]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    bytes[0] |= 0x80; // ensure top bit set → at least 128 bits
    return readManagedBe(allocator, &bytes);
}

pub fn dhPublicKey(allocator: Allocator, private_key: *const Managed, out: *[dh_pubkey_len]u8) !void {
    var p = try loadDhPrime(allocator);
    defer p.deinit();
    var g = try Managed.initSet(allocator, @as(u32, 2));
    defer g.deinit();
    var y = try Managed.initCapacity(allocator, dh_pubkey_len);
    defer y.deinit();
    try modPow(allocator, &y, &g, private_key, &p);
    writeManagedBe(y.toConst(), out);
}

pub fn dhSharedSecret(
    allocator: Allocator,
    private_key: *const Managed,
    peer_pubkey_be: *const [dh_pubkey_len]u8,
    out: *[dh_pubkey_len]u8,
) !void {
    var p = try loadDhPrime(allocator);
    defer p.deinit();
    var y_peer = try readManagedBe(allocator, peer_pubkey_be);
    defer y_peer.deinit();
    var s = try Managed.initCapacity(allocator, dh_pubkey_len);
    defer s.deinit();
    try modPow(allocator, &s, &y_peer, private_key, &p);
    writeManagedBe(s.toConst(), out);
}

fn randomPad(allocator: Allocator) ![]u8 {
    const len = std.crypto.random.intRangeAtMost(usize, 0, max_pad_len);
    const pad = try allocator.alloc(u8, len);
    std.crypto.random.bytes(pad);
    return pad;
}

fn writeDhStep(stream: *std.net.Stream, pubkey: *const [dh_pubkey_len]u8, pad: []const u8) !void {
    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u16, hdr[0..2], dh_pubkey_len, .big);
    std.mem.writeInt(u16, hdr[2..4], @intCast(pad.len), .big);
    try writeAll(stream, hdr[0..]);
    try writeAll(stream, pubkey);
    if (pad.len > 0) try writeAll(stream, pad);
}

fn readDhStep(allocator: Allocator, stream: *std.net.Stream, pubkey: *[dh_pubkey_len]u8) ![]u8 {
    var hdr: [4]u8 = undefined;
    try readExact(stream, &hdr);
    const ya_len = std.mem.readInt(u16, hdr[0..2], .big);
    const pad_len = std.mem.readInt(u16, hdr[2..4], .big);
    if (ya_len != dh_pubkey_len or pad_len > max_pad_len) return error.InvalidDhStep;
    try readExact(stream, pubkey);
    if (pad_len == 0) return &.{};
    const pad = try allocator.alloc(u8, pad_len);
    errdefer allocator.free(pad);
    try readExact(stream, pad);
    return pad;
}

fn writeAll(stream: *std.net.Stream, buf: []const u8) !void {
    var index: usize = 0;
    while (index < buf.len) {
        const n = try stream.write(buf[index..]);
        if (n == 0) return error.EndOfStream;
        index += n;
    }
}

fn readExact(stream: *std.net.Stream, buf: []u8) !void {
    var index: usize = 0;
    while (index < buf.len) {
        const n = try stream.read(buf[index..]);
        if (n == 0) return error.EndOfStream;
        index += n;
    }
}

fn selectCrypto(crypto_provide: u32, crypto_select: u32) !CryptoMethod {
    if (crypto_provide == 0) return error.NoCryptoProvided;
    const selected = crypto_select & crypto_provide;
    if (selected & crypto_rc4 != 0) return .rc4;
    if (selected & crypto_plaintext != 0) return .plaintext;
    return error.UnsupportedCrypto;
}

/// Run the full 5-step MSE handshake as initiator (A).
pub fn handshakeInitiator(allocator: Allocator, stream: *std.net.Stream, opts: Options) !Stream {
    var priv = try generatePrivateKey(allocator);
    defer priv.deinit();

    var ya: [dh_pubkey_len]u8 = undefined;
    try dhPublicKey(allocator, &priv, &ya);

    const pad_a = try randomPad(allocator);
    defer allocator.free(pad_a);
    try writeDhStep(stream, &ya, pad_a);

    var yb: [dh_pubkey_len]u8 = undefined;
    const pad_b = try readDhStep(allocator, stream, &yb);
    defer if (pad_b.len > 0) allocator.free(pad_b);

    var s: [dh_pubkey_len]u8 = undefined;
    try dhSharedSecret(allocator, &priv, &yb, &s);

    var enc = initRc4FromShared(.initiator, &s, &opts.skey);
    var dec = initRc4FromShared(.responder, &s, &opts.skey);

    var req1: [hash_len]u8 = undefined;
    var req2: [hash_len]u8 = undefined;
    var req3: [hash_len]u8 = undefined;
    hashReq1(&s, &req1);
    hashReq2(&opts.skey, &req2);
    hashReq3(&s, &req3);

    var skey_xor: [hash_len]u8 = undefined;
    for (0..hash_len) |i| {
        skey_xor[i] = req2[i] ^ req3[i];
    }

    const pad_c = try randomPad(allocator);
    defer allocator.free(pad_c);

    // Step 3: req1 + skey_xor in plaintext, then ENCRYPT(VC, …, IA).
    try writeAll(stream, &req1);
    try writeAll(stream, &skey_xor);

    const enc_len = 8 + 4 + 2 + pad_c.len + 2 + opts.ia.len;
    var enc_part = try allocator.alloc(u8, enc_len);
    defer allocator.free(enc_part);
    var off: usize = 0;
    @memcpy(enc_part[off..][0..8], &vc);
    off += 8;
    std.mem.writeInt(u32, enc_part[off..][0..4], opts.crypto_provide, .big);
    off += 4;
    std.mem.writeInt(u16, enc_part[off..][0..2], @intCast(pad_c.len), .big);
    off += 2;
    if (pad_c.len > 0) {
        @memcpy(enc_part[off..][0..pad_c.len], pad_c);
        off += pad_c.len;
    }
    std.mem.writeInt(u16, enc_part[off..][0..2], @intCast(opts.ia.len), .big);
    off += 2;
    if (opts.ia.len > 0) {
        @memcpy(enc_part[off..][0..opts.ia.len], opts.ia);
        off += opts.ia.len;
    }
    enc.cryptInPlace(enc_part[0..off]);
    try writeAll(stream, enc_part[0..off]);

    // Step 4: ENCRYPT(VC, crypto_select, len(PadD), PadD) + ENCRYPT2(payload)
    var buf: [1024]u8 = undefined;
    var total: usize = 0;
    var crypto_select: u32 = 0;
    var method: CryptoMethod = undefined;
    while (total < buf.len) {
        const n = try stream.read(buf[total..]);
        if (n == 0) return error.EndOfStream;
        total += n;
        var trial: usize = 8 + 4 + 2;
        while (trial <= total) : (trial += 1) {
            var tmp = buf[0..trial];
            dec.cryptInPlace(tmp);
            if (!std.mem.eql(u8, tmp[0..8], &vc)) continue;
            crypto_select = std.mem.readInt(u32, tmp[8..12], .big);
            method = selectCrypto(opts.crypto_provide, crypto_select) catch continue;
            const pad_d_len = std.mem.readInt(u16, tmp[12..14], .big);
            if (pad_d_len > max_pad_len) continue;
            const need = 8 + 4 + 2 + pad_d_len;
            if (total < need) break;
            if (total > need) {
                dec.cryptInPlace(buf[need..total]);
            }
            return .{
                .inner = stream.*,
                .encrypt = enc,
                .decrypt = dec,
                .method = method,
            };
        }
    }
    return error.HandshakeSyncFailed;
}

/// Run the full 5-step MSE handshake as responder (B).
pub fn handshakeResponder(allocator: Allocator, stream: *std.net.Stream, opts: Options) !Stream {
    var priv = try generatePrivateKey(allocator);
    defer priv.deinit();

    var ya: [dh_pubkey_len]u8 = undefined;
    const pad_a = try readDhStep(allocator, stream, &ya);
    defer if (pad_a.len > 0) allocator.free(pad_a);

    var yb: [dh_pubkey_len]u8 = undefined;
    try dhPublicKey(allocator, &priv, &yb);
    const pad_b = try randomPad(allocator);
    defer allocator.free(pad_b);
    try writeDhStep(stream, &yb, pad_b);

    var s: [dh_pubkey_len]u8 = undefined;
    try dhSharedSecret(allocator, &priv, &ya, &s);

    var req1: [hash_len]u8 = undefined;
    hashReq1(&s, &req1);

    var enc = initRc4FromShared(.responder, &s, &opts.skey);
    var dec = initRc4FromShared(.initiator, &s, &opts.skey);

    var plain: [hash_len * 2]u8 = undefined;
    try readExact(stream, plain[0..hash_len]);
    if (!std.mem.eql(u8, plain[0..hash_len], &req1)) return error.HandshakeSyncFailed;

    try readExact(stream, plain[hash_len..]);
    var req2: [hash_len]u8 = undefined;
    hashReq2(&opts.skey, &req2);
    var req3: [hash_len]u8 = undefined;
    hashReq3(&s, &req3);
    var expect_xor: [hash_len]u8 = undefined;
    for (0..hash_len) |i| expect_xor[i] = req2[i] ^ req3[i];
    if (!std.mem.eql(u8, plain[hash_len..], &expect_xor)) return error.InvalidSkeyHash;

    var enc_buf: [512 + 8 + 4 + 2 + 2 + 65535]u8 = undefined;
    var enc_total: usize = 0;
    const min_enc = 8 + 4 + 2 + 2;
    while (enc_total < enc_buf.len) {
        const n = try stream.read(enc_buf[enc_total..]);
        if (n == 0) return error.EndOfStream;
        enc_total += n;
        if (enc_total < min_enc) continue;
        var trial = enc_buf[0..enc_total];
        dec.cryptInPlace(trial);
        if (!std.mem.eql(u8, trial[0..8], &vc)) continue;
        const crypto_provide = std.mem.readInt(u32, trial[8..12], .big);
        const pad_c_len = std.mem.readInt(u16, trial[12..14], .big);
        if (pad_c_len > max_pad_len) continue;
        const need = 8 + 4 + 2 + pad_c_len + 2;
        if (enc_total < need) continue;
        const ia_len = std.mem.readInt(u16, trial[14 + pad_c_len ..][0..2], .big);
        if (ia_len > 65535) continue;
        if (enc_total < need + ia_len) continue;

        const crypto_select: u32 = crypto_rc4;
        const method = try selectCrypto(crypto_provide, crypto_select);

        var step4_plain = [_]u8{0} ** (8 + 4 + 2);
        @memcpy(step4_plain[0..8], &vc);
        std.mem.writeInt(u32, step4_plain[8..12], crypto_select, .big);
        std.mem.writeInt(u16, step4_plain[12..14], 0, .big);
        enc.cryptInPlace(&step4_plain);
        try writeAll(stream, &step4_plain);

        return .{
            .inner = stream.*,
            .encrypt = enc,
            .decrypt = dec,
            .method = method,
        };
    }
    return error.HandshakeSyncFailed;
}

// --- tests ---

const testing = std.testing;

fn hexToBytes(comptime hex_str: []const u8) [dh_pubkey_len]u8 {
    var out: [dh_pubkey_len]u8 = undefined;
    var i: usize = 0;
    var j: usize = 0;
    while (i < hex_str.len) : (i += 2) {
        const hi = std.fmt.parseInt(u4, hex_str[i .. i + 1], 16) catch unreachable;
        const lo = std.fmt.parseInt(u4, hex_str[i + 1 .. i + 2], 16) catch unreachable;
        out[j] = @as(u8, hi) << 4 | lo;
        j += 1;
    }
    return out;
}

test "dh shared secret test vector" {
    const allocator = testing.allocator;
    const xa_hex = "1234567890abcdef1234567890abcdef12345678";
    const xb_hex = "fedcba0987654321fedcba0987654321fedcba09";
    const ya_hex = "c44386497c31c0f76d76479d03a6f40c0cdac6c9a709f493da2c7aa8adb2cbfafe6b7833c0ded4ab5a310db1c2473066f1d3ef0a9e89f1093e7902f72337396dab1d1276ab9e6d447b62e57de71ec5b528209d8fadff8cb9b0d393131aa4a722";
    const yb_hex = "1264d66dda8e04907145f55a2e069e6fe7b6995abdf21a846f78a72ef3a047ac1893abacd6e08749eb3d313c3513932400d16d22d3003be57dad041c40b07cf9ea5eb0cf1593ac89ba444f17fc66ee7e1d96b5d1fd2136f96b92d50bd174ad6f";
    const s_hex = "7c1798a6ebab579cdd77e332bbab0901538801b6c73ec83c02a470e4d766ae98d8294d822827ecbac1c0bb7c6c7dea25eb6304393ac9c64e7963ef10cdb532c89da9695e550ced358895ad66b16fae3831b600b2d0e0c032203962b5140224b8";

    var xa = try Managed.initSet(allocator, 0);
    defer xa.deinit();
    try xa.setString(16, xa_hex);

    var xb = try Managed.initSet(allocator, 0);
    defer xb.deinit();
    try xb.setString(16, xb_hex);

    var ya: [dh_pubkey_len]u8 = undefined;
    try dhPublicKey(allocator, &xa, &ya);
    try testing.expectEqualSlices(u8, &hexToBytes(ya_hex), &ya);

    var yb: [dh_pubkey_len]u8 = undefined;
    try dhPublicKey(allocator, &xb, &yb);
    try testing.expectEqualSlices(u8, &hexToBytes(yb_hex), &yb);

    var s: [dh_pubkey_len]u8 = undefined;
    try dhSharedSecret(allocator, &xa, &yb, &s);
    try testing.expectEqualSlices(u8, &hexToBytes(s_hex), &s);

    var s2: [dh_pubkey_len]u8 = undefined;
    try dhSharedSecret(allocator, &xb, &ya, &s2);
    try testing.expectEqualSlices(u8, &s, &s2);
}

test "rc4 discard keystream" {
    var rc = Rc4.init("Key");
    var buf1: [10]u8 = .{0} ** 10;
    var buf2: [10]u8 = .{0} ** 10;
    rc.cryptInPlace(&buf1);
    var rc2 = Rc4.init("Key");
    rc2.discardKeystream(rc4_discard_len);
    rc2.cryptInPlace(&buf2);
    try testing.expect(!std.mem.eql(u8, &buf1, &buf2));
}

test "hash req1 deterministic" {
    const s = hexToBytes("7c1798a6ebab579cdd77e332bbab0901538801b6c73ec83c02a470e4d766ae98d8294d822827ecbac1c0bb7c6c7dea25eb6304393ac9c64e7963ef10cdb532c89da9695e550ced358895ad66b16fae3831b600b2d0e0c032203962b5140224b8");
    var h1: [hash_len]u8 = undefined;
    var h2: [hash_len]u8 = undefined;
    hashReq1(&s, &h1);
    hashReq1(&s, &h2);
    try testing.expectEqualSlices(u8, &h1, &h2);
}

test "mse loopback handshake" {
    const allocator = testing.allocator;
    const skey: [skey_len]u8 = .{0xAB} ** skey_len;

    const listen_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    var server = try listen_addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.in.getPort();

    const ServerCtx = struct {
        server: *std.net.Server,
        skey: [skey_len]u8,
        fn run(ctx: *@This()) void {
            const conn = ctx.server.accept() catch return;
            var peer_stream = conn.stream;
            defer peer_stream.close();
            _ = handshakeResponder(allocator, &peer_stream, .{
                .skey = ctx.skey,
                .crypto_provide = crypto_rc4,
            }) catch return;
        }
    };
    var ctx = ServerCtx{ .server = &server, .skey = skey };
    const server_thread = try std.Thread.spawn(.{}, ServerCtx.run, .{&ctx});

    const client_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    var stream = try std.net.tcpConnectToAddress(client_addr);

    const ia = "test-ia-payload";
    var mse_stream = try handshakeInitiator(allocator, &stream, .{
        .skey = skey,
        .crypto_provide = crypto_rc4,
        .ia = ia,
    });
    defer mse_stream.close();

    server_thread.join();

    try testing.expect(mse_stream.method == .rc4);
}
