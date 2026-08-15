//! Daemon API contract: the JSON shapes the desktop GUI consumes.
//!
//! These structs mirror the design prototype's data model (the `data.jsx`
//! fixture in the Claude Design handoff) so the Tauri/React frontend can be
//! built against a frozen contract. The full contract is documented in
//! `docs/daemon-api.md`.
//!
//! Serialization is hand-rolled with `std.ArrayList(u8)` (the same pattern as
//! `nostr.zig`'s `encodeEvent`) rather than `std.json.stringify`, so field
//! names and number formatting are explicit and stable.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// How a transfer's traffic is routed. The single most important privacy axis,
/// surfaced on every transfer in the UI.
pub const Route = enum {
    direct,
    proxy,
    tor,
    /// Native I2P transport via the SAM v3 bridge (see src/i2p_sam.zig).
    i2p,

    pub fn jsonName(self: Route) []const u8 {
        return @tagName(self);
    }

    pub fn parse(s: []const u8) ?Route {
        return std.meta.stringToEnum(Route, s);
    }

    /// True when this route tunnels TCP through the configured SOCKS endpoint.
    /// `direct` doesn't tunnel at all; `i2p` uses the SAM bridge, not SOCKS, so
    /// SOCKS health/probing and relay-over-SOCKS logic must skip it too — a
    /// single gate keeps every call site in lockstep.
    pub fn usesSocks(self: Route) bool {
        return self == .proxy or self == .tor;
    }
};

/// Lifecycle state of a transfer. Drives the status pill in the UI.
pub const Status = enum {
    downloading,
    seeding,
    complete,
    metadata,
    stalled,
    /// Anonymized/bootstrap window: no peers yet, but it's early — still trying.
    connecting,
    /// No peers found after the bootstrap window — the transfer can't progress.
    no_peers,

    pub fn jsonName(self: Status) []const u8 {
        return @tagName(self);
    }
};

/// A peer-discovery source. Distinct from `Route`: a transfer can use several.
pub const SourceKind = enum {
    tracker,
    dht,
    nostr,

    pub fn jsonName(self: SourceKind) []const u8 {
        return @tagName(self);
    }
};

/// One row in the Transfers list. Lifetimes: all slices are borrowed from the
/// owner that built the value (the manager snapshot owns its backing buffers
/// and frees them together), so `Transfer` itself has no `deinit`.
pub const Transfer = struct {
    id: []const u8,
    name: []const u8,
    /// info-hash, lowercase hex (40 chars), or empty if not yet known.
    hash: []const u8,
    magnet: []const u8,
    status: Status,
    route: Route,
    sources: []const SourceKind,
    /// 0..100 completion percentage.
    pct: u8,
    /// Total size in bytes; null until metadata is known (magnet bootstrap).
    size: ?u64,
    /// Instantaneous download / upload rate, bytes per second.
    down: u64,
    up: u64,
    /// Human-readable ETA ("1m 48s", "—", "stalled").
    eta: []const u8,
    peers: u32,
    seeds: u32,
    /// BEP 9 metadata pieces received / total during the magnet bootstrap phase.
    /// Both 0 once the info dict is in, or for a non-magnet source. Lets the UI
    /// show "fetching metadata · have/total" instead of an opaque spinner.
    meta_have: u32 = 0,
    meta_total: u32 = 0,
    /// Upload/download ratio; null while still downloading.
    ratio: ?f64 = null,
    /// .onion address when seeding as a hidden service; null otherwise.
    onion: ?[]const u8 = null,
    /// Per-file rows for the Files detail tab. Populated from the session's
    /// published file snapshot (1 Hz from maintenance). Empty for magnet
    /// torrents until metadata resolves.
    file_rows: []const FileEntry = &.{},
    peer_rows: []const Peer = &.{},
    /// Per-source rows for the Sources detail tab. Populated from the
    /// session's Progress snapshot (tracker seeders/leechers, DHT node count).
    source_rows: []const Source = &.{},
};

/// One peer in a transfer's Peers detail tab.
pub const Peer = struct {
    addr: []const u8,
    port: u16,
    client: []const u8,
    down: u64,
    up: u64,
    pct: u8,
    /// BEP-style flag string ("DUE", "DU", ...).
    flags: []const u8,
    onion: bool = false,
};

