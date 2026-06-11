/// Disk I/O for piece data with multi-file torrent support.
const std = @import("std");
const Allocator = std.mem.Allocator;
const metainfo = @import("metainfo.zig");
const piece_mod = @import("piece.zig");

/// A contiguous region within a single file.
pub const FileSlice = struct {
    file_index: u32,
    file_offset: u64,
    length: u64,
};

/// Pre-computed file boundary table for mapping torrent-linear offsets to files.
pub const FileMap = struct {
    file_starts: []u64,
    file_lengths: []u64,
    total_length: u64,
    num_files: u32,

    pub fn init(allocator: Allocator, files: []const metainfo.FileInfo) error{OutOfMemory}!FileMap {
        const n = std.math.cast(u32, files.len) orelse return error.OutOfMemory;
        const starts = allocator.alloc(u64, files.len) catch return error.OutOfMemory;
        const lengths = allocator.alloc(u64, files.len) catch {
            allocator.free(starts);
            return error.OutOfMemory;
        };

        var offset: u64 = 0;
        for (files, 0..) |f, i| {
            starts[i] = offset;
            lengths[i] = f.length;
            offset += f.length;
        }

        return .{
            .file_starts = starts,
            .file_lengths = lengths,
            .total_length = offset,
            .num_files = n,
        };
    }

    pub fn deinit(self: FileMap, allocator: Allocator) void {
        allocator.free(self.file_starts);
        allocator.free(self.file_lengths);
    }

    /// Map a (torrent_offset, length) range to FileSlice entries.
    /// Writes into the provided scratch buffer and returns the used portion.
    /// Returns error if the scratch buffer is too small to hold all slices.
    pub fn mapRange(self: FileMap, torrent_offset: u64, length: u64, scratch: []FileSlice) error{ScratchExhausted}![]FileSlice {
        var start = torrent_offset;
        var remaining = length;
        var count: usize = 0;

        // Find starting file
        var fi: usize = 0;
        while (fi < self.num_files) : (fi += 1) {
            if (self.file_starts[fi] + self.file_lengths[fi] > start) break;
        }

        while (remaining > 0 and fi < self.num_files) {
            if (count >= scratch.len) return error.ScratchExhausted;

            const file_offset = start - self.file_starts[fi];
            const avail = self.file_lengths[fi] - file_offset;
            const chunk = @min(remaining, avail);

            scratch[count] = .{
                .file_index = @intCast(fi),
                .file_offset = file_offset,
                .length = chunk,
            };
            count += 1;
            start += chunk;
            remaining -= chunk;
            fi += 1;
        }

        return scratch[0..count];
    }
};

