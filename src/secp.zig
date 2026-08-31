//! BIP-340 Schnorr signatures over secp256k1, exposed as a thin Zig wrapper
//! around libsecp256k1 (vendored via build.zig.zon). Only the subset Nostr
//! needs is exposed: 32-byte x-only public keys, 64-byte signatures, sign and
//! verify of an already-hashed 32-byte message.
//!
//! The library context is created lazily on first use and shared process-wide.
//! libsecp256k1 0.5+ allows a single SECP256K1_CONTEXT_NONE context for both
//! signing and verification; we randomize it once for side-channel resistance.

const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cDefine("ENABLE_MODULE_SCHNORRSIG", "1");
    @cDefine("ENABLE_MODULE_EXTRAKEYS", "1");
    // libsecp256k1 marks its public API as `__declspec(dllimport)` on
    // MSVC/MinGW unless SECP256K1_STATIC is defined. We always link it as a
    // static library via build.zig, so the import-style declarations would
    // cause Windows cross-builds to fail looking for `__imp_*` symbols.
    // Setting the macro is a no-op on POSIX, so it's safe to set everywhere.
    @cDefine("SECP256K1_STATIC", "1");
    @cInclude("secp256k1.h");
    @cInclude("secp256k1_extrakeys.h");
    @cInclude("secp256k1_schnorrsig.h");
});

const log = std.log.scoped(.secp);

pub const Error = error{
    InvalidSecretKey,
    InvalidPublicKey,
    InvalidHex,
    KeyGenerationFailed,
    SigningFailed,
    OutOfMemory,
};

/// A secp256k1 secret key. 32 bytes in [1, n-1].
pub const SecretKey = [32]u8;

/// A 32-byte x-only public key (BIP-340 format).
pub const PublicKey = [32]u8;

/// A 64-byte BIP-340 Schnorr signature.
pub const Signature = [64]u8;

// ---------------------------------------------------------------------------
// Shared context
// ---------------------------------------------------------------------------

var shared_ctx: ?*c.secp256k1_context = null;
var shared_io: ?std.Io = null;
var init_mutex: std.Io.Mutex = .init;

pub fn init(io: std.Io) Error!void {
    init_mutex.lockUncancelable(io);
    defer init_mutex.unlock(io);

    if (shared_ctx != null) return;

    const new_ctx =
        c.secp256k1_context_create(c.SECP256K1_CONTEXT_NONE);

    if (new_ctx == null) {
        log.err("secp256k1_context_create returned null", .{});
        return error.OutOfMemory;
    }

    var seed: [32]u8 = undefined;
    io.random(&seed);

    if (c.secp256k1_context_randomize(new_ctx, &seed) != 1) {
        log.warn("secp256k1_context_randomize failed", .{});
    }

    shared_io = io;
    shared_ctx = new_ctx;
}

fn getCtx() !*c.secp256k1_context {
    if (shared_ctx == null and builtin.is_test) {
        try init(std.testing.io);
    }

    return shared_ctx orelse error.OutOfMemory;
}

fn getIo() !std.Io {
    return shared_io orelse error.OutOfMemory;
}

// ---------------------------------------------------------------------------
// Key generation and derivation
// ---------------------------------------------------------------------------

/// Generate a fresh random secret key. The implementation rejects scalars
/// outside [1, n-1] by checking with libsecp256k1.
pub fn generateSecretKey() Error!SecretKey {
    const ctx_ptr = try getCtx();
    const io = try getIo();
    var sk: SecretKey = undefined;
    var attempts: u32 = 0;
    while (attempts < 256) : (attempts += 1) {
        io.random(&sk);
        if (c.secp256k1_ec_seckey_verify(ctx_ptr, &sk) == 1) return sk;
    }
    // Statistically unreachable (~256 * 2^-256), but if the RNG is broken or
    // the curve order has shifted under our feet, return a name that matches
    // the action.
    return error.KeyGenerationFailed;
}

/// Derive the x-only public key from a secret key. Returns InvalidSecretKey if
/// the scalar is zero or >= n.
pub fn publicKeyFromSecret(sk: SecretKey) Error!PublicKey {
    const ctx_ptr = try getCtx();
    var keypair: c.secp256k1_keypair = undefined;
    if (c.secp256k1_keypair_create(ctx_ptr, &keypair, &sk) != 1) {
        return error.InvalidSecretKey;
    }
    var xonly: c.secp256k1_xonly_pubkey = undefined;
    if (c.secp256k1_keypair_xonly_pub(ctx_ptr, &xonly, null, &keypair) != 1) {
        return error.InvalidSecretKey;
    }
    var out: PublicKey = undefined;
    _ = c.secp256k1_xonly_pubkey_serialize(ctx_ptr, &out, &xonly);
    return out;
}

