//! NIP-19 bech32 entity encoding for Nostr.
//!
//! Supports the bare 32-byte entities used by carl: `npub` (public keys),
//! `nsec` (secret keys), and `note` (event ids). TLV-encoded entities
//! (`nprofile`, `nevent`, `naddr`) are decoded into their component parts
//! but not encoded — carl only needs to consume them.
//!
//! The variant is standard bech32 (not bech32m); HRPs are lowercase ASCII;
//! checksum follows BIP-173.

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.nip19);

pub const Error = error{
    InvalidBech32,
    BadChecksum,
    BadHrp,
    BadLength,
    BadTlv,
    OutOfMemory,
};

pub const Kind = enum {
    npub,
    nsec,
    note,

    pub fn hrp(self: Kind) []const u8 {
        return switch (self) {
            .npub => "npub",
            .nsec => "nsec",
            .note => "note",
        };
    }
};

const charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";
// Precomputed inverse table for the charset above. -1 for invalid chars.
const charset_rev = blk: {
    var t: [128]i8 = .{-1} ** 128;
    for (charset, 0..) |c, i| t[c] = @intCast(i);
    break :blk t;
};

// ---------------------------------------------------------------------------
// Public encode / decode for bare 32-byte entities
// ---------------------------------------------------------------------------

/// Encode a 32-byte payload as bech32 with the given kind's HRP.
/// Caller owns the returned slice.
pub fn encode32(allocator: Allocator, kind: Kind, data: [32]u8) Error![]u8 {
    return encodeRaw(allocator, kind.hrp(), &data);
}

/// Decode a bech32 string. Returns the kind and the 32-byte payload.
/// Returns BadHrp if the HRP doesn't match a known bare-32 entity.
pub fn decode32(input: []const u8) Error!struct { kind: Kind, data: [32]u8 } {
    const decoded = try decodeRaw(input);
    defer std.heap.page_allocator.free(decoded.data);

    if (decoded.data.len != 32) return error.BadLength;

    const kind: Kind = if (std.mem.eql(u8, decoded.hrp, "npub"))
        .npub
    else if (std.mem.eql(u8, decoded.hrp, "nsec"))
        .nsec
    else if (std.mem.eql(u8, decoded.hrp, "note"))
        .note
    else
        return error.BadHrp;

    var out: [32]u8 = undefined;
    @memcpy(&out, decoded.data);
    return .{ .kind = kind, .data = out };
}

// ---------------------------------------------------------------------------
// Lower-level bech32 (used by both the bare-32 path and TLV decoders)
// ---------------------------------------------------------------------------

/// Encode arbitrary raw bytes under `hrp`. Returns owned slice.
pub fn encodeRaw(allocator: Allocator, hrp: []const u8, data: []const u8) Error![]u8 {
    // Convert 8-bit data to 5-bit groups (padded).
    const five = try convertBits(allocator, data, 8, 5, true);
    defer allocator.free(five);

    // Build checksum.
    var values = try allocator.alloc(u5, five.len + 6);
    defer allocator.free(values);
    for (five, 0..) |b, i| values[i] = @intCast(b);
    for (0..6) |i| values[five.len + i] = 0;

    const cksum = createChecksum(hrp, values[0 .. values.len - 6]);
    for (0..6) |i| {
        values[five.len + i] = @intCast((cksum >> @intCast(5 * (5 - i))) & 0x1F);
    }

    // Assemble final string: HRP + "1" + data + checksum.
    var out = try allocator.alloc(u8, hrp.len + 1 + values.len);
    @memcpy(out[0..hrp.len], hrp);
    out[hrp.len] = '1';
    for (values, 0..) |v, i| out[hrp.len + 1 + i] = charset[v];
    return out;
}

const DecodedRaw = struct {
    hrp: []const u8, // borrowed slice of input
    data: []u8, // owned (allocated with page_allocator)
};

fn decodeRaw(input: []const u8) Error!DecodedRaw {
    if (input.len < 8 or input.len > 1024) return error.InvalidBech32;
    // Determine case (all upper or all lower; mixed is invalid).
    var has_lower = false;
    var has_upper = false;
    for (input) |c| {
        if (c >= 'a' and c <= 'z') has_lower = true;
        if (c >= 'A' and c <= 'Z') has_upper = true;
        if (c < 33 or c > 126) return error.InvalidBech32;
    }
    if (has_lower and has_upper) return error.InvalidBech32;

    const sep = std.mem.lastIndexOfScalar(u8, input, '1') orelse return error.InvalidBech32;
    if (sep < 1 or sep + 7 > input.len) return error.InvalidBech32;

    const hrp_slice = input[0..sep];

    // Validate / decode the data part (5-bit values).
    const data_part = input[sep + 1 ..];
    var values_buf: [1024]u5 = undefined;
    if (data_part.len > values_buf.len) return error.InvalidBech32;
    for (data_part, 0..) |c, i| {
        const norm = if (c >= 'A' and c <= 'Z') c + 32 else c;
        if (norm >= charset_rev.len) return error.InvalidBech32;
        const v = charset_rev[norm];
        if (v < 0) return error.InvalidBech32;
        values_buf[i] = @intCast(v);
    }

    // Verify checksum.
    if (!verifyChecksum(hrp_slice, values_buf[0..data_part.len])) {
        return error.BadChecksum;
    }

    const payload = values_buf[0 .. data_part.len - 6];
    const eight = try convertBits(std.heap.page_allocator, payload, 5, 8, false);
    return .{ .hrp = hrp_slice, .data = eight };
}

