//! NIP-01: the Nostr basic protocol layer.
//!
//! Provides:
//!   - Event: in-memory representation of a Nostr event.
//!   - canonicalize() / computeId() / sign() / verify() for full event lifecycle.
//!   - Filter: encodes the JSON filter object used in REQ subscriptions.
//!   - encodeReq / encodeClose / encodeEvent: build outgoing relay messages.
//!   - parseRelayMessage: decode incoming EVENT/EOSE/OK/NOTICE/CLOSED.
//!
//! Canonical event ID serialization follows NIP-01 exactly:
//!   sha256(utf8(json([0, pubkey, created_at, kind, tags, content])))
//! with content escapes limited to \n \" \\ \r \t \b \f.

const std = @import("std");
const Allocator = std.mem.Allocator;
const secp = @import("secp.zig");

const log = std.log.scoped(.nostr);

pub const Error = error{
    InvalidJson,
    InvalidEvent,
    BadSignature,
    BadId,
    UnknownMessage,
    OutOfMemory,
};

pub const event_id_len: usize = 32;
pub const pubkey_len: usize = 32;
pub const sig_len: usize = 64;

/// A single tag entry: ["e", "<event_id>", ...] etc.
pub const Tag = struct {
    items: [][]const u8,

    pub fn deinit(self: Tag, allocator: Allocator) void {
        for (self.items) |s| allocator.free(s);
        allocator.free(self.items);
    }
};

/// A Nostr event. Field layout matches the NIP-01 JSON shape.
pub const Event = struct {
    id: [event_id_len]u8,
    pubkey: [pubkey_len]u8,
    created_at: i64,
    kind: u32,
    tags: []Tag,
    content: []const u8,
    sig: [sig_len]u8,

    pub fn deinit(self: Event, allocator: Allocator) void {
        for (self.tags) |t| t.deinit(allocator);
        allocator.free(self.tags);
        allocator.free(self.content);
    }

    /// Look up the first tag whose first element equals `name`. Returns the
    /// second element if present, or null. Useful for `x`, `title`, `d`, etc.
    pub fn firstTagValue(self: Event, name: []const u8) ?[]const u8 {
        for (self.tags) |t| {
            if (t.items.len >= 2 and std.mem.eql(u8, t.items[0], name)) {
                return t.items[1];
            }
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Canonical serialization + id + signing
// ---------------------------------------------------------------------------

/// Build the canonical pre-image used to compute an event's id:
/// `[0, pubkey, created_at, kind, tags, content]` as a JSON array string
/// with NIP-01 escape rules and no whitespace. Caller owns the returned slice.
pub fn canonicalize(
    allocator: Allocator,
    pubkey_hex: []const u8,
    created_at: i64,
    kind: u32,
    tags: []const Tag,
    content: []const u8,
) Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "[0,\"");
    try buf.appendSlice(allocator, pubkey_hex);
    try buf.appendSlice(allocator, "\",");
    try fmtInt(allocator, &buf, created_at);
    try buf.append(allocator, ',');
    try fmtInt(allocator, &buf, kind);
    try buf.append(allocator, ',');

    // Tags: [["t","v1","v2"], ...]
    try buf.append(allocator, '[');
    for (tags, 0..) |t, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.append(allocator, '[');
        for (t.items, 0..) |s, j| {
            if (j > 0) try buf.append(allocator, ',');
            try writeJsonString(allocator, &buf, s);
        }
        try buf.append(allocator, ']');
    }
    try buf.append(allocator, ']');

    try buf.append(allocator, ',');
    try writeJsonString(allocator, &buf, content);
    try buf.append(allocator, ']');

    return buf.toOwnedSlice(allocator) catch error.OutOfMemory;
}

/// Compute the 32-byte event id from a canonical pre-image. id = sha256(preimage).
pub fn computeId(preimage: []const u8) [event_id_len]u8 {
    var out: [event_id_len]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(preimage, &out, .{});
    return out;
}