/// One file in a transfer's Files detail tab.
pub const FileEntry = struct {
    name: []const u8,
    size: u64,
    pct: u8,
    /// "normal" | "high" | "skip"
    prio: []const u8 = "normal",
};

/// One peer-discovery source row in the Sources detail tab.
pub const Source = struct {
    kind: SourceKind,
    label: []const u8,
    state: []const u8,
    detail: []const u8,
    interval: []const u8 = "—",
};

/// A Nostr (NIP-35) search result card in Discover.
pub const DiscoverResult = struct {
    id: []const u8,
    title: []const u8,
    hash: []const u8,
    size: u64,
    files: u32,
    trackers: u32,
    desc: []const u8,
    verified: bool,
    relays: []const []const u8,
    author: []const u8,
    age: []const u8,
};

/// A configured Nostr relay and its connection state.
pub const Relay = struct {
    url: []const u8,
    /// "connected" | "connecting" | "unreachable" | "configured"
    state: []const u8,
    /// "clearnet" | "tor"
    net: []const u8,
    events: u64 = 0,
};

/// Health of the configured SOCKS proxy on the proxy/tor route, so the UI and
/// logs can say *why* the route isn't working (Tor down / timeout / rejected)
/// instead of silently failing. Probed by the daemon's background prober.
pub const ProxyHealth = struct {
    /// "disabled" (direct route) | "checking" (before first probe) |
    /// "ok" | "not_running" | "timeout" | "rejected"
    state: []const u8,
    /// The SOCKS endpoint being probed (e.g. "socks5h://127.0.0.1:9050").
    endpoint: []const u8,
    /// Human-readable detail, e.g. the SOCKS5 reply byte for "rejected"; "" otherwise.
    detail: []const u8 = "",
};

/// A file being seeded.
pub const Seed = struct {
    id: []const u8,
    name: []const u8,
    /// matches Route names; "tor" implies an onion address.
    visibility: Route,
    onion: ?[]const u8 = null,
    size: u64,
    up_total: u64,
    up: u64,
    leechers: u32,
    ratio: f64,
    relays: u32 = 0,
};

/// One torrent inside a followed publisher's mirror.
pub const FollowTorrent = struct {
    name: []const u8,
    /// info-hash, lowercase hex (40 chars).
    hash: []const u8,
    /// "starting" | "downloading" | "seeding" | "failed"
    state: []const u8,
    pct: u8,
    peers: u32,
    down: u64,
    up: u64,
};

/// A followed publisher: carl mirrors (downloads + reseeds) everything this
/// pubkey announces via NIP-35. One row in the Following screen.
pub const Follow = struct {
    id: []const u8,
    /// bech32 npub of the followed publisher.
    npub: []const u8,
    route: Route,
    /// Mirror data directory.
    dir: []const u8,
    /// Aggregates over `torrents` (computed by the manager snapshot).
    seeding: u32,
    downloading: u32,
    failed: u32,
    torrents: []const FollowTorrent,
};

/// Local Nostr identity. The secret key (nsec) is NEVER serialized.
pub const Identity = struct {
    /// bech32 npub, or empty if no key is configured.
    npub: []const u8,
};

/// One file inside a shared drive.
pub const DriveFile = struct {
    /// Filename (drives are flat: path == filename == torrent name).
    path: []const u8,
    size: u64,
    /// "starting" | "downloading" | "seeding" | "failed"
    phase: []const u8,
    /// info-hash, lowercase hex (40 chars).
    info_hash: []const u8,
};

/// A shared drive: a flat folder published as one torrent per file (publisher
/// role) or mirrored from a publisher's Nostr drive index (subscriber role).
/// One row in the Drives screen.
pub const Drive = struct {
    id: []const u8,
    /// "publisher" | "subscriber"
    role: []const u8,
    /// Drive name (the `<name>` in the `carl-drive:<name>` d-tag).
    name: []const u8,
    /// Watched folder (publisher) / sync folder (subscriber).
    dir: []const u8,
    route: Route,
    /// bech32 npub of the subscriber's followed author; null for a publisher.
    author: ?[]const u8,
    /// Extra writer npubs (multi-writer subscriptions).
    also: []const []const u8,
    files: []const DriveFile,
    file_count: usize,
};