// ---------------------------------------------------------------------------
// TLV decoder for nevent / naddr / nprofile
// ---------------------------------------------------------------------------

pub const TlvKind = enum {
    nevent,
    naddr,
    nprofile,
};

/// One TLV record.
pub const Tlv = struct {
    type: u8,
    value: []const u8, // borrowed slice into the decoded buffer
};

/// Decoded TLV entity. `buffer` owns the underlying bytes; `tlvs` points into it.
pub const TlvDecoded = struct {
    kind: TlvKind,
    buffer: []u8,
    tlvs: []Tlv,

    pub fn deinit(self: *TlvDecoded, allocator: Allocator) void {
        allocator.free(self.buffer);
        allocator.free(self.tlvs);
    }
};

/// Decode a TLV bech32 entity (nevent/naddr/nprofile).
pub fn decodeTlv(allocator: Allocator, input: []const u8) Error!TlvDecoded {
    const decoded = try decodeRaw(input);
    // We need to re-allocate the bytes into the caller's allocator and free the
    // page_allocator buffer.
    const owned = try allocator.dupe(u8, decoded.data);
    std.heap.page_allocator.free(decoded.data);

    const kind: TlvKind = if (std.mem.eql(u8, decoded.hrp, "nevent"))
        .nevent
    else if (std.mem.eql(u8, decoded.hrp, "naddr"))
        .naddr
    else if (std.mem.eql(u8, decoded.hrp, "nprofile"))
        .nprofile
    else {
        allocator.free(owned);
        return error.BadHrp;
    };

    // Parse TLV records: type (1B), length (1B), value.
    var list: std.ArrayList(Tlv) = .empty;
    errdefer list.deinit(allocator);
    var off: usize = 0;
    while (off < owned.len) {
        if (off + 2 > owned.len) {
            list.deinit(allocator);
            allocator.free(owned);
            return error.BadTlv;
        }
        const t = owned[off];
        const len = owned[off + 1];
        off += 2;
        if (off + len > owned.len) {
            list.deinit(allocator);
            allocator.free(owned);
            return error.BadTlv;
        }
        list.append(allocator, .{ .type = t, .value = owned[off .. off + len] }) catch {
            list.deinit(allocator);
            allocator.free(owned);
            return error.OutOfMemory;
        };
        off += len;
    }

    const tlvs = list.toOwnedSlice(allocator) catch {
        allocator.free(owned);
        return error.OutOfMemory;
    };
    return .{ .kind = kind, .buffer = owned, .tlvs = tlvs };
}

// ---------------------------------------------------------------------------
// Internal bech32 primitives
// ---------------------------------------------------------------------------

/// 5-bit value generator polynomial for the bech32 checksum (BIP-173).
fn polymod(values: []const u5) u32 {
    var chk: u32 = 1;
    const gen: [5]u32 = .{ 0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3 };
    for (values) |v| {
        const top: u32 = chk >> 25;
        chk = ((chk & 0x1ffffff) << 5) ^ @as(u32, v);
        var i: u3 = 0;
        while (i < 5) : (i += 1) {
            if ((top >> i) & 1 == 1) chk ^= gen[i];
        }
    }
    return chk;
}

fn hrpExpand(allocator: Allocator, hrp: []const u8) ![]u5 {
    const out = try allocator.alloc(u5, hrp.len * 2 + 1);
    for (hrp, 0..) |c, i| out[i] = @intCast(c >> 5);
    out[hrp.len] = 0;
    for (hrp, 0..) |c, i| out[hrp.len + 1 + i] = @intCast(c & 0x1f);
    return out;
}