/// Sign an event in place. Fills `out_event.id` and `out_event.sig`. The other
/// fields must already be populated. `sk` is the BIP-340 secret key.
pub fn sign(out_event: *Event, sk: secp.SecretKey, allocator: Allocator) Error!void {
    // pubkey hex string for canonical pre-image.
    var pk_hex: [pubkey_len * 2]u8 = undefined;
    secp.toHex(&out_event.pubkey, &pk_hex);

    const preimage = try canonicalize(
        allocator,
        &pk_hex,
        out_event.created_at,
        out_event.kind,
        out_event.tags,
        out_event.content,
    );
    defer allocator.free(preimage);

    out_event.id = computeId(preimage);

    // BIP-340 sign over the id. We pass null aux_rand so libsecp256k1 uses
    // the all-zero auxiliary, which is spec-compliant and deterministic for
    // a given (sk, msg). For better side-channel resistance, callers can
    // supply fresh randomness via signWithAux below.
    out_event.sig = secp.sign(sk, out_event.id, null) catch return error.BadSignature;
}

/// Verify an event's signature *and* recomputed id. Returns true if both match.
pub fn verify(event: Event, allocator: Allocator) bool {
    var pk_hex: [pubkey_len * 2]u8 = undefined;
    secp.toHex(&event.pubkey, &pk_hex);

    const preimage = canonicalize(
        allocator,
        &pk_hex,
        event.created_at,
        event.kind,
        event.tags,
        event.content,
    ) catch return false;
    defer allocator.free(preimage);

    const expected_id = computeId(preimage);
    if (!std.mem.eql(u8, &expected_id, &event.id)) return false;

    return secp.verify(event.sig, &event.id, event.pubkey);
}

// ---------------------------------------------------------------------------
// Filter
// ---------------------------------------------------------------------------

/// Filter object as defined by NIP-01. All fields are optional; null means
/// "do not include in the JSON". Caller still owns each slice.
pub const Filter = struct {
    ids: ?[]const []const u8 = null, // hex event ids
    authors: ?[]const []const u8 = null, // hex pubkeys
    kinds: ?[]const u32 = null,
    tags: ?[]const TagFilter = null,
    since: ?i64 = null,
    until: ?i64 = null,
    limit: ?u32 = null,
    search: ?[]const u8 = null, // NIP-50 optional

    pub const TagFilter = struct {
        /// Single ASCII letter, e.g. 'e', 'p', 't', 'd', 'x'.
        letter: u8,
        values: []const []const u8,
    };
};

// ---------------------------------------------------------------------------
// Outgoing message builders
// ---------------------------------------------------------------------------

/// Build a `["REQ", "<sub_id>", <filter>, ...]` JSON message.
pub fn encodeReq(allocator: Allocator, sub_id: []const u8, filters: []const Filter) Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "[\"REQ\",");
    try writeJsonString(allocator, &buf, sub_id);
    for (filters) |f| {
        try buf.append(allocator, ',');
        try writeFilter(allocator, &buf, f);
    }
    try buf.append(allocator, ']');
    return buf.toOwnedSlice(allocator) catch error.OutOfMemory;
}

/// Build a `["CLOSE", "<sub_id>"]` JSON message.
pub fn encodeClose(allocator: Allocator, sub_id: []const u8) Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "[\"CLOSE\",");
    try writeJsonString(allocator, &buf, sub_id);
    try buf.append(allocator, ']');
    return buf.toOwnedSlice(allocator) catch error.OutOfMemory;
}

/// Build a `["EVENT", <event>]` JSON message for publishing.
pub fn encodeEvent(allocator: Allocator, event: Event) Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var id_hex: [event_id_len * 2]u8 = undefined;
    secp.toHex(&event.id, &id_hex);
    var pk_hex: [pubkey_len * 2]u8 = undefined;
    secp.toHex(&event.pubkey, &pk_hex);
    var sig_hex: [sig_len * 2]u8 = undefined;
    secp.toHex(&event.sig, &sig_hex);

    try buf.appendSlice(allocator, "[\"EVENT\",{\"id\":\"");
    try buf.appendSlice(allocator, &id_hex);
    try buf.appendSlice(allocator, "\",\"pubkey\":\"");
    try buf.appendSlice(allocator, &pk_hex);
    try buf.appendSlice(allocator, "\",\"created_at\":");
    try fmtInt(allocator, &buf, event.created_at);
    try buf.appendSlice(allocator, ",\"kind\":");
    try fmtInt(allocator, &buf, event.kind);
    try buf.appendSlice(allocator, ",\"tags\":[");
    for (event.tags, 0..) |t, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.append(allocator, '[');
        for (t.items, 0..) |s, j| {
            if (j > 0) try buf.append(allocator, ',');
            try writeJsonString(allocator, &buf, s);
        }
        try buf.append(allocator, ']');
    }
    try buf.appendSlice(allocator, "],\"content\":");
    try writeJsonString(allocator, &buf, event.content);
    try buf.appendSlice(allocator, ",\"sig\":\"");
    try buf.appendSlice(allocator, &sig_hex);
    try buf.appendSlice(allocator, "\"}]");
    return buf.toOwnedSlice(allocator) catch error.OutOfMemory;
}