// ---------------------------------------------------------------------------
// Sign and verify
// ---------------------------------------------------------------------------

/// Sign a 32-byte message hash with BIP-340 Schnorr. When `aux_rand` is null
/// we draw 32 fresh bytes from `std.crypto.random` — per BIP-340 §3.3,
/// auxiliary randomness mitigates fault and side-channel attacks on the nonce
/// derivation, so the safe default is the easy default. Callers needing
/// deterministic signatures (test vectors, reproducibility) pass an explicit
/// 32-byte value.
pub fn sign(sk: SecretKey, msg32: [32]u8, aux_rand: ?[32]u8) Error!Signature {
    const ctx_ptr = try getCtx();
    var keypair: c.secp256k1_keypair = undefined;
    if (c.secp256k1_keypair_create(ctx_ptr, &keypair, &sk) != 1) {
        return error.InvalidSecretKey;
    }
    var aux: [32]u8 = undefined;
    if (aux_rand) |a| {
        aux = a;
    } else {
        const io = try getIo();
        io.random(&aux);
    }
    var sig: Signature = undefined;
    if (c.secp256k1_schnorrsig_sign32(ctx_ptr, &sig, &msg32, &keypair, &aux) != 1) {
        return error.SigningFailed;
    }
    return sig;
}

/// Verify a BIP-340 Schnorr signature over an arbitrary-length message.
/// Nostr signs a 32-byte event id hash; other callers may sign other lengths.
/// Returns true if the signature is valid, false otherwise.
pub fn verify(sig: Signature, msg: []const u8, pk: PublicKey) bool {
    const ctx_ptr = getCtx() catch return false;
    var xonly: c.secp256k1_xonly_pubkey = undefined;
    if (c.secp256k1_xonly_pubkey_parse(ctx_ptr, &xonly, &pk) != 1) return false;
    return c.secp256k1_schnorrsig_verify(ctx_ptr, &sig, msg.ptr, msg.len, &xonly) == 1;
}

// ---------------------------------------------------------------------------
// Hex helpers (Nostr serializes everything as lowercase hex)
// ---------------------------------------------------------------------------

const hex_table = "0123456789abcdef";

/// Encode `bytes` as lowercase hex into `out`. `out.len` must equal 2*bytes.len.
/// Mismatched sizes are a programmer error and panic explicitly in all build
/// modes (a `std.debug.assert` would compile out and silently overrun the
/// buffer in ReleaseFast/ReleaseSmall).
pub fn toHex(bytes: []const u8, out: []u8) void {
    if (out.len != bytes.len * 2) @panic("secp.toHex: out buffer must be 2 * bytes.len");
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex_table[b >> 4];
        out[i * 2 + 1] = hex_table[b & 0x0f];
    }
}

/// Decode lowercase or uppercase hex into `out`. `out.len` must equal hex.len/2.
pub fn fromHex(hex: []const u8, out: []u8) Error!void {
    if (hex.len != out.len * 2) return error.InvalidHex;
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const hi = nibble(hex[i * 2]) orelse return error.InvalidHex;
        const lo = nibble(hex[i * 2 + 1]) orelse return error.InvalidHex;
        out[i] = (hi << 4) | lo;
    }
}

fn nibble(b: u8) ?u8 {
    return switch (b) {
        '0'...'9' => b - '0',
        'a'...'f' => b - 'a' + 10,
        'A'...'F' => b - 'A' + 10,
        else => null,
    };
}

// ===========================================================================
// Tests — BIP-340 official test vectors
// ===========================================================================
// Source: https://github.com/bitcoin/bips/blob/master/bip-0340/test-vectors.csv

test "BIP-340 vector 0: derive pubkey + sign + verify (sk=3, msg=zeros, aux=zeros)" {
    var sk: SecretKey = undefined;
    try fromHex("0000000000000000000000000000000000000000000000000000000000000003", &sk);

    const expected_pk = "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9";
    var expected_pk_bytes: PublicKey = undefined;
    try fromHex(expected_pk, &expected_pk_bytes);

    const pk = try publicKeyFromSecret(sk);
    try std.testing.expectEqualSlices(u8, &expected_pk_bytes, &pk);

    const msg: [32]u8 = .{0} ** 32;
    const aux: [32]u8 = .{0} ** 32;
    const sig = try sign(sk, msg, aux);

    const expected_sig = "e907831f80848d1069a5371b402410364bdf1c5f8307b0084c55f1ce2dca8215" ++
        "25f66a4a85ea8b71e482a74f382d2ce5ebeee8fdb2172f477df4900d310536c0";
    var expected_sig_bytes: Signature = undefined;
    try fromHex(expected_sig, &expected_sig_bytes);
    try std.testing.expectEqualSlices(u8, &expected_sig_bytes, &sig);

    try std.testing.expect(verify(sig, &msg, pk));
}