/// User-facing settings. Mirrors the Settings screen.
pub const Settings = struct {
    route: Route,
    socks: []const u8,
    relays: []const []const u8,
    download_dir: []const u8,
    listen_port: u16,
    max_active: u32,
    peer_limit: u32,
    publish_nip35: bool,
};

// ===========================================================================
// JSON writer
// ===========================================================================

/// Minimal JSON writer over an owned `std.ArrayList(u8)`. Tracks whether a
/// separator is needed between object members / array elements so callers don't
/// have to thread comma bookkeeping by hand.
pub const Json = struct {
    buf: std.ArrayList(u8),
    allocator: Allocator,
    /// Stack of "needs a leading comma before the next item" flags, one per
    /// open object/array. Depth is bounded by the contract's nesting.
    need_comma: [16]bool = [_]bool{false} ** 16,
    depth: usize = 0,

    pub fn init(allocator: Allocator) Json {
        return .{ .buf = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *Json) void {
        self.buf.deinit(self.allocator);
    }

    /// Hand ownership of the serialized bytes to the caller.
    pub fn toOwnedSlice(self: *Json) Allocator.Error![]u8 {
        return self.buf.toOwnedSlice(self.allocator);
    }

    fn sep(self: *Json) Allocator.Error!void {
        if (self.depth > 0 and self.need_comma[self.depth - 1]) {
            try self.buf.append(self.allocator, ',');
        }
        if (self.depth > 0) self.need_comma[self.depth - 1] = true;
    }

    fn push(self: *Json) void {
        if (self.depth < self.need_comma.len) self.need_comma[self.depth] = false;
        self.depth += 1;
    }

    fn pop(self: *Json) void {
        if (self.depth > 0) self.depth -= 1;
    }

    pub fn beginObject(self: *Json) Allocator.Error!void {
        try self.sep();
        try self.buf.append(self.allocator, '{');
        self.push();
    }

    pub fn endObject(self: *Json) Allocator.Error!void {
        try self.buf.append(self.allocator, '}');
        self.pop();
    }

    pub fn beginArray(self: *Json) Allocator.Error!void {
        try self.sep();
        try self.buf.append(self.allocator, '[');
        self.push();
    }

    pub fn endArray(self: *Json) Allocator.Error!void {
        try self.buf.append(self.allocator, ']');
        self.pop();
    }

    /// Write an object key. The next value call supplies its value.
    pub fn key(self: *Json, name: []const u8) Allocator.Error!void {
        try self.sep();
        try self.writeString(name);
        try self.buf.append(self.allocator, ':');
        // A key consumes the separator slot; the value that follows must not
        // emit another comma before itself.
        if (self.depth > 0) self.need_comma[self.depth - 1] = false;
    }

    pub fn string(self: *Json, v: []const u8) Allocator.Error!void {
        try self.sep();
        try self.writeString(v);
    }

    pub fn number(self: *Json, v: anytype) Allocator.Error!void {
        try self.sep();
        var tmp: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
        try self.buf.appendSlice(self.allocator, s);
    }

    /// Floats are emitted with two decimals (ratios, rates) to keep the wire
    /// representation deterministic for the UI.
    pub fn float(self: *Json, v: f64) Allocator.Error!void {
        try self.sep();
        var tmp: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d:.2}", .{v}) catch unreachable;
        try self.buf.appendSlice(self.allocator, s);
    }

    pub fn boolean(self: *Json, v: bool) Allocator.Error!void {
        try self.sep();
        try self.buf.appendSlice(self.allocator, if (v) "true" else "false");
    }

    pub fn nullValue(self: *Json) Allocator.Error!void {
        try self.sep();
        try self.buf.appendSlice(self.allocator, "null");
    }

    /// Convenience: write `"key": "value"`.
    pub fn keyString(self: *Json, name: []const u8, v: []const u8) Allocator.Error!void {
        try self.key(name);
        try self.string(v);
    }

    pub fn keyNumber(self: *Json, name: []const u8, v: anytype) Allocator.Error!void {
        try self.key(name);
        try self.number(v);
    }

    pub fn keyBool(self: *Json, name: []const u8, v: bool) Allocator.Error!void {
        try self.key(name);
        try self.boolean(v);
    }

    fn writeString(self: *Json, s: []const u8) Allocator.Error!void {
        try self.buf.append(self.allocator, '"');
        for (s) |c| {
            switch (c) {
                '"' => try self.buf.appendSlice(self.allocator, "\\\""),
                '\\' => try self.buf.appendSlice(self.allocator, "\\\\"),
                '\n' => try self.buf.appendSlice(self.allocator, "\\n"),
                '\r' => try self.buf.appendSlice(self.allocator, "\\r"),
                '\t' => try self.buf.appendSlice(self.allocator, "\\t"),
                0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                    var tmp: [8]u8 = undefined;
                    const esc = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable;
                    try self.buf.appendSlice(self.allocator, esc);
                },
                else => try self.buf.append(self.allocator, c),
            }
        }
        try self.buf.append(self.allocator, '"');
    }
};