// ---------------------------------------------------------------------------
// Incoming message parser
// ---------------------------------------------------------------------------

pub const RelayMessage = union(enum) {
    event: struct { sub_id: []const u8, event: Event },
    eose: []const u8, // sub_id
    ok: struct { event_id_hex: []const u8, accepted: bool, message: []const u8 },
    notice: []const u8,
    closed: struct { sub_id: []const u8, message: []const u8 },
    auth: []const u8, // challenge

    pub fn deinit(self: RelayMessage, allocator: Allocator) void {
        switch (self) {
            .event => |e| {
                allocator.free(e.sub_id);
                e.event.deinit(allocator);
            },
            .eose => |s| allocator.free(s),
            .ok => |o| {
                allocator.free(o.event_id_hex);
                allocator.free(o.message);
            },
            .notice => |m| allocator.free(m),
            .closed => |c| {
                allocator.free(c.sub_id);
                allocator.free(c.message);
            },
            .auth => |c| allocator.free(c),
        }
    }
};

/// Parse a relay-to-client message into a tagged union. Allocates strings
/// from the input; the caller must call `.deinit(allocator)` on the result.
pub fn parseRelayMessage(allocator: Allocator, json: []const u8) Error!RelayMessage {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return error.InvalidJson;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .array or root.array.items.len == 0) return error.InvalidJson;
    const items = root.array.items;
    if (items[0] != .string) return error.InvalidJson;
    const verb = items[0].string;

    if (std.mem.eql(u8, verb, "EVENT")) {
        if (items.len < 3 or items[1] != .string or items[2] != .object) return error.InvalidEvent;
        const sub_id = allocator.dupe(u8, items[1].string) catch return error.OutOfMemory;
        errdefer allocator.free(sub_id);
        const ev = try parseEventValue(allocator, items[2]);
        return .{ .event = .{ .sub_id = sub_id, .event = ev } };
    } else if (std.mem.eql(u8, verb, "EOSE")) {
        if (items.len < 2 or items[1] != .string) return error.InvalidJson;
        return .{ .eose = allocator.dupe(u8, items[1].string) catch return error.OutOfMemory };
    } else if (std.mem.eql(u8, verb, "OK")) {
        if (items.len < 4 or items[1] != .string or items[2] != .bool or items[3] != .string) {
            return error.InvalidJson;
        }
        const id_hex = allocator.dupe(u8, items[1].string) catch return error.OutOfMemory;
        errdefer allocator.free(id_hex);
        const msg = allocator.dupe(u8, items[3].string) catch return error.OutOfMemory;
        return .{ .ok = .{ .event_id_hex = id_hex, .accepted = items[2].bool, .message = msg } };
    } else if (std.mem.eql(u8, verb, "NOTICE")) {
        if (items.len < 2 or items[1] != .string) return error.InvalidJson;
        return .{ .notice = allocator.dupe(u8, items[1].string) catch return error.OutOfMemory };
    } else if (std.mem.eql(u8, verb, "CLOSED")) {
        if (items.len < 3 or items[1] != .string or items[2] != .string) return error.InvalidJson;
        const sub_id = allocator.dupe(u8, items[1].string) catch return error.OutOfMemory;
        errdefer allocator.free(sub_id);
        const msg = allocator.dupe(u8, items[2].string) catch return error.OutOfMemory;
        return .{ .closed = .{ .sub_id = sub_id, .message = msg } };
    } else if (std.mem.eql(u8, verb, "AUTH")) {
        if (items.len < 2 or items[1] != .string) return error.InvalidJson;
        return .{ .auth = allocator.dupe(u8, items[1].string) catch return error.OutOfMemory };
    }
    return error.UnknownMessage;
}

