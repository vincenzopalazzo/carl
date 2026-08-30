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
const SQLITE_DONE: c_int = 101;
// SQLITE_TRANSIENT = (void*)-1 → tells SQLite to copy bound text immediately.
const SQLITE_TRANSIENT: ?*const anyopaque = @ptrFromInt(@as(usize, std.math.maxInt(usize)));

const SCHEMA =
    \\CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
    \\CREATE TABLE IF NOT EXISTS transfers(
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  kind TEXT NOT NULL, source TEXT NOT NULL, route TEXT NOT NULL, nostr INTEGER NOT NULL);
    \\CREATE TABLE IF NOT EXISTS follows(
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  pubkey TEXT NOT NULL, route TEXT NOT NULL);
    \\CREATE TABLE IF NOT EXISTS drives(
    \\  id TEXT PRIMARY KEY, role TEXT, dir TEXT, name TEXT, author TEXT, also TEXT, route TEXT);
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

/// A followed publisher to re-create on restart: the pubkey (64-char hex) and
/// the mirror route. The mirror dir is derived from the download dir + pubkey,
/// so it's not persisted.
pub const FollowSpec = struct {
    pubkey: []const u8,
    route: api.Route,
};

/// A shared drive's role: a publisher watches a folder and publishes its files;
/// a subscriber mirrors a publisher's drive index into a local folder.
pub const DriveRole = enum {
    publisher,
    subscriber,

    fn jsonName(self: DriveRole) []const u8 {
        return @tagName(self);
    }

    fn parse(s: []const u8) ?DriveRole {
        return std.meta.stringToEnum(DriveRole, s);
    }
};

/// A shared drive to re-create on restart. `author` is the subscriber's
/// followed author as 64-char hex ('' for a publisher); `also` is a
/// comma-separated hex list of extra writer pubkeys ('' for none). The id is
/// the daemon's "d<n>" handle id.
pub const DriveSpec = struct {
    id: []const u8,
    role: DriveRole,
    dir: []const u8,
    name: []const u8,
    author: []const u8,
    also: []const u8,
    route: api.Route,
};