/// Manages open file handles and performs positioned reads/writes.
pub const Storage = struct {
    allocator: Allocator,
    file_map: FileMap,
    handles: []std.fs.File,
    piece_len: u64,
    /// The output directory, kept open so handles can be reopened read-only.
    dir: std.fs.Dir,
    /// Relative path of each file inside `dir` (joined components), owned.
    paths: [][]u8,
    /// True when `handles` are read-only (seed mode, or after a downgrade).
    read_only: bool,
    /// True once `closeFiles` ran; guards double-close from `deinit`.
    files_closed: bool = false,

    pub const IoError = error{
        FileOpenFailed,
        WriteFailed,
        ReadFailed,
        OutOfMemory,
    };

    /// Initialize storage for a torrent. If `create` is true, creates/preallocates files.
    /// If false, opens existing files for reading (seed mode).
    pub fn init(
        allocator: Allocator,
        meta: metainfo.Metainfo,
        output_dir_path: []const u8,
        create: bool,
    ) IoError!Storage {
        const fm = FileMap.init(allocator, meta.files) catch return error.OutOfMemory;
        errdefer fm.deinit(allocator);

        const handles = allocator.alloc(std.fs.File, meta.files.len) catch return error.OutOfMemory;
        @memset(handles, undefined);
        errdefer allocator.free(handles);

        const paths = allocator.alloc([]u8, meta.files.len) catch return error.OutOfMemory;
        errdefer allocator.free(paths);

        var opened: usize = 0;
        var paths_set: usize = 0;
        errdefer {
            for (handles[0..opened]) |h| h.close();
            for (paths[0..paths_set]) |p| allocator.free(p);
        }

        var dir = std.fs.cwd().openDir(output_dir_path, .{}) catch return error.FileOpenFailed;
        errdefer dir.close();

        // Validate all path components before creating any files (path traversal defense)
        for (meta.files) |file_info| {
            for (file_info.path) |comp| {
                if (!isValidPathComponent(comp)) return error.FileOpenFailed;
            }
        }

        for (meta.files, 0..) |file_info, i| {
            // Build path from components
            if (file_info.path.len > 1) {
                // Create parent directories
                var path_buf: [4096]u8 = undefined;
                var pos: usize = 0;
                for (file_info.path[0 .. file_info.path.len - 1]) |comp| {
                    if (pos > 0) {
                        path_buf[pos] = '/';
                        pos += 1;
                    }
                    if (pos + comp.len > path_buf.len) return error.FileOpenFailed;
                    @memcpy(path_buf[pos .. pos + comp.len], comp);
                    pos += comp.len;
                }
                dir.makePath(path_buf[0..pos]) catch {};
            }

            // Build full relative path
            var path_buf: [4096]u8 = undefined;
            var pos: usize = 0;
            for (file_info.path, 0..) |comp, j| {
                if (j > 0) {
                    path_buf[pos] = '/';
                    pos += 1;
                }
                if (pos + comp.len > path_buf.len) return error.FileOpenFailed;
                @memcpy(path_buf[pos .. pos + comp.len], comp);
                pos += comp.len;
            }
            const path = path_buf[0..pos];

            if (create) {
                handles[i] = dir.createFile(path, .{ .read = true, .truncate = false }) catch return error.FileOpenFailed;
                // Count the handle as opened before preallocating, so a
                // setEndPos failure (disk full) doesn't leak the descriptor
                // on the error path — Session.init failures don't kill the
                // daemon, so leaked fds would accumulate.
                opened += 1;
                handles[i].setEndPos(file_info.length) catch return error.WriteFailed;
            } else {
                // Seeding only reads: a read-only handle leaves the file free
                // for other programs (no write lock on data we never modify).
                handles[i] = dir.openFile(path, .{ .mode = .read_only }) catch return error.FileOpenFailed;
                opened += 1;
            }
            paths[i] = allocator.dupe(u8, path) catch return error.OutOfMemory;
            paths_set += 1;
        }

        return .{
            .allocator = allocator,
            .file_map = fm,
            .handles = handles,
            .piece_len = meta.piece_length,
            .dir = dir,
            .paths = paths,
            .read_only = !create,
        };
    }

    pub fn deinit(self: *Storage) void {
        self.closeFiles();
        self.allocator.free(self.handles);
        for (self.paths) |p| self.allocator.free(p);
        self.allocator.free(self.paths);
        self.dir.close();
        self.file_map.deinit(self.allocator);
    }

    /// Close every file handle (idempotent). Called when a download finishes
    /// without continuing to seed: the session object can outlive completion
    /// (the daemon keeps it registered), and a finished download must not
    /// keep its files open. Reads/writes fail after this.
    pub fn closeFiles(self: *Storage) void {
        if (self.files_closed) return;
        for (self.handles) |h| h.close();
        self.files_closed = true;
    }

    /// Swap read-write handles for read-only ones, per file and best-effort
    /// (a file whose reopen fails keeps its old handle). Called when a
    /// finished download keeps seeding: serving pieces only reads, and
    /// holding write access would keep other programs from using the files.
    pub fn downgradeToReadOnly(self: *Storage) void {
        if (self.files_closed or self.read_only) return;
        for (self.handles, self.paths) |*h, p| {
            const ro = self.dir.openFile(p, .{ .mode = .read_only }) catch continue;
            h.close();
            h.* = ro;
        }
        self.read_only = true;
    }

    /// Write a verified piece to disk.
    pub fn writePiece(self: *Storage, index: u32, data: []const u8) IoError!void {
        const torrent_offset = @as(u64, index) * self.piece_len;
        var scratch: [64]FileSlice = undefined;
        const slices = self.file_map.mapRange(torrent_offset, data.len, &scratch) catch return error.WriteFailed;

        var data_pos: usize = 0;
        for (slices) |s| {
            const chunk_len = std.math.cast(usize, s.length) orelse return error.WriteFailed;
            const chunk = data[data_pos .. data_pos + chunk_len];
            self.handles[s.file_index].pwriteAll(chunk, s.file_offset) catch return error.WriteFailed;
            data_pos += chunk_len;
        }
    }

    /// Read a piece from disk. Caller owns the returned slice.
    pub fn readPiece(self: *Storage, allocator: Allocator, index: u32, length: u32) IoError![]u8 {
        return self.readRange(allocator, index, 0, length);
    }

    /// Read `length` bytes starting at `begin` within piece `index`. Caller
    /// owns the returned slice. Serving a 16 KiB block request must not read
    /// (and allocate) the whole piece — that is a 16-64x overhead per block.
    pub fn readRange(self: *Storage, allocator: Allocator, index: u32, begin: u32, length: u32) IoError![]u8 {
        const torrent_offset = @as(u64, index) * self.piece_len + begin;
        const buf = allocator.alloc(u8, length) catch return error.OutOfMemory;
        errdefer allocator.free(buf);

        var scratch: [64]FileSlice = undefined;
        const slices = self.file_map.mapRange(torrent_offset, length, &scratch) catch return error.ReadFailed;

        var buf_pos: usize = 0;
        for (slices) |s| {
            const chunk_len = std.math.cast(usize, s.length) orelse return error.ReadFailed;
            const bytes_read = self.handles[s.file_index].pread(buf[buf_pos .. buf_pos + chunk_len], s.file_offset) catch return error.ReadFailed;
            if (bytes_read != chunk_len) return error.ReadFailed;
            buf_pos += chunk_len;
        }

        // A range past the torrent's end maps to fewer bytes than requested;
        // the unfilled allocation must never escape (it would leak heap
        // contents to the peer being served).
        if (buf_pos != length) return error.ReadFailed;

        return buf;
    }
};