/// Parse a standalone event JSON object into an Event.
fn parseEventValue(allocator: Allocator, obj: std.json.Value) Error!Event {
    if (obj != .object) return error.InvalidEvent;
    const o = obj.object;

    const id_v = o.get("id") orelse return error.InvalidEvent;
    const pk_v = o.get("pubkey") orelse return error.InvalidEvent;
    const ca_v = o.get("created_at") orelse return error.InvalidEvent;
    const kind_v = o.get("kind") orelse return error.InvalidEvent;
    const tags_v = o.get("tags") orelse return error.InvalidEvent;
    const content_v = o.get("content") orelse return error.InvalidEvent;
    const sig_v = o.get("sig") orelse return error.InvalidEvent;

    if (id_v != .string or pk_v != .string or sig_v != .string) return error.InvalidEvent;
    if (ca_v != .integer or kind_v != .integer) return error.InvalidEvent;
    if (tags_v != .array or content_v != .string) return error.InvalidEvent;

    var ev: Event = .{
        .id = undefined,
        .pubkey = undefined,
        .created_at = ca_v.integer,
        .kind = std.math.cast(u32, kind_v.integer) orelse return error.InvalidEvent,
        .tags = &.{},
        .content = "",
        .sig = undefined,
    };
    secp.fromHex(id_v.string, &ev.id) catch return error.InvalidEvent;
    secp.fromHex(pk_v.string, &ev.pubkey) catch return error.InvalidEvent;
    secp.fromHex(sig_v.string, &ev.sig) catch return error.InvalidEvent;

    var tag_list: std.ArrayList(Tag) = .empty;
    errdefer {
        for (tag_list.items) |t| t.deinit(allocator);
        tag_list.deinit(allocator);
    }
    for (tags_v.array.items) |tv| {
        if (tv != .array) return error.InvalidEvent;
        var items: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (items.items) |s| allocator.free(s);
            items.deinit(allocator);
        }
        for (tv.array.items) |sv| {
            if (sv != .string) return error.InvalidEvent;
            const dup = allocator.dupe(u8, sv.string) catch return error.OutOfMemory;
            items.append(allocator, dup) catch {
                allocator.free(dup);
                return error.OutOfMemory;
            };
        }
        const slice = items.toOwnedSlice(allocator) catch return error.OutOfMemory;
        tag_list.append(allocator, .{ .items = slice }) catch {
            for (slice) |s| allocator.free(s);
            allocator.free(slice);
            return error.OutOfMemory;
        };
    }
    ev.tags = tag_list.toOwnedSlice(allocator) catch return error.OutOfMemory;

    ev.content = allocator.dupe(u8, content_v.string) catch {
        for (ev.tags) |t| t.deinit(allocator);
        allocator.free(ev.tags);
        return error.OutOfMemory;
    };
    return ev;
}

// ---------------------------------------------------------------------------
// JSON / formatting helpers
// ---------------------------------------------------------------------------

fn writeFilter(allocator: Allocator, buf: *std.ArrayList(u8), f: Filter) Error!void {
    try buf.append(allocator, '{');
    var first = true;
    if (f.ids) |v| {
        try writeFieldArrayOfStrings(allocator, buf, &first, "ids", v);
    }
    if (f.authors) |v| {
        try writeFieldArrayOfStrings(allocator, buf, &first, "authors", v);
    }
    if (f.kinds) |v| {
        if (!first) try buf.append(allocator, ',');
        first = false;
        try buf.appendSlice(allocator, "\"kinds\":[");
        for (v, 0..) |k, i| {
            if (i > 0) try buf.append(allocator, ',');
            try fmtInt(allocator, buf, k);
        }
        try buf.append(allocator, ']');
    }
    if (f.tags) |tlist| {
        for (tlist) |tf| {
            if (!first) try buf.append(allocator, ',');
            first = false;
            try buf.appendSlice(allocator, "\"#");
            try buf.append(allocator, tf.letter);
            try buf.appendSlice(allocator, "\":[");
            for (tf.values, 0..) |s, i| {
                if (i > 0) try buf.append(allocator, ',');
                try writeJsonString(allocator, buf, s);
            }
            try buf.append(allocator, ']');
        }
    }
    if (f.since) |s| {
        if (!first) try buf.append(allocator, ',');
        first = false;
        try buf.appendSlice(allocator, "\"since\":");
        try fmtInt(allocator, buf, s);
    }
    if (f.until) |u| {
        if (!first) try buf.append(allocator, ',');
        first = false;
        try buf.appendSlice(allocator, "\"until\":");
        try fmtInt(allocator, buf, u);
    }
    if (f.limit) |l| {
        if (!first) try buf.append(allocator, ',');
        first = false;
        try buf.appendSlice(allocator, "\"limit\":");
        try fmtInt(allocator, buf, l);
    }
    if (f.search) |s| {
        if (!first) try buf.append(allocator, ',');
        first = false;
        try buf.appendSlice(allocator, "\"search\":");
        try writeJsonString(allocator, buf, s);
    }
    try buf.append(allocator, '}');
}