pub const State = struct {
    route: api.Route,
    download_dir: []const u8,
    transfers: []const TransferSpec,
    follows: []const FollowSpec = &.{},
    drives: []const DriveSpec = &.{},

    pub fn deinit(self: State, a: Allocator) void {
        a.free(self.download_dir);
        for (self.transfers) |t| a.free(t.source);
        a.free(self.transfers);
        for (self.follows) |f| a.free(f.pubkey);
        a.free(self.follows);
        for (self.drives) |d| {
            a.free(d.id);
            a.free(d.dir);
            a.free(d.name);
            a.free(d.author);
            a.free(d.also);
        }
        a.free(self.drives);
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
    follows: []const FollowSpec,
    drives: []const DriveSpec,
) !void {
    const dir = try nostr_config.ensureConfigDir(a);
    defer a.free(dir);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/carl.db", .{dir}, 0);
    defer a.free(path);
    try saveTo(path, route, download_dir, specs, follows, drives);
}

fn saveTo(
    path: [:0]const u8,
    route: api.Route,
    download_dir: []const u8,
    specs: []const TransferSpec,
    follows: []const FollowSpec,
    drives: []const DriveSpec,
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
        if (sqlite3_step(stmt) != SQLITE_DONE) return error.DbExec;
    }

    try exec(db, "DELETE FROM follows");
    var fstmt: ?*Stmt = null;
    const fsql = "INSERT INTO follows(pubkey,route) VALUES(?,?)";
    if (sqlite3_prepare_v2(db, fsql, @intCast(fsql.len), &fstmt, null) != SQLITE_OK) return error.DbPrepare;
    defer _ = sqlite3_finalize(fstmt);
    for (follows) |f| {
        _ = sqlite3_reset(fstmt);
        bindText(fstmt, 1, f.pubkey);
        bindText(fstmt, 2, f.route.jsonName());
        if (sqlite3_step(fstmt) != SQLITE_DONE) return error.DbExec;
    }

    try exec(db, "DELETE FROM drives");
    var dstmt: ?*Stmt = null;
    const dsql = "INSERT INTO drives(id,role,dir,name,author,also,route) VALUES(?,?,?,?,?,?,?)";
    if (sqlite3_prepare_v2(db, dsql, @intCast(dsql.len), &dstmt, null) != SQLITE_OK) return error.DbPrepare;
    defer _ = sqlite3_finalize(dstmt);
    for (drives) |d| {
        _ = sqlite3_reset(dstmt);
        bindText(dstmt, 1, d.id);
        bindText(dstmt, 2, d.role.jsonName());
        bindText(dstmt, 3, d.dir);
        bindText(dstmt, 4, d.name);
        bindText(dstmt, 5, d.author);
        bindText(dstmt, 6, d.also);
        bindText(dstmt, 7, d.route.jsonName());
        if (sqlite3_step(dstmt) != SQLITE_DONE) return error.DbExec;
    }

    try exec(db, "COMMIT");

    // Magnets, routes, follow pubkeys, drive dirs. sqlite3_open creates
    // the file with the process umask (typically 0644). Re-assert 0600
    // after every save so an existing world-readable db is tightened too.
    if (std.fs.cwd().openFile(path, .{})) |f| {
        defer f.close();
        f.chmod(0o600) catch {};
    } else |_| {}
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

    var follows: std.ArrayList(FollowSpec) = .empty;
    errdefer {
        for (follows.items) |f| a.free(f.pubkey);
        follows.deinit(a);
    }
    var fstmt: ?*Stmt = null;
    const fsql = "SELECT pubkey,route FROM follows ORDER BY id";
    if (sqlite3_prepare_v2(db, fsql, @intCast(fsql.len), &fstmt, null) != SQLITE_OK) return error.DbPrepare;
    defer _ = sqlite3_finalize(fstmt);
    while (sqlite3_step(fstmt) == SQLITE_ROW) {
        const pk = try a.dupe(u8, columnText(fstmt, 0));
        errdefer a.free(pk);
        const r = api.Route.parse(columnText(fstmt, 1)) orelse .direct;
        try follows.append(a, .{ .pubkey = pk, .route = r });
    }

    var drives: std.ArrayList(DriveSpec) = .empty;
    errdefer {
        for (drives.items) |d| {
            a.free(d.id);
            a.free(d.dir);
            a.free(d.name);
            a.free(d.author);
            a.free(d.also);
        }
        drives.deinit(a);
    }
    var dstmt: ?*Stmt = null;
    const dsql = "SELECT id,role,dir,name,author,also,route FROM drives ORDER BY rowid";
    if (sqlite3_prepare_v2(db, dsql, @intCast(dsql.len), &dstmt, null) != SQLITE_OK) return error.DbPrepare;
    defer _ = sqlite3_finalize(dstmt);
    while (sqlite3_step(dstmt) == SQLITE_ROW) {
        const id = try a.dupe(u8, columnText(dstmt, 0));
        errdefer a.free(id);
        const role = DriveRole.parse(columnText(dstmt, 1)) orelse .publisher;
        const ddir = try a.dupe(u8, columnText(dstmt, 2));
        errdefer a.free(ddir);
        const name = try a.dupe(u8, columnText(dstmt, 3));
        errdefer a.free(name);
        const author = try a.dupe(u8, columnText(dstmt, 4));
        errdefer a.free(author);
        const also = try a.dupe(u8, columnText(dstmt, 5));
        errdefer a.free(also);
        const r = api.Route.parse(columnText(dstmt, 6)) orelse .direct;
        try drives.append(a, .{ .id = id, .role = role, .dir = ddir, .name = name, .author = author, .also = also, .route = r });
    }

    const transfers = try list.toOwnedSlice(a);
    errdefer {
        for (transfers) |t| a.free(t.source);
        a.free(transfers);
    }
    const follows_slice = try follows.toOwnedSlice(a);
    errdefer a.free(follows_slice);
    const drives_slice = try drives.toOwnedSlice(a);
    errdefer a.free(drives_slice);
    return .{
        .route = route,
        .download_dir = download_dir,
        .transfers = transfers,
        .follows = follows_slice,
        .drives = drives_slice,
    };
}

/// Read just the persisted `downloadDir` setting, or null when there is no
/// database / no value / an empty value. Best-effort: any failure reads as
/// "unset" so callers (workdir resolution) fall back to the built-in default.
pub fn loadDownloadDir(a: Allocator) ?[]u8 {
    const path = dbPath(a) catch return null;
    defer a.free(path);
    std.fs.cwd().access(path, .{}) catch return null; // no DB yet
    const path_z = a.dupeZ(u8, path) catch return null;
    defer a.free(path_z);
    return loadDownloadDirFrom(a, path_z);
}

fn loadDownloadDirFrom(a: Allocator, path: [:0]const u8) ?[]u8 {
    const db = open(path) catch return null;
    defer _ = sqlite3_close(db);
    const value = (getSetting(a, db, "downloadDir") catch return null) orelse return null;
    if (value.len == 0) {
        a.free(value);
        return null;
    }
    return value;
}

