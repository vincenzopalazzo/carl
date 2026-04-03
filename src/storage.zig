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
        errdefer allocator.free(starts);
        const lengths = allocator.alloc(u64, files.len) catch return error.OutOfMemory;

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
    pub fn mapRange(self: FileMap, torrent_offset: u64, length: u64, scratch: []FileSlice) []FileSlice {
        var start = torrent_offset;
        var remaining = length;
        var count: usize = 0;

        // Find starting file
        var fi: usize = 0;
        while (fi < self.num_files) : (fi += 1) {
            if (self.file_starts[fi] + self.file_lengths[fi] > start) break;
        }

        while (remaining > 0 and fi < self.num_files and count < scratch.len) {
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

        var opened: usize = 0;
        errdefer {
            for (handles[0..opened]) |h| h.close();
            allocator.free(handles);
        }

        const dir = std.fs.cwd().openDir(output_dir_path, .{}) catch return error.FileOpenFailed;

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
                // Preallocate file size
                handles[i].setEndPos(file_info.length) catch return error.WriteFailed;
            } else {
                handles[i] = dir.openFile(path, .{ .mode = .read_write }) catch return error.FileOpenFailed;
            }
            opened += 1;
        }

        return .{
            .allocator = allocator,
            .file_map = fm,
            .handles = handles,
            .piece_len = meta.piece_length,
        };
    }

    pub fn deinit(self: *Storage) void {
        for (self.handles) |h| h.close();
        self.allocator.free(self.handles);
        self.file_map.deinit(self.allocator);
    }

    /// Write a verified piece to disk.
    pub fn writePiece(self: *Storage, index: u32, data: []const u8) IoError!void {
        const torrent_offset = @as(u64, index) * self.piece_len;
        var scratch: [64]FileSlice = undefined;
        const slices = self.file_map.mapRange(torrent_offset, data.len, &scratch);

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
        const torrent_offset = @as(u64, index) * self.piece_len;
        const buf = allocator.alloc(u8, length) catch return error.OutOfMemory;
        errdefer allocator.free(buf);

        var scratch: [64]FileSlice = undefined;
        const slices = self.file_map.mapRange(torrent_offset, length, &scratch);

        var buf_pos: usize = 0;
        for (slices) |s| {
            const chunk_len = std.math.cast(usize, s.length) orelse return error.ReadFailed;
            const bytes_read = self.handles[s.file_index].pread(buf[buf_pos .. buf_pos + chunk_len], s.file_offset) catch return error.ReadFailed;
            if (bytes_read != chunk_len) return error.ReadFailed;
            buf_pos += chunk_len;
        }

        return buf;
    }
};

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
    const slices = fm.mapRange(100, 200, &scratch);
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
    const slices = fm.mapRange(50, 150, &scratch);
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
    const slices = fm.mapRange(5, 20, &scratch);
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