// ===========================================================================
// Serializers — each appends one value to an open Json writer.
// ===========================================================================

fn writeSourceArray(j: *Json, sources: []const SourceKind) Allocator.Error!void {
    try j.beginArray();
    for (sources) |s| try j.string(s.jsonName());
    try j.endArray();
}

fn writeStringArray(j: *Json, items: []const []const u8) Allocator.Error!void {
    try j.beginArray();
    for (items) |s| try j.string(s);
    try j.endArray();
}

pub fn writeTransfer(j: *Json, t: Transfer) Allocator.Error!void {
    try j.beginObject();
    try j.keyString("id", t.id);
    try j.keyString("name", t.name);
    try j.keyString("hash", t.hash);
    try j.keyString("magnet", t.magnet);
    try j.keyString("status", t.status.jsonName());
    try j.keyString("route", t.route.jsonName());
    try j.key("sources");
    try writeSourceArray(j, t.sources);
    try j.keyNumber("pct", t.pct);
    try j.key("size");
    if (t.size) |s| try j.number(s) else try j.nullValue();
    try j.keyNumber("down", t.down);
    try j.keyNumber("up", t.up);
    try j.keyString("eta", t.eta);
    try j.keyNumber("peers", t.peers);
    try j.keyNumber("seeds", t.seeds);
    try j.keyNumber("metaHave", t.meta_have);
    try j.keyNumber("metaTotal", t.meta_total);
    try j.key("ratio");
    if (t.ratio) |r| try j.float(r) else try j.nullValue();
    try j.key("onion");
    if (t.onion) |o| try j.string(o) else try j.nullValue();
    try j.key("fileRows");
    try j.beginArray();
    for (t.file_rows) |fr| try writeFileEntry(j, fr);
    try j.endArray();
    try j.key("peerRows");
    try j.beginArray();
    for (t.peer_rows) |pr| try writePeer(j, pr);
    try j.endArray();
    try j.key("sourceRows");
    try j.beginArray();
    for (t.source_rows) |sr| try writeSource(j, sr);
    try j.endArray();
    try j.endObject();
}

pub fn writePeer(j: *Json, p: Peer) Allocator.Error!void {
    try j.beginObject();
    try j.keyString("addr", p.addr);
    try j.keyNumber("port", p.port);
    try j.keyString("client", p.client);
    try j.keyNumber("down", p.down);
    try j.keyNumber("up", p.up);
    try j.keyNumber("pct", p.pct);
    try j.keyString("flags", p.flags);
    try j.keyBool("onion", p.onion);
    try j.endObject();
}

pub fn writeFileEntry(j: *Json, f: FileEntry) Allocator.Error!void {
    try j.beginObject();
    try j.keyString("name", f.name);
    try j.keyNumber("size", f.size);
    try j.keyNumber("pct", f.pct);
    try j.keyString("prio", f.prio);
    try j.endObject();
}

pub fn writeSource(j: *Json, s: Source) Allocator.Error!void {
    try j.beginObject();
    try j.keyString("kind", s.kind.jsonName());
    try j.keyString("label", s.label);
    try j.keyString("state", s.state);
    try j.keyString("detail", s.detail);
    try j.keyString("interval", s.interval);
    try j.endObject();
}

