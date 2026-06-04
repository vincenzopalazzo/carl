//! Daemon state persistence: the set of transfers/seeds and the editable
//! settings, written to `<config>/daemon-state.json` so a daemon restart
//! resumes exactly where it left off (nothing is lost).
//!
//! Transfers are persisted as *specs* — the minimal recipe to re-create them
//! (source + route + nostr) — not live session state. On restart the manager
//! replays each spec: downloads resume from on-disk pieces (the session
//! re-verifies them) and seeds re-hash their file. Relays already persist via
//! `nostr_config`, so they're not duplicated here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const api = @import("api.zig");
const nostr_config = @import("nostr_config.zig");

const log = std.log.scoped(.state);

pub const Kind = enum {
    download,
    seed,

    fn jsonName(self: Kind) []const u8 {
        return @tagName(self);
    }

    fn parse(s: []const u8) ?Kind {
        return std.meta.stringToEnum(Kind, s);
    }
};

/// The recipe to re-create one transfer on restart.
pub const TransferSpec = struct {
    kind: Kind,
    /// magnet / http URL / .torrent path (download) or file path (seed).
    source: []const u8,
    route: api.Route,
    nostr: bool,
};

pub const State = struct {
    route: api.Route,
    download_dir: []const u8,
    transfers: []const TransferSpec,

    /// Free everything owned by a `State` returned from `load` / `decode`.
    pub fn deinit(self: State, a: Allocator) void {
        a.free(self.download_dir);
        for (self.transfers) |t| a.free(t.source);
        a.free(self.transfers);
    }
};

/// `<config>/daemon-state.json`. Caller owns the returned path.
pub fn statePath(a: Allocator) ![]u8 {
    const dir = try nostr_config.configDir(a);
    defer a.free(dir);
    return std.fmt.allocPrint(a, "{s}/daemon-state.json", .{dir});
}

/// Serialize state to JSON bytes. Caller owns the result.
pub fn encode(
    a: Allocator,
    route: api.Route,
    download_dir: []const u8,
    specs: []const TransferSpec,
) Allocator.Error![]u8 {
    var j = api.Json.init(a);
    errdefer j.deinit();
    try j.beginObject();
    try j.keyString("route", route.jsonName());
    try j.keyString("downloadDir", download_dir);
    try j.key("transfers");
    try j.beginArray();
    for (specs) |s| {
        try j.beginObject();
        try j.keyString("kind", s.kind.jsonName());
        try j.keyString("source", s.source);
        try j.keyString("route", s.route.jsonName());
        try j.keyBool("nostr", s.nostr);
        try j.endObject();
    }
    try j.endArray();
    try j.endObject();
    return j.toOwnedSlice();
}

pub const DecodeError = error{ InvalidJson, OutOfMemory };

/// Parse JSON bytes into an owned `State`. Caller frees via `State.deinit`.
pub fn decode(a: Allocator, bytes: []const u8) DecodeError!State {
    const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJson;
    const root = parsed.value.object;

    const route = api.Route.parse(strField(root, "route") orelse "direct") orelse .direct;
    const download_dir = try a.dupe(u8, strField(root, "downloadDir") orelse "");
    errdefer a.free(download_dir);

    var list: std.ArrayList(TransferSpec) = .empty;
    errdefer {
        for (list.items) |t| a.free(t.source);
        list.deinit(a);
    }
    if (root.get("transfers")) |tv| {
        if (tv == .array) {
            for (tv.array.items) |item| {
                if (item != .object) continue;
                const o = item.object;
                const kind = Kind.parse(strField(o, "kind") orelse "download") orelse .download;
                const src_raw = strField(o, "source") orelse continue;
                const src = try a.dupe(u8, src_raw);
                errdefer a.free(src);
                const r = api.Route.parse(strField(o, "route") orelse "direct") orelse .direct;
                const nostr = if (o.get("nostr")) |nv| (nv == .bool and nv.bool) else false;
                try list.append(a, .{ .kind = kind, .source = src, .route = r, .nostr = nostr });
            }
        }
    }
    return .{
        .route = route,
        .download_dir = download_dir,
        .transfers = try list.toOwnedSlice(a),
    };
}

/// Write the state file (atomically: write a temp file, then rename). Best
/// effort — a failure is logged by the caller, never fatal.
pub fn save(
    a: Allocator,
    route: api.Route,
    download_dir: []const u8,
    specs: []const TransferSpec,
) !void {
    const dir = try nostr_config.ensureConfigDir(a);
    defer a.free(dir);
    const path = try std.fmt.allocPrint(a, "{s}/daemon-state.json", .{dir});
    defer a.free(path);
    const tmp = try std.fmt.allocPrint(a, "{s}.tmp", .{path});
    defer a.free(tmp);

    const bytes = try encode(a, route, download_dir, specs);
    defer a.free(bytes);

    {
        var file = try std.fs.cwd().createFile(tmp, .{ .truncate = true });
        defer file.close();
        try file.writeAll(bytes);
    }
    try std.fs.cwd().rename(tmp, path);
}

/// Load the state file, or null if it doesn't exist yet. Caller frees the
/// returned `State` via `deinit`.
pub fn load(a: Allocator) !?State {
    const path = try statePath(a);
    defer a.free(path);
    const data = std.fs.cwd().readFileAlloc(a, path, 8 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer a.free(data);
    return try decode(a, data);
}

fn strField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "encode/decode round-trips transfers + settings" {
    const a = testing.allocator;
    const specs = [_]TransferSpec{
        .{ .kind = .download, .source = "magnet:?xt=urn:btih:abc", .route = .tor, .nostr = true },
        .{ .kind = .seed, .source = "/data/movie.tar", .route = .direct, .nostr = false },
    };
    const bytes = try encode(a, .proxy, "/home/u/dl", &specs);
    defer a.free(bytes);

    const st = try decode(a, bytes);
    defer st.deinit(a);

    try testing.expectEqual(api.Route.proxy, st.route);
    try testing.expectEqualStrings("/home/u/dl", st.download_dir);
    try testing.expectEqual(@as(usize, 2), st.transfers.len);
    try testing.expectEqual(Kind.download, st.transfers[0].kind);
    try testing.expectEqualStrings("magnet:?xt=urn:btih:abc", st.transfers[0].source);
    try testing.expectEqual(api.Route.tor, st.transfers[0].route);
    try testing.expect(st.transfers[0].nostr);
    try testing.expectEqual(Kind.seed, st.transfers[1].kind);
    try testing.expectEqualStrings("/data/movie.tar", st.transfers[1].source);
    try testing.expect(!st.transfers[1].nostr);
}

test "decode tolerates empty transfer list and missing fields" {
    const a = testing.allocator;
    const st = try decode(a, "{\"route\":\"tor\",\"downloadDir\":\"/x\",\"transfers\":[]}");
    defer st.deinit(a);
    try testing.expectEqual(api.Route.tor, st.route);
    try testing.expectEqual(@as(usize, 0), st.transfers.len);

    const st2 = try decode(a, "{}");
    defer st2.deinit(a);
    try testing.expectEqual(api.Route.direct, st2.route);
    try testing.expectEqualStrings("", st2.download_dir);
}

test "decode rejects non-object json" {
    const a = testing.allocator;
    try testing.expectError(error.InvalidJson, decode(a, "[1,2,3]"));
}