fn createChecksum(hrp: []const u8, data: []const u5) u32 {
    var expand_buf: [128]u5 = undefined;
    for (hrp, 0..) |c, i| expand_buf[i] = @intCast(c >> 5);
    expand_buf[hrp.len] = 0;
    for (hrp, 0..) |c, i| expand_buf[hrp.len + 1 + i] = @intCast(c & 0x1f);
    const expand_len = hrp.len * 2 + 1;

    // Concatenate expand + data + 6 zero values.
    var values_buf: [1024]u5 = undefined;
    const total = expand_len + data.len + 6;
    if (total > values_buf.len) return 0; // bech32 max is well under this
    @memcpy(values_buf[0..expand_len], expand_buf[0..expand_len]);
    @memcpy(values_buf[expand_len..][0..data.len], data);
    for (0..6) |i| values_buf[expand_len + data.len + i] = 0;

    return polymod(values_buf[0..total]) ^ 1;
}

fn verifyChecksum(hrp: []const u8, data: []const u5) bool {
    var expand_buf: [128]u5 = undefined;
    for (hrp, 0..) |c, i| expand_buf[i] = @intCast(c >> 5);
    expand_buf[hrp.len] = 0;
    for (hrp, 0..) |c, i| expand_buf[hrp.len + 1 + i] = @intCast(c & 0x1f);
    const expand_len = hrp.len * 2 + 1;

    var values_buf: [1024]u5 = undefined;
    const total = expand_len + data.len;
    if (total > values_buf.len) return false;
    @memcpy(values_buf[0..expand_len], expand_buf[0..expand_len]);
    @memcpy(values_buf[expand_len..][0..data.len], data);

    return polymod(values_buf[0..total]) == 1;
}

/// Convert `data` from `from_bits` to `to_bits` bit groups, optionally padding.
fn convertBits(allocator: Allocator, data: anytype, from_bits: u4, to_bits: u4, pad: bool) ![]u8 {
    var acc: u32 = 0;
    var bits: u4 = 0;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const max_v: u32 = (@as(u32, 1) << to_bits) - 1;
    for (data) |b| {
        acc = (acc << from_bits) | @as(u32, b);
        bits += from_bits;
        while (bits >= to_bits) {
            bits -= to_bits;
            try out.append(allocator, @intCast((acc >> bits) & max_v));
        }
    }
    if (pad) {
        if (bits > 0) {
            try out.append(allocator, @intCast((acc << (to_bits - bits)) & max_v));
        }
    } else if (bits >= from_bits or (acc << (to_bits - bits)) & max_v != 0) {
        return error.InvalidBech32;
    }
    return out.toOwnedSlice(allocator);
}

// Special-case overload: we need to call convertBits on a slice of u5 too.
// Zig comptime would handle this generically, but the easier path here is to
// keep the parameter as `anytype` and let the compiler instantiate per call.

// ===========================================================================
// Tests
// ===========================================================================

test "encode/decode npub round trip" {
    const allocator = std.testing.allocator;

    // Pubkey from NIP-19 examples (NIP-19 spec text).
    const pk_hex = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d";
    var pk: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        pk[i] = std.fmt.parseUnsigned(u8, pk_hex[i * 2 ..][0..2], 16) catch unreachable;
    }

    const encoded = try encode32(allocator, .npub, pk);
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings(
        "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6",
        encoded,
    );

    const back = try decode32(encoded);
    try std.testing.expectEqual(Kind.npub, back.kind);
    try std.testing.expectEqualSlices(u8, &pk, &back.data);
}

test "encode/decode nsec round trip with synthetic key" {
    const allocator = std.testing.allocator;

    var sk: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) sk[i] = @intCast(i + 1);

    const encoded = try encode32(allocator, .nsec, sk);
    defer allocator.free(encoded);
    try std.testing.expect(std.mem.startsWith(u8, encoded, "nsec1"));

    const back = try decode32(encoded);
    try std.testing.expectEqual(Kind.nsec, back.kind);
    try std.testing.expectEqualSlices(u8, &sk, &back.data);
}

test "decode32 rejects bad checksum" {
    const allocator = std.testing.allocator;
    var sk: [32]u8 = undefined;
    @memset(&sk, 0xAA);
    const good = try encode32(allocator, .npub, sk);
    defer allocator.free(good);

    // Flip a char near the end.
    const bad = try allocator.dupe(u8, good);
    defer allocator.free(bad);
    bad[bad.len - 1] = if (bad[bad.len - 1] == 'q') 'p' else 'q';

    try std.testing.expectError(error.BadChecksum, decode32(bad));
}

test "decode32 rejects unknown HRP" {
    const allocator = std.testing.allocator;
    // Build a valid bech32 string under HRP "xyz" so checksum is good but
    // decode32 should reject the HRP itself.
    var data: [32]u8 = undefined;
    @memset(&data, 0x55);
    const encoded = try encodeRaw(allocator, "xyz", &data);
    defer allocator.free(encoded);
    try std.testing.expectError(error.BadHrp, decode32(encoded));
}

test "decode32 rejects mixed case" {
    try std.testing.expectError(
        error.InvalidBech32,
        decode32("npub180CVV07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"),
    );
}