fn upsertSetting(db: *Sqlite, key: []const u8, value: []const u8) Error!void {
    var stmt: ?*Stmt = null;
    const sql = "INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value";
    if (sqlite3_prepare_v2(db, sql, @intCast(sql.len), &stmt, null) != SQLITE_OK) return error.DbPrepare;
    defer _ = sqlite3_finalize(stmt);
    bindText(stmt, 1, key);
    bindText(stmt, 2, value);
    if (sqlite3_step(stmt) != SQLITE_DONE) return error.DbExec;
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
    try saveTo(path, .proxy, "/home/u/dl", &specs, &.{}, &.{});

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

test "sqlite save creates the db with mode 0600" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/carl.db", .{dir}, 0);
    defer a.free(path);

    try saveTo(path, .proxy, "/home/u/dl", &.{}, &.{}, &.{});
    var f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const st = try f.stat();
    try testing.expectEqual(@as(u32, 0o600), st.mode & 0o777);
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
    try saveTo(path, .direct, "/x", &one, &.{}, &.{});
    try saveTo(path, .tor, "/y", &one, &.{}, &.{}); // overwrite

    const st = try loadFrom(a, path);
    defer st.deinit(a);
    try testing.expectEqual(@as(usize, 1), st.transfers.len);
    try testing.expectEqual(api.Route.tor, st.route);
    try testing.expectEqualStrings("/y", st.download_dir);
}

test "sqlite save/load round-trips follows" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/carl.db", .{dir}, 0);
    defer a.free(path);

    const follows = [_]FollowSpec{
        .{ .pubkey = "16e8c40c332df0746a15d1e8c0a569af59d8da3ac0bafbe8f1c3f23156c44313", .route = .i2p },
        .{ .pubkey = "ab" ** 32, .route = .direct },
    };
    try saveTo(path, .direct, "/dl", &.{}, &follows, &.{});

    const st = try loadFrom(a, path);
    defer st.deinit(a);
    try testing.expectEqual(@as(usize, 2), st.follows.len);
    try testing.expectEqualStrings(follows[0].pubkey, st.follows[0].pubkey);
    try testing.expectEqual(api.Route.i2p, st.follows[0].route);
    try testing.expectEqual(api.Route.direct, st.follows[1].route);

    // Re-save with none: the table is rebuilt, not accumulated.
    try saveTo(path, .direct, "/dl", &.{}, &.{}, &.{});
    const st2 = try loadFrom(a, path);
    defer st2.deinit(a);
    try testing.expectEqual(@as(usize, 0), st2.follows.len);
}

test "sqlite save/load round-trips drives" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/carl.db", .{dir}, 0);
    defer a.free(path);

    const drives = [_]DriveSpec{
        .{ .id = "d1", .role = .publisher, .dir = "/data/pub", .name = "docs", .author = "", .also = "", .route = .direct },
        .{ .id = "d2", .role = .subscriber, .dir = "/data/sub", .name = "mirror", .author = "ab" ** 32, .also = "cd" ** 32 ++ "," ++ "ef" ** 32, .route = .i2p },
    };
    try saveTo(path, .direct, "/dl", &.{}, &.{}, &drives);

    const st = try loadFrom(a, path);
    defer st.deinit(a);
    try testing.expectEqual(@as(usize, 2), st.drives.len);
    try testing.expectEqualStrings("d1", st.drives[0].id);
    try testing.expectEqual(DriveRole.publisher, st.drives[0].role);
    try testing.expectEqualStrings("/data/pub", st.drives[0].dir);
    try testing.expectEqualStrings("docs", st.drives[0].name);
    try testing.expectEqualStrings("", st.drives[0].author);
    try testing.expectEqualStrings("", st.drives[0].also);
    try testing.expectEqual(api.Route.direct, st.drives[0].route);
    try testing.expectEqualStrings("d2", st.drives[1].id);
    try testing.expectEqual(DriveRole.subscriber, st.drives[1].role);
    try testing.expectEqualStrings("ab" ** 32, st.drives[1].author);
    try testing.expectEqualStrings("cd" ** 32 ++ "," ++ "ef" ** 32, st.drives[1].also);
    try testing.expectEqual(api.Route.i2p, st.drives[1].route);

    // Re-save with none: the table is rebuilt, not accumulated.
    try saveTo(path, .direct, "/dl", &.{}, &.{}, &.{});
    const st2 = try loadFrom(a, path);
    defer st2.deinit(a);
    try testing.expectEqual(@as(usize, 0), st2.drives.len);
}

test "loadDownloadDirFrom reads the setting; empty/missing read as unset" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/carl.db", .{dir}, 0);
    defer a.free(path);

    // Fresh DB (schema only): no setting yet.
    try testing.expect(loadDownloadDirFrom(a, path) == null);

    try saveTo(path, .direct, "/home/u/dl", &.{}, &.{}, &.{});
    const got = loadDownloadDirFrom(a, path) orelse return error.TestUnexpectedResult;
    defer a.free(got);
    try testing.expectEqualStrings("/home/u/dl", got);

    try saveTo(path, .direct, "", &.{}, &.{}, &.{});
    try testing.expect(loadDownloadDirFrom(a, path) == null);
}