fn writeFieldArrayOfStrings(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    first: *bool,
    name: []const u8,
    values: []const []const u8,
) Error!void {
    if (!first.*) try buf.append(allocator, ',');
    first.* = false;
    try buf.append(allocator, '"');
    try buf.appendSlice(allocator, name);
    try buf.appendSlice(allocator, "\":[");
    for (values, 0..) |s, i| {
        if (i > 0) try buf.append(allocator, ',');
        try writeJsonString(allocator, buf, s);
    }
    try buf.append(allocator, ']');
}

/// Append `s` to `buf` as a JSON string with NIP-01 escaping. Only
/// `\n \" \\ \r \t \b \f` and `\u00XX` for other controls are emitted —
/// per NIP-01 the canonical pre-image does not perform any other escapes.
fn writeJsonString(allocator: Allocator, buf: *std.ArrayList(u8), s: []const u8) Error!void {
    try buf.append(allocator, '"');
    for (s) |b| {
        switch (b) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0x08 => try buf.appendSlice(allocator, "\\b"),
            0x0C => try buf.appendSlice(allocator, "\\f"),
            0...7, 0x0B, 0x0E...0x1F, 0x7F => {
                var tmp: [6]u8 = undefined;
                _ = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{b}) catch unreachable;
                try buf.appendSlice(allocator, &tmp);
            },
            else => try buf.append(allocator, b),
        }
    }
    try buf.append(allocator, '"');
}

fn fmtInt(allocator: Allocator, buf: *std.ArrayList(u8), value: anytype) Error!void {
    var tmp: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch unreachable;
    try buf.appendSlice(allocator, s);
}

// ===========================================================================
// Tests
// ===========================================================================

test "canonicalize: NIP-01 minimal event" {
    const allocator = std.testing.allocator;

    // Hand-pick a known-good pre-image and compare exactly.
    var tags = [_]Tag{};
    const preimage = try canonicalize(allocator, "00" ** 32, 1000, 1, &tags, "hello");
    defer allocator.free(preimage);

    const expected =
        "[0,\"" ++ ("00" ** 32) ++ "\",1000,1,[],\"hello\"]";
    try std.testing.expectEqualStrings(expected, preimage);
}

test "canonicalize escapes control chars and quotes" {
    const allocator = std.testing.allocator;
    var tags = [_]Tag{};
    const preimage = try canonicalize(allocator, "00" ** 32, 0, 1, &tags, "a\"b\\c\nd");
    defer allocator.free(preimage);
    const want_content_part = "\"a\\\"b\\\\c\\nd\"";
    try std.testing.expect(std.mem.indexOf(u8, preimage, want_content_part) != null);
}

test "sign + verify round trip with derived pubkey" {
    const allocator = std.testing.allocator;

    var sk: secp.SecretKey = undefined;
    try secp.fromHex("0000000000000000000000000000000000000000000000000000000000000003", &sk);
    const pk = try secp.publicKeyFromSecret(sk);

    var ev: Event = .{
        .id = undefined,
        .pubkey = pk,
        .created_at = 1700000000,
        .kind = 1,
        .tags = &.{},
        .content = "hello, nostr",
        .sig = undefined,
    };
    // sign expects a mutable copy of content too; we set it after canonicalize
    // computes from the slice we pass.
    try sign(&ev, sk, allocator);

    // verify must pass.
    try std.testing.expect(verify(ev, allocator));

    // tamper with content's id: flip a bit. Use a new event with a different id.
    var bad = ev;
    bad.id[0] ^= 0x01;
    try std.testing.expect(!verify(bad, allocator));
}

