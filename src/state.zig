//! Daemon state persistence, backed by SQLite (`<config>/carl.db`).
//!
//! Stores the editable settings (route, download dir) and the set of
//! transfers/seeds as re-create *specs* (kind + source + route + nostr) so a
//! restart resumes exactly where it left off. On metadata completion the
//! manager rewrites a transfer's source to a generated `.torrent` path (see
//! manager.zig), so a finished magnet download restores as a full, complete
//! torrent rather than re-fetching metadata.
//!
//! SQLite (not a flat file) gives atomic, crash-safe writes via a transaction
//! and is the natural store as this grows. Relays/identity persist separately
//! via `nostr_config`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const api = @import("api.zig");
const nostr_config = @import("nostr_config.zig");

const log = std.log.scoped(.state);

// ---- minimal libsqlite3 bindings (linked via build.zig) -------------------
const Sqlite = opaque {};
const Stmt = opaque {};
extern fn sqlite3_open(filename: [*:0]const u8, ppDb: *?*Sqlite) c_int;
extern fn sqlite3_close(db: ?*Sqlite) c_int;
extern fn sqlite3_exec(db: ?*Sqlite, sql: [*:0]const u8, cb: ?*const anyopaque, arg: ?*anyopaque, errmsg: ?*?[*:0]u8) c_int;
extern fn sqlite3_prepare_v2(db: ?*Sqlite, sql: [*]const u8, n: c_int, stmt: *?*Stmt, tail: ?*?[*]const u8) c_int;
extern fn sqlite3_step(s: ?*Stmt) c_int;
extern fn sqlite3_finalize(s: ?*Stmt) c_int;
extern fn sqlite3_reset(s: ?*Stmt) c_int;
extern fn sqlite3_bind_text(s: ?*Stmt, i: c_int, t: [*]const u8, n: c_int, d: ?*const anyopaque) c_int;
extern fn sqlite3_bind_int(s: ?*Stmt, i: c_int, v: c_int) c_int;
extern fn sqlite3_column_text(s: ?*Stmt, i: c_int) ?[*:0]const u8;
extern fn sqlite3_column_int(s: ?*Stmt, i: c_int) c_int;

const SQLITE_OK: c_int = 0;
const SQLITE_ROW: c_int = 100;
// SQLITE_TRANSIENT = (void*)-1 → tells SQLite to copy bound text immediately.
const SQLITE_TRANSIENT: ?*const anyopaque = @ptrFromInt(@as(usize, std.math.maxInt(usize)));

const SCHEMA =
    \\CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
    \\CREATE TABLE IF NOT EXISTS transfers(
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  kind TEXT NOT NULL, source TEXT NOT NULL, route TEXT NOT NULL, nostr INTEGER NOT NULL);
;

pub const Error = error{ DbOpen, DbExec, DbPrepare } || Allocator.Error;

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

pub const TransferSpec = struct {
    kind: Kind,
    source: []const u8,
    route: api.Route,
    nostr: bool,
};

pub const State = struct {
    route: api.Route,
    download_dir: []const u8,
    transfers: []const TransferSpec,

    pub fn deinit(self: State, a: Allocator) void {
        a.free(self.download_dir);
        for (self.transfers) |t| a.free(t.source);
        a.free(self.transfers);
    }
};

/// `<config>/carl.db`. Caller owns the returned path.
pub fn dbPath(a: Allocator) ![]u8 {
    const dir = try nostr_config.configDir(a);
    defer a.free(dir);
    return std.fmt.allocPrint(a, "{s}/carl.db", .{dir});
}

fn open(path: [:0]const u8) Error!*Sqlite {
    var db: ?*Sqlite = null;
    if (sqlite3_open(path, &db) != SQLITE_OK or db == null) {
        if (db) |d| _ = sqlite3_close(d);
        return error.DbOpen;
    }
    if (sqlite3_exec(db, SCHEMA, null, null, null) != SQLITE_OK) {
        _ = sqlite3_close(db);
        return error.DbExec;
    }
    return db.?;
}

fn exec(db: *Sqlite, sql: [:0]const u8) Error!void {
    if (sqlite3_exec(db, sql, null, null, null) != SQLITE_OK) return error.DbExec;
}

/// Write settings + transfers atomically (a single transaction; the table is
/// rebuilt from `specs`). Persists to `<config>/carl.db`.
pub fn save(
    a: Allocator,
    route: api.Route,
    download_dir: []const u8,
    specs: []const TransferSpec,
) !void {
    const dir = try nostr_config.ensureConfigDir(a);
    defer a.free(dir);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/carl.db", .{dir}, 0);
    defer a.free(path);
    try saveTo(path, route, download_dir, specs);
}

fn saveTo(
    path: [:0]const u8,
    route: api.Route,
    download_dir: []const u8,
    specs: []const TransferSpec,
) Error!void {
    const db = try open(path);
    defer _ = sqlite3_close(db);

    try exec(db, "BEGIN IMMEDIATE");
    errdefer exec(db, "ROLLBACK") catch {};

    try upsertSetting(db, "route", route.jsonName());
    try upsertSetting(db, "downloadDir", download_dir);
    try exec(db, "DELETE FROM transfers");

    var stmt: ?*Stmt = null;
    const sql = "INSERT INTO transfers(kind,source,route,nostr) VALUES(?,?,?,?)";
    if (sqlite3_prepare_v2(db, sql, @intCast(sql.len), &stmt, null) != SQLITE_OK) return error.DbPrepare;
    defer _ = sqlite3_finalize(stmt);
    for (specs) |s| {
        _ = sqlite3_reset(stmt);
        bindText(stmt, 1, s.kind.jsonName());
        bindText(stmt, 2, s.source);
        bindText(stmt, 3, s.route.jsonName());
        _ = sqlite3_bind_int(stmt, 4, if (s.nostr) 1 else 0);
        _ = sqlite3_step(stmt);
    }

    try exec(db, "COMMIT");
}