pub fn writeDiscoverResult(j: *Json, d: DiscoverResult) Allocator.Error!void {
    try j.beginObject();
    try j.keyString("id", d.id);
    try j.keyString("title", d.title);
    try j.keyString("hash", d.hash);
    try j.keyNumber("size", d.size);
    try j.keyNumber("files", d.files);
    try j.keyNumber("trackers", d.trackers);
    try j.keyString("desc", d.desc);
    try j.keyBool("verified", d.verified);
    try j.key("relays");
    try writeStringArray(j, d.relays);
    try j.keyString("author", d.author);
    try j.keyString("age", d.age);
    try j.endObject();
}

pub fn writeRelay(j: *Json, r: Relay) Allocator.Error!void {
    try j.beginObject();
    try j.keyString("url", r.url);
    try j.keyString("state", r.state);
    try j.keyString("net", r.net);
    try j.keyNumber("events", r.events);
    try j.endObject();
}

pub fn writeProxyHealth(j: *Json, h: ProxyHealth) Allocator.Error!void {
    try j.beginObject();
    try j.keyString("state", h.state);
    try j.keyString("endpoint", h.endpoint);
    try j.keyString("detail", h.detail);
    try j.endObject();
}

pub fn writeSeed(j: *Json, s: Seed) Allocator.Error!void {
    try j.beginObject();
    try j.keyString("id", s.id);
    try j.keyString("name", s.name);
    try j.keyString("visibility", s.visibility.jsonName());
    try j.key("onion");
    if (s.onion) |o| try j.string(o) else try j.nullValue();
    try j.keyNumber("size", s.size);
    try j.keyNumber("upTotal", s.up_total);
    try j.keyNumber("up", s.up);
    try j.keyNumber("leechers", s.leechers);
    try j.key("ratio");
    try j.float(s.ratio);
    try j.keyNumber("relays", s.relays);
    try j.endObject();
}

pub fn writeFollowTorrent(j: *Json, t: FollowTorrent) Allocator.Error!void {
    try j.beginObject();
    try j.keyString("name", t.name);
    try j.keyString("hash", t.hash);
    try j.keyString("state", t.state);
    try j.keyNumber("pct", t.pct);
    try j.keyNumber("peers", t.peers);
    try j.keyNumber("down", t.down);
    try j.keyNumber("up", t.up);
    try j.endObject();
}

pub fn writeFollow(j: *Json, f: Follow) Allocator.Error!void {
    try j.beginObject();
    try j.keyString("id", f.id);
    try j.keyString("npub", f.npub);
    try j.keyString("route", f.route.jsonName());
    try j.keyString("dir", f.dir);
    try j.keyNumber("seeding", f.seeding);
    try j.keyNumber("downloading", f.downloading);
    try j.keyNumber("failed", f.failed);
    try j.key("torrents");
    try j.beginArray();
    for (f.torrents) |t| try writeFollowTorrent(j, t);
    try j.endArray();
    try j.endObject();
}

pub fn writeIdentity(j: *Json, id: Identity) Allocator.Error!void {
    try j.beginObject();
    try j.keyString("npub", id.npub);
    try j.endObject();
}

pub fn writeDriveFile(j: *Json, f: DriveFile) Allocator.Error!void {
    try j.beginObject();
    try j.keyString("path", f.path);
    try j.keyNumber("size", f.size);
    try j.keyString("phase", f.phase);
    try j.keyString("info_hash", f.info_hash);
    try j.endObject();
}

/// Serialize one drive's file table as a JSON array.
pub fn writeDriveFiles(j: *Json, files: []const DriveFile) Allocator.Error!void {
    try j.beginArray();
    for (files) |f| try writeDriveFile(j, f);
    try j.endArray();
}

pub fn writeDrive(j: *Json, d: Drive) Allocator.Error!void {
    try j.beginObject();
    try j.keyString("id", d.id);
    try j.keyString("role", d.role);
    try j.keyString("name", d.name);
    try j.keyString("dir", d.dir);
    try j.keyString("route", d.route.jsonName());
    try j.key("author");
    if (d.author) |au| try j.string(au) else try j.nullValue();
    try j.key("also");
    try writeStringArray(j, d.also);
    try j.key("files");
    try writeDriveFiles(j, d.files);
    try j.keyNumber("file_count", d.file_count);
    try j.endObject();
}