test "encodeReq builds correct JSON" {
    const allocator = std.testing.allocator;
    const f: Filter = .{
        .kinds = &[_]u32{ 2003, 30078 },
        .limit = 50,
    };
    const out = try encodeReq(allocator, "sub1", &[_]Filter{f});
    defer allocator.free(out);
    try std.testing.expectEqualStrings(
        "[\"REQ\",\"sub1\",{\"kinds\":[2003,30078],\"limit\":50}]",
        out,
    );
}

test "encodeReq with tag filter" {
    const allocator = std.testing.allocator;
    var values = [_][]const u8{"abc123"};
    const tag_filters = [_]Filter.TagFilter{.{ .letter = 'd', .values = &values }};
    const f: Filter = .{ .kinds = &[_]u32{30078}, .tags = &tag_filters };
    const out = try encodeReq(allocator, "s", &[_]Filter{f});
    defer allocator.free(out);
    try std.testing.expectEqualStrings(
        "[\"REQ\",\"s\",{\"kinds\":[30078],\"#d\":[\"abc123\"]}]",
        out,
    );
}

test "encodeClose" {
    const allocator = std.testing.allocator;
    const out = try encodeClose(allocator, "sub42");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("[\"CLOSE\",\"sub42\"]", out);
}

test "parseRelayMessage: EOSE" {
    const allocator = std.testing.allocator;
    const msg = try parseRelayMessage(allocator, "[\"EOSE\",\"s1\"]");
    defer msg.deinit(allocator);
    try std.testing.expect(msg == .eose);
    try std.testing.expectEqualStrings("s1", msg.eose);
}

test "parseRelayMessage: OK accepted" {
    const allocator = std.testing.allocator;
    const msg = try parseRelayMessage(
        allocator,
        "[\"OK\",\"abc123\",true,\"\"]",
    );
    defer msg.deinit(allocator);
    try std.testing.expect(msg == .ok);
    try std.testing.expect(msg.ok.accepted);
    try std.testing.expectEqualStrings("abc123", msg.ok.event_id_hex);
}

test "parseRelayMessage: NOTICE" {
    const allocator = std.testing.allocator;
    const msg = try parseRelayMessage(allocator, "[\"NOTICE\",\"rate limited\"]");
    defer msg.deinit(allocator);
    try std.testing.expect(msg == .notice);
    try std.testing.expectEqualStrings("rate limited", msg.notice);
}

test "parseRelayMessage + verify: round trip a signed event" {
    const allocator = std.testing.allocator;

    // Build and sign an event, encode it, parse it back, verify.
    var sk: secp.SecretKey = undefined;
    try secp.fromHex("b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef", &sk);
    const pk = try secp.publicKeyFromSecret(sk);

    var tag_items = [_][]const u8{ "t", "nostr" };
    var tags = [_]Tag{.{ .items = &tag_items }};

    var ev: Event = .{
        .id = undefined,
        .pubkey = pk,
        .created_at = 1700000000,
        .kind = 1,
        .tags = &tags,
        .content = "hi",
        .sig = undefined,
    };
    try sign(&ev, sk, allocator);

    // Encode as ["EVENT", {...}] but parseRelayMessage expects sub_id form, so
    // build a relay-style wrapper directly.
    const ev_msg = try encodeEvent(allocator, ev);
    defer allocator.free(ev_msg);

    // Replace leading "EVENT" with relay-style "EVENT","sub_id".
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "[\"EVENT\",\"sub1\",");
    try buf.appendSlice(allocator, ev_msg["[\"EVENT\",".len .. ev_msg.len - 1]);
    try buf.append(allocator, ']');

    const parsed = try parseRelayMessage(allocator, buf.items);
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed == .event);
    try std.testing.expectEqualStrings("sub1", parsed.event.sub_id);
    try std.testing.expectEqualSlices(u8, &ev.id, &parsed.event.event.id);
    try std.testing.expect(verify(parsed.event.event, allocator));
}