/// Reject path components that could escape the output directory.
fn isValidPathComponent(comp: []const u8) bool {
    if (comp.len == 0) return false;
    if (std.mem.eql(u8, comp, "..")) return false;
    if (std.mem.eql(u8, comp, ".")) return false;
    // Reject absolute paths and embedded separators
    if (comp[0] == '/') return false;
    if (std.mem.indexOfScalar(u8, comp, '/') != null) return false;
    if (std.mem.indexOfScalar(u8, comp, 0) != null) return false;
    // Reject backslash (Windows path separator)
    if (std.mem.indexOfScalar(u8, comp, '\\') != null) return false;
    return true;
}

// --- Tests ---

test "file map single file" {
    const allocator = std.testing.allocator;
    const files = [_]metainfo.FileInfo{
        .{ .length = 1000, .path = &.{"test.txt"} },
    };
    const fm = try FileMap.init(allocator, &files);
    defer fm.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 1000), fm.total_length);
    try std.testing.expectEqual(@as(u64, 0), fm.file_starts[0]);

    var scratch: [4]FileSlice = undefined;
    const slices = try fm.mapRange(100, 200, &scratch);
    try std.testing.expectEqual(@as(usize, 1), slices.len);
    try std.testing.expectEqual(@as(u32, 0), slices[0].file_index);
    try std.testing.expectEqual(@as(u64, 100), slices[0].file_offset);
    try std.testing.expectEqual(@as(u64, 200), slices[0].length);
}