pub fn writeSettings(j: *Json, s: Settings) Allocator.Error!void {
    try j.beginObject();
    try j.keyString("route", s.route.jsonName());
    try j.keyString("socks", s.socks);
    try j.key("relays");
    try writeStringArray(j, s.relays);
    try j.keyString("downloadDir", s.download_dir);
    try j.keyNumber("listenPort", s.listen_port);
    try j.keyNumber("maxActive", s.max_active);
    try j.keyNumber("peerLimit", s.peer_limit);
    try j.keyBool("publishNip35", s.publish_nip35);
    try j.endObject();
}

/// Serialize a list of transfers as a JSON array. Caller owns the result.
pub fn transfersJson(allocator: Allocator, transfers: []const Transfer) Allocator.Error![]u8 {
    var j = Json.init(allocator);
    errdefer j.deinit();
    try j.beginArray();
    for (transfers) |t| try writeTransfer(&j, t);
    try j.endArray();
    return j.toOwnedSlice();
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

/// Parse `s` as JSON and assert it succeeds, returning the parsed tree so tests
/// can assert on individual fields. Caller must deinit.
fn parse(allocator: Allocator, s: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, s, .{});
}

test "Json: object with separators is valid and re-parses" {
    const allocator = testing.allocator;
    var j = Json.init(allocator);
    defer j.deinit();
    try j.beginObject();
    try j.keyString("a", "x");
    try j.keyNumber("b", 42);
    try j.keyBool("c", true);
    try j.endObject();

    var p = try parse(allocator, j.buf.items);
    defer p.deinit();
    try testing.expectEqualStrings("x", p.value.object.get("a").?.string);
    try testing.expectEqual(@as(i64, 42), p.value.object.get("b").?.integer);
    try testing.expectEqual(true, p.value.object.get("c").?.bool);
}

test "Json: string escaping" {
    const allocator = testing.allocator;
    var j = Json.init(allocator);
    defer j.deinit();
    try j.beginObject();
    try j.keyString("k", "a\"b\\c\nd\te");
    try j.endObject();

    var p = try parse(allocator, j.buf.items);
    defer p.deinit();
    try testing.expectEqualStrings("a\"b\\c\nd\te", p.value.object.get("k").?.string);
}

test "writeDrive: round-trips through std.json" {
    const allocator = testing.allocator;
    const files = [_]DriveFile{
        .{ .path = "report.pdf", .size = 1024, .phase = "seeding", .info_hash = "ab" ** 20 },
        .{ .path = "notes.txt", .size = 42, .phase = "downloading", .info_hash = "cd" ** 20 },
    };
    const also = [_][]const u8{ "npub1aaa", "npub1bbb" };
    var j = Json.init(allocator);
    defer j.deinit();
    try writeDrive(&j, .{
        .id = "d1",
        .role = "subscriber",
        .name = "docs",
        .dir = "/data/docs",
        .route = .i2p,
        .author = "npub1author",
        .also = &also,
        .files = &files,
        .file_count = 2,
    });

    var p = try parse(allocator, j.buf.items);
    defer p.deinit();
    const o = p.value.object;
    try testing.expectEqualStrings("d1", o.get("id").?.string);
    try testing.expectEqualStrings("subscriber", o.get("role").?.string);
    try testing.expectEqualStrings("docs", o.get("name").?.string);
    try testing.expectEqualStrings("/data/docs", o.get("dir").?.string);
    try testing.expectEqualStrings("i2p", o.get("route").?.string);
    try testing.expectEqualStrings("npub1author", o.get("author").?.string);
    try testing.expectEqual(@as(usize, 2), o.get("also").?.array.items.len);
    try testing.expectEqualStrings("npub1bbb", o.get("also").?.array.items[1].string);
    try testing.expectEqual(@as(i64, 2), o.get("file_count").?.integer);
    const f0 = o.get("files").?.array.items[0].object;
    try testing.expectEqualStrings("report.pdf", f0.get("path").?.string);
    try testing.expectEqual(@as(i64, 1024), f0.get("size").?.integer);
    try testing.expectEqualStrings("seeding", f0.get("phase").?.string);
    try testing.expectEqualStrings("ab" ** 20, f0.get("info_hash").?.string);

    // A publisher serializes author as null and an empty also list.
    var j2 = Json.init(allocator);
    defer j2.deinit();
    try writeDrive(&j2, .{
        .id = "d2",
        .role = "publisher",
        .name = "x",
        .dir = "/y",
        .route = .direct,
        .author = null,
        .also = &.{},
        .files = &.{},
        .file_count = 0,
    });
    var p2 = try parse(allocator, j2.buf.items);
    defer p2.deinit();
    const o2 = p2.value.object;
    try testing.expect(o2.get("author").? == .null);
    try testing.expectEqual(@as(usize, 0), o2.get("also").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), o2.get("files").?.array.items.len);
}