/// Load persisted state, or null if no database exists yet. Caller frees via
/// `State.deinit`.
pub fn load(a: Allocator) !?State {
    const path = try dbPath(a);
    defer a.free(path);
    std.fs.cwd().access(path, .{}) catch return null; // no DB yet
    const path_z = try a.dupeZ(u8, path);
    defer a.free(path_z);
    return try loadFrom(a, path_z);
}

fn loadFrom(a: Allocator, path: [:0]const u8) Error!State {
    const db = try open(path);
    defer _ = sqlite3_close(db);

    const route_str = try getSetting(a, db, "route");
    defer if (route_str) |s| a.free(s);
    const route = api.Route.parse(route_str orelse "direct") orelse .direct;
    const download_dir = try getSetting(a, db, "downloadDir") orelse try a.dupe(u8, "");
    errdefer a.free(download_dir);

    var list: std.ArrayList(TransferSpec) = .empty;
    errdefer {
        for (list.items) |t| a.free(t.source);
        list.deinit(a);
    }

    var stmt: ?*Stmt = null;
    const sql = "SELECT kind,source,route,nostr FROM transfers ORDER BY id";
    if (sqlite3_prepare_v2(db, sql, @intCast(sql.len), &stmt, null) != SQLITE_OK) return error.DbPrepare;
    defer _ = sqlite3_finalize(stmt);
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const kind = Kind.parse(columnText(stmt, 0)) orelse .download;
        const src = try a.dupe(u8, columnText(stmt, 1));
        errdefer a.free(src);
        const r = api.Route.parse(columnText(stmt, 2)) orelse .direct;
        const nostr = sqlite3_column_int(stmt, 3) != 0;
        try list.append(a, .{ .kind = kind, .source = src, .route = r, .nostr = nostr });
    }

    return .{ .route = route, .download_dir = download_dir, .transfers = try list.toOwnedSlice(a) };
}

fn upsertSetting(db: *Sqlite, key: []const u8, value: []const u8) Error!void {
    var stmt: ?*Stmt = null;
    const sql = "INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value";
    if (sqlite3_prepare_v2(db, sql, @intCast(sql.len), &stmt, null) != SQLITE_OK) return error.DbPrepare;
    defer _ = sqlite3_finalize(stmt);
    bindText(stmt, 1, key);
    bindText(stmt, 2, value);
    _ = sqlite3_step(stmt);
}

fn getSetting(a: Allocator, db: *Sqlite, key: []const u8) Error!?[]u8 {
    var stmt: ?*Stmt = null;
    const sql = "SELECT value FROM settings WHERE key=?";
    if (sqlite3_prepare_v2(db, sql, @intCast(sql.len), &stmt, null) != SQLITE_OK) return error.DbPrepare;
    defer _ = sqlite3_finalize(stmt);
    bindText(stmt, 1, key);
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        return try a.dupe(u8, columnText(stmt, 0));
    }
    return null;
}

fn bindText(stmt: ?*Stmt, idx: c_int, text: []const u8) void {
    _ = sqlite3_bind_text(stmt, idx, text.ptr, @intCast(text.len), SQLITE_TRANSIENT);
}

fn columnText(stmt: ?*Stmt, idx: c_int) []const u8 {
    const ptr = sqlite3_column_text(stmt, idx) orelse return "";
    return std.mem.span(ptr);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "sqlite save/load round-trips settings + transfers" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/carl.db", .{dir}, 0);
    defer a.free(path);

    const specs = [_]TransferSpec{
        .{ .kind = .download, .source = "magnet:?xt=urn:btih:abc", .route = .tor, .nostr = true },
        .{ .kind = .seed, .source = "/data/movie.tar", .route = .direct, .nostr = false },
    };
    try saveTo(path, .proxy, "/home/u/dl", &specs);

    const st = try loadFrom(a, path);
    defer st.deinit(a);
    try testing.expectEqual(api.Route.proxy, st.route);
    try testing.expectEqualStrings("/home/u/dl", st.download_dir);
    try testing.expectEqual(@as(usize, 2), st.transfers.len);
    try testing.expectEqual(Kind.download, st.transfers[0].kind);
    try testing.expectEqualStrings("magnet:?xt=urn:btih:abc", st.transfers[0].source);
    try testing.expectEqual(api.Route.tor, st.transfers[0].route);
    try testing.expect(st.transfers[0].nostr);
    try testing.expectEqual(Kind.seed, st.transfers[1].kind);
    try testing.expect(!st.transfers[1].nostr);
}

test "sqlite save replaces prior transfers (no accumulation)" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/carl.db", .{dir}, 0);
    defer a.free(path);

    const one = [_]TransferSpec{.{ .kind = .download, .source = "a", .route = .direct, .nostr = false }};
    try saveTo(path, .direct, "/x", &one);
    try saveTo(path, .tor, "/y", &one); // overwrite

    const st = try loadFrom(a, path);
    defer st.deinit(a);
    try testing.expectEqual(@as(usize, 1), st.transfers.len);
    try testing.expectEqual(api.Route.tor, st.route);
    try testing.expectEqualStrings("/y", st.download_dir);
}