test "file map multi file spanning" {
    const allocator = std.testing.allocator;
    const files = [_]metainfo.FileInfo{
        .{ .length = 100, .path = &.{"a.txt"} },
        .{ .length = 200, .path = &.{"b.txt"} },
        .{ .length = 150, .path = &.{"c.txt"} },
    };
    const fm = try FileMap.init(allocator, &files);
    defer fm.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 450), fm.total_length);

    // Range that spans file a (last 50 bytes) and file b (first 100 bytes)
    var scratch: [4]FileSlice = undefined;
    const slices = try fm.mapRange(50, 150, &scratch);
    try std.testing.expectEqual(@as(usize, 2), slices.len);

    // First slice: file a, offset 50, length 50
    try std.testing.expectEqual(@as(u32, 0), slices[0].file_index);
    try std.testing.expectEqual(@as(u64, 50), slices[0].file_offset);
    try std.testing.expectEqual(@as(u64, 50), slices[0].length);

    // Second slice: file b, offset 0, length 100
    try std.testing.expectEqual(@as(u32, 1), slices[1].file_index);
    try std.testing.expectEqual(@as(u64, 0), slices[1].file_offset);
    try std.testing.expectEqual(@as(u64, 100), slices[1].length);
}

test "file map three file span" {
    const allocator = std.testing.allocator;
    const files = [_]metainfo.FileInfo{
        .{ .length = 10, .path = &.{"a.txt"} },
        .{ .length = 10, .path = &.{"b.txt"} },
        .{ .length = 10, .path = &.{"c.txt"} },
    };
    const fm = try FileMap.init(allocator, &files);
    defer fm.deinit(allocator);

    // Span all three files
    var scratch: [4]FileSlice = undefined;
    const slices = try fm.mapRange(5, 20, &scratch);
    try std.testing.expectEqual(@as(usize, 3), slices.len);
    try std.testing.expectEqual(@as(u64, 5), slices[0].length); // a: 5 bytes
    try std.testing.expectEqual(@as(u64, 10), slices[1].length); // b: all 10
    try std.testing.expectEqual(@as(u64, 5), slices[2].length); // c: 5 bytes
}

test "storage write and read roundtrip" {
    const allocator = std.testing.allocator;

    // Create a temp directory
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = tmp_dir.dir.realpathAlloc(allocator, ".") catch return;
    defer allocator.free(tmp_path);

    const files = [_]metainfo.FileInfo{
        .{ .length = 32768, .path = &.{"test_output.bin"} },
    };

    const meta = metainfo.Metainfo{
        .announce = "http://example.com",
        .announce_list = null,
        .name = "test",
        .piece_length = 16384,
        .pieces = &([_]u8{0} ** 40), // 2 piece hashes
        .files = &files,
        .comment = null,
        .creation_date = null,
        .created_by = null,
        .raw_info = &.{},
        .url_list = null,
    };

    var store = Storage.init(allocator, meta, tmp_path, true) catch return;
    defer store.deinit();

    // Write piece 0
    const data0 = [_]u8{0xAA} ** 16384;
    try store.writePiece(0, &data0);

    // Write piece 1
    const data1 = [_]u8{0xBB} ** 16384;
    try store.writePiece(1, &data1);

    // Read back
    const read0 = try store.readPiece(allocator, 0, 16384);
    defer allocator.free(read0);
    try std.testing.expectEqual(@as(u8, 0xAA), read0[0]);
    try std.testing.expectEqual(@as(u8, 0xAA), read0[16383]);

    const read1 = try store.readPiece(allocator, 1, 16384);
    defer allocator.free(read1);
    try std.testing.expectEqual(@as(u8, 0xBB), read1[0]);
}