test "writeTransfer: round-trips through std.json" {
    const allocator = testing.allocator;
    const sources = [_]SourceKind{ .tracker, .dht, .nostr };
    const t = Transfer{
        .id = "t1",
        .name = "debian-12.5.0-amd64-netinst.iso",
        .hash = "a1d9f3c2e7b48f10c9a6d2e5f8b3071c4e9a2d6f",
        .magnet = "magnet:?xt=urn:btih:a1d9f3c2",
        .status = .downloading,
        .route = .direct,
        .sources = &sources,
        .pct = 64,
        .size = 658 * 1024 * 1024,
        .down = 4_404_019,
        .up = 262_144,
        .eta = "1m 48s",
        .peers = 38,
        .seeds = 64,
        .ratio = null,
        .onion = null,
    };

    var j = Json.init(allocator);
    defer j.deinit();
    try writeTransfer(&j, t);

    var p = try parse(allocator, j.buf.items);
    defer p.deinit();
    const o = p.value.object;
    try testing.expectEqualStrings("t1", o.get("id").?.string);
    try testing.expectEqualStrings("downloading", o.get("status").?.string);
    try testing.expectEqualStrings("direct", o.get("route").?.string);
    try testing.expectEqual(@as(i64, 64), o.get("pct").?.integer);
    try testing.expectEqual(@as(usize, 3), o.get("sources").?.array.items.len);
    try testing.expectEqualStrings("tracker", o.get("sources").?.array.items[0].string);
    try testing.expectEqual(std.json.Value.null, o.get("ratio").?);
    try testing.expectEqual(std.json.Value.null, o.get("onion").?);
    try testing.expectEqual(@as(i64, 658 * 1024 * 1024), o.get("size").?.integer);
}

test "writeTransfer: optional ratio + onion emit values" {
    const allocator = testing.allocator;
    const sources = [_]SourceKind{.nostr};
    const t = Transfer{
        .id = "t2",
        .name = "archlinux.iso",
        .hash = "7f2b9c4e",
        .magnet = "magnet:?xt=urn:btih:7f2b9c4e",
        .status = .seeding,
        .route = .tor,
        .sources = &sources,
        .pct = 100,
        .size = 1_202_590_842,
        .down = 0,
        .up = 1_887_436,
        .eta = "—",
        .peers = 12,
        .seeds = 0,
        .ratio = 3.41,
        .onion = "g7k3xqp4.onion",
    };
    var j = Json.init(allocator);
    defer j.deinit();
    try writeTransfer(&j, t);

    var p = try parse(allocator, j.buf.items);
    defer p.deinit();
    const o = p.value.object;
    try testing.expectApproxEqAbs(@as(f64, 3.41), o.get("ratio").?.float, 0.001);
    try testing.expectEqualStrings("g7k3xqp4.onion", o.get("onion").?.string);
    try testing.expectEqualStrings("tor", o.get("route").?.string);
}