test "BIP-340 vector 1: sign + verify with non-zero aux_rand" {
    var sk: SecretKey = undefined;
    try fromHex("b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef", &sk);

    var msg: [32]u8 = undefined;
    try fromHex("243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89", &msg);

    var aux: [32]u8 = undefined;
    try fromHex("0000000000000000000000000000000000000000000000000000000000000001", &aux);

    const sig = try sign(sk, msg, aux);

    const expected_sig = "6896bd60eeae296db48a229ff71dfe071bde413e6d43f917dc8dcf8c78de3341" ++
        "8906d11ac976abccb20b091292bff4ea897efcb639ea871cfa95f6de339e4b0a";
    var expected_sig_bytes: Signature = undefined;
    try fromHex(expected_sig, &expected_sig_bytes);
    try std.testing.expectEqualSlices(u8, &expected_sig_bytes, &sig);

    const pk = try publicKeyFromSecret(sk);
    try std.testing.expect(verify(sig, &msg, pk));
}

test "BIP-340 verify-only vector with known sig" {
    // Vector 2 from the BIP-340 test vectors.
    var pk: PublicKey = undefined;
    try fromHex("dd308afec5777e13121fa72b9cc1b7cc0139715309b086c960e18fd969774eb8", &pk);

    var msg: [32]u8 = undefined;
    try fromHex("7e2d58d8b3bcdf1abadec7829054f90dda9805aab56c77333024b9d0a508b75c", &msg);

    var sig: Signature = undefined;
    try fromHex(
        "5831aaeed7b44bb74e5eab94ba9d4294c49bcf2a60728d8b4c200f50dd313c1b" ++
            "ab745879a5ad954a72c45a91c3a51d3c7adea98d82f8481e0e1e03674a6f3fb7",
        &sig,
    );

    try std.testing.expect(verify(sig, &msg, pk));
}

test "verify rejects a tampered signature" {
    var sk: SecretKey = undefined;
    try fromHex("0000000000000000000000000000000000000000000000000000000000000003", &sk);
    const pk = try publicKeyFromSecret(sk);

    const msg: [32]u8 = .{0} ** 32;
    var sig = try sign(sk, msg, [_]u8{0} ** 32);

    // Flip a bit in the signature.
    sig[7] ^= 0x01;
    try std.testing.expect(!verify(sig, &msg, pk));
}

test "verify rejects signature under wrong pubkey" {
    var sk_a: SecretKey = undefined;
    try fromHex("0000000000000000000000000000000000000000000000000000000000000003", &sk_a);

    var sk_b: SecretKey = undefined;
    try fromHex("0000000000000000000000000000000000000000000000000000000000000005", &sk_b);
    const pk_b = try publicKeyFromSecret(sk_b);

    const msg: [32]u8 = .{0} ** 32;
    const sig = try sign(sk_a, msg, [_]u8{0} ** 32);

    try std.testing.expect(!verify(sig, &msg, pk_b));
}

test "publicKeyFromSecret rejects zero secret key" {
    const zero: SecretKey = .{0} ** 32;
    try std.testing.expectError(error.InvalidSecretKey, publicKeyFromSecret(zero));
}

test "generateSecretKey produces a valid key that derives a pubkey" {
    const sk = try generateSecretKey();
    const pk = try publicKeyFromSecret(sk);

    // Pubkey should not be all-zero (extremely improbable, but a sanity check).
    var any_nonzero = false;
    for (pk) |b| if (b != 0) {
        any_nonzero = true;
        break;
    };
    try std.testing.expect(any_nonzero);

    // Round-trip: sign random msg and verify.
    var msg: [32]u8 = undefined;
    std.Io.random(std.testing.io, &msg);
    const sig = try sign(sk, msg, null);
    try std.testing.expect(verify(sig, &msg, pk));
}

test "hex round trip" {
    const bytes = [_]u8{ 0xde, 0xad, 0xbe, 0xef, 0x00, 0xff };
    var hex_out: [12]u8 = undefined;
    toHex(&bytes, &hex_out);
    try std.testing.expectEqualStrings("deadbeef00ff", &hex_out);

    var back: [6]u8 = undefined;
    try fromHex(&hex_out, &back);
    try std.testing.expectEqualSlices(u8, &bytes, &back);
}

test "fromHex rejects bad input" {
    var out: [4]u8 = undefined;
    try std.testing.expectError(error.InvalidHex, fromHex("xx", &out)); // wrong length
    try std.testing.expectError(error.InvalidHex, fromHex("ZZZZZZZZ", &out)); // bad chars
}