test "readRange reads a mid-piece block spanning a file boundary" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = tmp_dir.dir.realpathAlloc(allocator, ".") catch return;
    defer allocator.free(tmp_path);

    // One 16 KiB piece split across two files (10000 + 6384 bytes), so a
    // mid-piece range crosses the file boundary.
    const files = [_]metainfo.FileInfo{
        .{ .length = 10000, .path = &.{"a.bin"} },
        .{ .length = 6384, .path = &.{"b.bin"} },
    };

    var store = Storage.init(allocator, testMeta(&files), tmp_path, true) catch return;
    defer store.deinit();

    var data: [16384]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i);
    try store.writePiece(0, &data);

    // Serve a block-request-sized range straddling the boundary: the offset
    // math (`index * piece_len + begin`) must hold for a non-zero `begin`.
    const begin: u32 = 9000;
    const length: u32 = 2000;
    const got = try store.readRange(allocator, 0, begin, length);
    defer allocator.free(got);
    try std.testing.expectEqualSlices(u8, data[begin .. begin + length], got);

    // And a range entirely inside the second file.
    const got2 = try store.readRange(allocator, 0, 12000, 1000);
    defer allocator.free(got2);
    try std.testing.expectEqualSlices(u8, data[12000..13000], got2);

    // A range past the torrent's end maps to fewer bytes than requested and
    // must fail rather than return a partially-uninitialized buffer (which
    // would leak heap contents to the requesting peer).
    try std.testing.expectError(error.ReadFailed, store.readRange(allocator, 0, 16000, 1000));
    try std.testing.expectError(error.ReadFailed, store.readRange(allocator, 9, 0, 16384));
}

fn testMeta(files: []const metainfo.FileInfo) metainfo.Metainfo {
    return .{
        .announce = "http://example.com",
        .announce_list = null,
        .name = "test",
        .piece_length = 16384,
        .pieces = &([_]u8{0} ** 20),
        .files = files,
        .comment = null,
        .creation_date = null,
        .created_by = null,
        .raw_info = &.{},
        .url_list = null,
    };
}

test "downgradeToReadOnly: reads keep working, writes fail" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = tmp_dir.dir.realpathAlloc(allocator, ".") catch return;
    defer allocator.free(tmp_path);

    const files = [_]metainfo.FileInfo{
        .{ .length = 16384, .path = &.{"dl.bin"} },
    };
    var store = Storage.init(allocator, testMeta(&files), tmp_path, true) catch return;
    defer store.deinit();

    const data = [_]u8{0xCC} ** 16384;
    try store.writePiece(0, &data);

    store.downgradeToReadOnly();
    store.downgradeToReadOnly(); // idempotent

    const back = try store.readPiece(allocator, 0, 16384);
    defer allocator.free(back);
    try std.testing.expectEqual(@as(u8, 0xCC), back[0]);
    try std.testing.expectError(error.WriteFailed, store.writePiece(0, &data));
}

test "seed mode opens files read-only" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = tmp_dir.dir.realpathAlloc(allocator, ".") catch return;
    defer allocator.free(tmp_path);

    const files = [_]metainfo.FileInfo{
        .{ .length = 16384, .path = &.{"seed.bin"} },
    };

    // Lay the file down via a create-mode store first.
    {
        var store = Storage.init(allocator, testMeta(&files), tmp_path, true) catch return;
        defer store.deinit();
        const data = [_]u8{0xDD} ** 16384;
        try store.writePiece(0, &data);
    }

    var store = Storage.init(allocator, testMeta(&files), tmp_path, false) catch return;
    defer store.deinit();
    try std.testing.expect(store.read_only);

    const back = try store.readPiece(allocator, 0, 16384);
    defer allocator.free(back);
    try std.testing.expectEqual(@as(u8, 0xDD), back[0]);
    const data = [_]u8{0xEE} ** 16384;
    try std.testing.expectError(error.WriteFailed, store.writePiece(0, &data));
}

test "closeFiles is idempotent and safe before deinit" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = tmp_dir.dir.realpathAlloc(allocator, ".") catch return;
    defer allocator.free(tmp_path);

    const files = [_]metainfo.FileInfo{
        .{ .length = 16384, .path = &.{"done.bin"} },
    };
    var store = Storage.init(allocator, testMeta(&files), tmp_path, true) catch return;
    defer store.deinit(); // closes again via the guard — must not double-close

    const data = [_]u8{0xAB} ** 16384;
    try store.writePiece(0, &data);
    store.closeFiles();
    store.closeFiles();
}