test "transfersJson: array of transfers" {
    const allocator = testing.allocator;
    const sources = [_]SourceKind{.dht};
    const items = [_]Transfer{
        .{ .id = "a", .name = "n1", .hash = "h1", .magnet = "m1", .status = .downloading, .route = .proxy, .sources = &sources, .pct = 10, .size = null, .down = 1, .up = 2, .eta = "x", .peers = 1, .seeds = 2 },
        .{ .id = "b", .name = "n2", .hash = "h2", .magnet = "m2", .status = .complete, .route = .direct, .sources = &sources, .pct = 100, .size = 99, .down = 0, .up = 0, .eta = "—", .peers = 0, .seeds = 0 },
    };
    const s = try transfersJson(allocator, &items);
    defer allocator.free(s);

    var p = try parse(allocator, s);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 2), p.value.array.items.len);
    try testing.expectEqual(std.json.Value.null, p.value.array.items[0].object.get("size").?);
    try testing.expectEqualStrings("complete", p.value.array.items[1].object.get("status").?.string);
}

test "writeSettings: relays array + camelCase keys" {
    const allocator = testing.allocator;
    const relays = [_][]const u8{ "wss://relay.damus.io", "wss://nos.lol" };
    const s = Settings{
        .route = .tor,
        .socks = "socks5h://127.0.0.1:9050",
        .relays = &relays,
        .download_dir = "~/Downloads/carl",
        .listen_port = 51413,
        .max_active = 8,
        .peer_limit = 60,
        .publish_nip35 = true,
    };
    var j = Json.init(allocator);
    defer j.deinit();
    try writeSettings(&j, s);

    var p = try parse(allocator, j.buf.items);
    defer p.deinit();
    const o = p.value.object;
    try testing.expectEqual(@as(usize, 2), o.get("relays").?.array.items.len);
    try testing.expectEqual(@as(i64, 51413), o.get("listenPort").?.integer);
    try testing.expectEqual(true, o.get("publishNip35").?.bool);
}

test "writeSeed: upTotal camelCase and float ratio" {
    const allocator = testing.allocator;
    const s = Seed{
        .id = "s1",
        .name = "arch.iso",
        .visibility = .tor,
        .onion = "abc.onion",
        .size = 100,
        .up_total = 382,
        .up = 18,
        .leechers = 12,
        .ratio = 3.41,
        .relays = 4,
    };
    var j = Json.init(allocator);
    defer j.deinit();
    try writeSeed(&j, s);

    var p = try parse(allocator, j.buf.items);
    defer p.deinit();
    const o = p.value.object;
    try testing.expectEqual(@as(i64, 382), o.get("upTotal").?.integer);
    try testing.expectApproxEqAbs(@as(f64, 3.41), o.get("ratio").?.float, 0.001);
    try testing.expectEqualStrings("abc.onion", o.get("onion").?.string);
}

test "writeFollow: nested torrents round-trip through std.json" {
    const allocator = testing.allocator;
    const torrents = [_]FollowTorrent{
        .{ .name = "a.bin", .hash = "aa" ** 20, .state = "seeding", .pct = 100, .peers = 2, .down = 0, .up = 1024 },
        .{ .name = "b.bin", .hash = "bb" ** 20, .state = "downloading", .pct = 40, .peers = 1, .down = 2048, .up = 0 },
    };
    const f = Follow{
        .id = "f1",
        .npub = "npub1test",
        .route = .i2p,
        .dir = "/data/follow-abc",
        .seeding = 1,
        .downloading = 1,
        .failed = 0,
        .torrents = &torrents,
    };
    var j = Json.init(allocator);
    defer j.deinit();
    try writeFollow(&j, f);

    var p = try parse(allocator, j.buf.items);
    defer p.deinit();
    const o = p.value.object;
    try testing.expectEqualStrings("npub1test", o.get("npub").?.string);
    try testing.expectEqualStrings("i2p", o.get("route").?.string);
    try testing.expectEqual(@as(i64, 1), o.get("seeding").?.integer);
    const ts = o.get("torrents").?.array.items;
    try testing.expectEqual(@as(usize, 2), ts.len);
    try testing.expectEqualStrings("seeding", ts[0].object.get("state").?.string);
    try testing.expectEqual(@as(i64, 40), ts[1].object.get("pct").?.integer);
}

test "Route.parse round-trips names" {
    try testing.expectEqual(Route.tor, Route.parse("tor").?);
    try testing.expectEqual(Route.proxy, Route.parse("proxy").?);
    try testing.expectEqual(Route.direct, Route.parse("direct").?);
    try testing.expectEqual(@as(?Route, null), Route.parse("bogus"));
}
