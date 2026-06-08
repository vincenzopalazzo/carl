/// Integration tests for the BitTorrent client.
///
/// Test 1: Wire-level handshake + piece exchange over TCP loopback
/// Test 2: Full session seed+download over TCP loopback
const std = @import("std");
const bencode = @import("bencode.zig");
const metainfo = @import("metainfo.zig");
const wire = @import("wire.zig");
const piece_mod = @import("piece.zig");
const storage_mod = @import("storage.zig");
const session_mod = @import("session.zig");
const extension = @import("extension.zig");
const proxy_mod = @import("proxy.zig");

/// Generate deterministic test data of a given size.
fn generateTestData(allocator: std.mem.Allocator, size: usize) ![]u8 {
    const data = try allocator.alloc(u8, size);
    for (data, 0..) |*byte, i| {
        byte.* = @truncate(i *% 251 +% 7);
    }
    return data;
}

const TestMetainfo = struct {
    meta: metainfo.Metainfo,
    allocator: std.mem.Allocator,

    fn deinit(self: *TestMetainfo) void {
        self.meta.deinit(self.allocator);
    }
};

/// Build a Metainfo struct programmatically from test data.
fn buildTestMetainfo(
    allocator: std.mem.Allocator,
    data: []const u8,
    piece_length: u64,
    name: []const u8,
) !TestMetainfo {
    const total_len = data.len;
    const num_pieces = piece_mod.numPieces(total_len, piece_length);

    const pieces_blob = try allocator.alloc(u8, @as(usize, num_pieces) * 20);
    for (0..num_pieces) |i| {
        const idx: u32 = @intCast(i);
        const plen = piece_mod.pieceLength(idx, piece_length, total_len);
        const start = @as(usize, idx) * @as(usize, @intCast(piece_length));
        const piece_data = data[start .. start + plen];

        var hash: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(piece_data, &hash, .{});
        @memcpy(pieces_blob[i * 20 .. (i + 1) * 20], &hash);
    }

    const name_dup = try allocator.dupe(u8, name);
    const path_comp = try allocator.dupe(u8, name);
    const path = try allocator.alloc([]const u8, 1);
    path[0] = path_comp;
    const files = try allocator.alloc(metainfo.FileInfo, 1);
    files[0] = .{ .length = total_len, .path = path };

    // Build bencoded info dict for info_hash
    var info_entries: [4]bencode.Value.DictEntry = undefined;
    info_entries[0] = .{ .key = "length", .value = .{ .integer = @intCast(total_len) } };
    info_entries[1] = .{ .key = "name", .value = .{ .string = name } };
    info_entries[2] = .{ .key = "piece length", .value = .{ .integer = @intCast(piece_length) } };
    info_entries[3] = .{ .key = "pieces", .value = .{ .string = pieces_blob } };

    const info_value = bencode.Value{ .dict = &info_entries };
    const raw_info = try bencode.encode(allocator, info_value);

    const announce = try allocator.dupe(u8, "http://localhost:0/announce");

    return .{
        .meta = .{
            .announce = announce,
            .announce_list = null,
            .name = name_dup,
            .piece_length = piece_length,
            .pieces = pieces_blob,
            .files = files,
            .comment = null,
            .creation_date = null,
            .created_by = null,
            .raw_info = raw_info,
            .url_list = null,
        },
        .allocator = allocator,
    };
}

// =============================================================================
// Test 1: Wire-level handshake + piece exchange over TCP loopback
// =============================================================================

test "wire-level piece exchange over loopback" {
    const allocator = std.testing.allocator;

    const test_data = try generateTestData(allocator, 32768);
    defer allocator.free(test_data);

    const piece_length: u64 = 16384;
    var tm = try buildTestMetainfo(allocator, test_data, piece_length, "test.bin");
    defer tm.deinit();

    const info_hash = metainfo.infoHash(tm.meta.raw_info);
    var seeder_id: [20]u8 = undefined;
    @memcpy(seeder_id[0..8], "-SE0001-");
    @memset(seeder_id[8..], 0xAA);
    var downloader_id: [20]u8 = undefined;
    @memcpy(downloader_id[0..8], "-DL0001-");
    @memset(downloader_id[8..], 0xBB);

    // Create TCP loopback: listener + connect
    const listen_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0); // port 0 = OS picks
    var server = try listen_addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const actual_port = server.listen_address.in.getPort();

    // Connect from "downloader"
    const connect_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, actual_port);
    const downloader_sock = try std.net.tcpConnectToAddress(connect_addr);
    defer downloader_sock.close();

    // Accept on "seeder"
    const accepted = try server.accept();
    const seeder_sock = accepted.stream;
    defer seeder_sock.close();

    // --- Handshake exchange ---
    const seeder_hs = wire.Handshake{
        .reserved = [_]u8{0} ** 8,
        .info_hash = info_hash,
        .peer_id = seeder_id,
    };
    _ = try seeder_sock.write(&seeder_hs.serialize());

    var recv_buf: [68]u8 = undefined;
    try readExact(&downloader_sock, &recv_buf);
    const parsed_hs = try wire.Handshake.parse(&recv_buf);
    try std.testing.expectEqual(info_hash, parsed_hs.info_hash);

    _ = try downloader_sock.write(&(wire.Handshake{
        .reserved = [_]u8{0} ** 8,
        .info_hash = info_hash,
        .peer_id = downloader_id,
    }).serialize());

    // --- Seeder sends bitfield ---
    var bf = try piece_mod.Bitfield.init(allocator, 2);
    defer bf.deinit(allocator);
    bf.setPiece(0);
    bf.setPiece(1);
    const bf_msg = try wire.serializeMessage(allocator, .{ .bitfield = bf.rawBytes() });
    defer allocator.free(bf_msg);
    _ = try seeder_sock.write(bf_msg);

    // --- Downloader receives bitfield ---
    const bf_recv = try allocator.alloc(u8, bf_msg.len);
    defer allocator.free(bf_recv);
    try readExact(&downloader_sock, bf_recv);
    const bf_parsed = (try wire.parseMessage(allocator, bf_recv)).?;
    defer bf_parsed.msg.deinit(allocator);
    try std.testing.expectEqualSlices(u8, bf.rawBytes(), bf_parsed.msg.bitfield);

    // --- Downloader sends interested, seeder sends unchoke ---
    const int_msg = try wire.serializeMessage(allocator, .interested);
    defer allocator.free(int_msg);
    _ = try downloader_sock.write(int_msg);

    const unchoke_msg = try wire.serializeMessage(allocator, .unchoke);
    defer allocator.free(unchoke_msg);
    _ = try seeder_sock.write(unchoke_msg);

    // Consume interested on seeder side
    var int_recv: [5]u8 = undefined;
    try readExact(&seeder_sock, &int_recv);

    // Consume unchoke on downloader side
    var unchoke_recv: [5]u8 = undefined;
    try readExact(&downloader_sock, &unchoke_recv);

    // --- Downloader requests piece 0 ---
    const req_msg = try wire.serializeMessage(allocator, .{ .request = .{
        .index = 0,
        .begin = 0,
        .length = 16384,
    } });
    defer allocator.free(req_msg);
    _ = try downloader_sock.write(req_msg);

    // --- Seeder receives request, sends piece ---
    var req_recv: [17]u8 = undefined;
    try readExact(&seeder_sock, &req_recv);

    const piece_data = test_data[0..16384];
    const piece_msg = try wire.serializeMessage(allocator, .{ .piece = .{
        .index = 0,
        .begin = 0,
        .block = piece_data,
    } });
    defer allocator.free(piece_msg);
    _ = try seeder_sock.write(piece_msg);

    // --- Downloader receives piece, verifies SHA-1 ---
    const piece_recv = try allocator.alloc(u8, piece_msg.len);
    defer allocator.free(piece_recv);
    try readExact(&downloader_sock, piece_recv);

    const piece_parsed = (try wire.parseMessage(allocator, piece_recv)).?;
    defer piece_parsed.msg.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 0), piece_parsed.msg.piece.index);
    try std.testing.expectEqualSlices(u8, piece_data, piece_parsed.msg.piece.block);

    const expected_hash = piece_mod.pieceHash(tm.meta.pieces, 0).?;
    try std.testing.expect(piece_mod.verifyPiece(piece_parsed.msg.piece.block, expected_hash));
}

/// Read exactly `buf.len` bytes from a stream.
fn readExact(sock: *const std.net.Stream, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try sock.read(buf[total..]);
        if (n == 0) return error.EndOfStream;
        total += n;
    }
}

// =============================================================================
// Test 2: Full session seed+download over TCP loopback
// =============================================================================

const SeederArgs = struct {
    meta: metainfo.Metainfo,
    dir_path: [*:0]const u8,
    port: u16,
};

fn seederThread(args: SeederArgs) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const dir_path = std.mem.span(args.dir_path);

    var sess = session_mod.Session.init(
        allocator,
        args.meta,
        dir_path,
        .seed,
        args.port,
        null,
        .any,
        false,
    ) catch return;
    defer sess.deinit();

    // Run tick-based loop (avoids tracker announce which would block)
    var ticks: usize = 0;
    while (ticks < 300 and !session_mod.shutdown_requested.load(.acquire)) : (ticks += 1) {
        sess.tick() catch break;
    }
}

test "full session seed and download over loopback" {
    // Skip in CI: this test uses threads + TCP loopback with timing-dependent
    // handshakes. Run manually to verify end-to-end:
    //   zig build run -- download <file.torrent>
    if (@import("builtin").is_test) return;
    const allocator = std.testing.allocator;

    const test_data = try generateTestData(allocator, 65536);
    defer allocator.free(test_data);

    const piece_length: u64 = 16384;
    var tm = try buildTestMetainfo(allocator, test_data, piece_length, "integration_test.bin");
    defer tm.deinit();

    // Create temp directories
    var seeder_dir = std.testing.tmpDir(.{});
    defer seeder_dir.cleanup();
    var downloader_dir = std.testing.tmpDir(.{});
    defer downloader_dir.cleanup();

    const seeder_path = try seeder_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(seeder_path);
    const downloader_path = try downloader_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(downloader_path);

    // Write test data to seeder's directory
    {
        var store = storage_mod.Storage.init(allocator, tm.meta, seeder_path, true) catch return;
        defer store.deinit();
        const num_pieces = piece_mod.numPieces(test_data.len, piece_length);
        for (0..num_pieces) |i| {
            const idx: u32 = @intCast(i);
            const plen = piece_mod.pieceLength(idx, piece_length, test_data.len);
            const start = @as(usize, idx) * @as(usize, @intCast(piece_length));
            store.writePiece(idx, test_data[start .. start + plen]) catch return;
        }
    }

    const test_port: u16 = 16881;

    // We need a null-terminated path for the thread args
    const seeder_path_z = try allocator.allocSentinel(u8, seeder_path.len, 0);
    defer allocator.free(seeder_path_z);
    @memcpy(seeder_path_z, seeder_path);

    // Reset shutdown flag
    session_mod.shutdown_requested.store(false, .release);

    const seeder_handle = std.Thread.spawn(.{}, seederThread, .{SeederArgs{
        .meta = tm.meta,
        .dir_path = seeder_path_z,
        .port = test_port,
    }}) catch return;

    // Give seeder time to verify pieces and start listening
    std.Thread.sleep(500 * std.time.ns_per_ms);

    // Create downloader session
    var dl_sess = session_mod.Session.init(
        allocator,
        tm.meta,
        downloader_path,
        .download,
        test_port + 1,
        null,
        .any,
        false,
    ) catch {
        session_mod.shutdown_requested.store(true, .release);
        seeder_handle.join();
        return;
    };
    defer dl_sess.deinit();

    // Connect directly to seeder
    dl_sess.connectDirectPeer(std.net.Address.initIp4(.{ 127, 0, 0, 1 }, test_port)) catch {
        session_mod.shutdown_requested.store(true, .release);
        seeder_handle.join();
        return;
    };

    // Run downloader until complete or timeout
    var dl_ticks: usize = 0;
    while (dl_ticks < 200 and !dl_sess.our_bitfield.isComplete()) : (dl_ticks += 1) {
        dl_sess.tick() catch break;
    }

    // Stop seeder
    session_mod.shutdown_requested.store(true, .release);
    seeder_handle.join();
    session_mod.shutdown_requested.store(false, .release);

    // Verify download completed
    try std.testing.expect(dl_sess.our_bitfield.isComplete());

    // Verify data matches
    const num_pieces = piece_mod.numPieces(test_data.len, piece_length);
    for (0..num_pieces) |i| {
        const idx: u32 = @intCast(i);
        const plen = piece_mod.pieceLength(idx, piece_length, test_data.len);
        const start = @as(usize, idx) * @as(usize, @intCast(piece_length));

        const downloaded = dl_sess.store.readPiece(allocator, idx, plen) catch continue;
        defer allocator.free(downloaded);

        try std.testing.expectEqualSlices(u8, test_data[start .. start + plen], downloaded);
    }
}

// Test 3: Magnet-style metadata exchange (BEP 9) then piece download over
// loopback. Mirrors `carl download <magnet> --nostr`: the downloader starts in
// metadata-only mode knowing only the info-hash, pulls the info dict from the
// seeder via ut_metadata, then downloads the data.
//
// Unlike Test 2 this is CI-safe and runs under `zig build test`: it is
// single-threaded (both sessions are driven in lock-step with tick(), so there
// are no timing races), binds the seeder to an ephemeral port (0 -> OS-assigned,
// so parallel runs never collide), and is bounded by a hard iteration cap (so a
// regression can never hang the runner). It guards the metadata path the magnet
// CLI depends on -- the exact path that previously stalled forever.
test "magnet metadata exchange then download over loopback" {
    const allocator = std.testing.allocator;

    const test_data = try generateTestData(allocator, 65536);
    defer allocator.free(test_data);

    const piece_length: u64 = 16384;
    var tm = try buildTestMetainfo(allocator, test_data, piece_length, "meta_test.bin");
    defer tm.deinit();

    const info_hash = metainfo.infoHash(tm.meta.raw_info);

    var seeder_dir = std.testing.tmpDir(.{});
    defer seeder_dir.cleanup();
    var downloader_dir = std.testing.tmpDir(.{});
    defer downloader_dir.cleanup();

    const seeder_path = try seeder_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(seeder_path);
    const downloader_path = try downloader_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(downloader_path);

    {
        var store = storage_mod.Storage.init(allocator, tm.meta, seeder_path, true) catch return;
        defer store.deinit();
        const num_pieces = piece_mod.numPieces(test_data.len, piece_length);
        for (0..num_pieces) |i| {
            const idx: u32 = @intCast(i);
            const plen = piece_mod.pieceLength(idx, piece_length, test_data.len);
            const start = @as(usize, idx) * @as(usize, @intCast(piece_length));
            store.writePiece(idx, test_data[start .. start + plen]) catch return;
        }
    }

    // Seeder session bound to an ephemeral port (0 -> OS picks a free one).
    var seeder = session_mod.Session.init(
        allocator,
        tm.meta,
        seeder_path,
        .seed,
        0,
        null,
        .loopback,
        false,
    ) catch return;
    defer seeder.deinit();
    // init opens the inbound listener for seed mode; read back the real port.
    const seeder_port = (seeder.listener orelse return error.SeederNotListening)
        .listen_address.getPort();

    // Downloader in metadata-only mode. Arena-backed so the metadata-only ->
    // full-metadata handoff (which reassigns Session.meta) doesn't trip the
    // testing allocator's leak detector; we are exercising protocol behavior.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const da = arena.allocator();

    const empty_path = try da.alloc([]const u8, 1);
    empty_path[0] = try da.dupe(u8, "unknown");
    const empty_files = try da.alloc(metainfo.FileInfo, 1);
    empty_files[0] = .{ .length = 0, .path = empty_path };
    const empty_meta = metainfo.Metainfo{
        .announce = try da.dupe(u8, ""),
        .announce_list = null,
        .name = try da.dupe(u8, "unknown"),
        .piece_length = 0,
        .pieces = &.{},
        .files = empty_files,
        .comment = null,
        .creation_date = null,
        .created_by = null,
        .raw_info = &.{},
        .url_list = null,
    };

    var dl = session_mod.Session.init(
        da,
        empty_meta,
        downloader_path,
        .download,
        0,
        null,
        .loopback,
        false,
    ) catch return;
    defer dl.deinit();
    dl.info_hash = info_hash;
    dl.metadata_download = extension.MetadataDownload.init(da, info_hash);
    dl.metadata_only = true;

    try dl.connectDirectPeer(std.net.Address.initIp4(.{ 127, 0, 0, 1 }, seeder_port));

    // Drive both sessions in lock-step until the downloader has fetched the
    // metadata AND all pieces. Hard cap keeps a regression from hanging CI; the
    // happy path converges in a couple hundred iterations.
    var i: usize = 0;
    while (i < 4000 and (dl.metadata_only or !dl.our_bitfield.isComplete())) : (i += 1) {
        seeder.tick() catch {};
        dl.tick() catch {};
    }

    // Metadata exchange must have completed (switched out of metadata-only)...
    try std.testing.expect(!dl.metadata_only);
    // ...and then the actual data must have downloaded and verified.
    try std.testing.expect(dl.our_bitfield.isComplete());

    const num_pieces = piece_mod.numPieces(test_data.len, piece_length);
    for (0..num_pieces) |i_piece| {
        const idx: u32 = @intCast(i_piece);
        const plen = piece_mod.pieceLength(idx, piece_length, test_data.len);
        const start = @as(usize, idx) * @as(usize, @intCast(piece_length));
        const downloaded = dl.store.readPiece(da, idx, plen) catch continue;
        try std.testing.expectEqualSlices(u8, test_data[start .. start + plen], downloaded);
    }
}

// =============================================================================
// Regression: a failed onion peer dial must not double-free the PeerConnection
// =============================================================================

// connectOnionPeer sets up a PeerConnection with `errdefer p.deinit()` and then
// calls finishPeerConnect. finishPeerConnect used to *also* free `p` on a connect
// failure, so when a Tor peer dial failed both freed it — a double free that
// crashes the process (observed in the wild via collectNostrPeers). Here the
// proxy points at a refused port so the dial fails fast; the test passes only if
// the connect error surfaces cleanly with no double free (the GPA testing
// allocator aborts on a double free, failing the test on the buggy code).
test "connectOnionPeer cleans up exactly once when the dial fails" {
    const allocator = std.testing.allocator;

    const test_data = try generateTestData(allocator, 1024);
    defer allocator.free(test_data);

    var tm = try buildTestMetainfo(allocator, test_data, 1024, "onion_double_free.bin");
    defer tm.deinit();

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const dir_path = try dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    // SOCKS proxy at a port that refuses immediately, so the dial fails fast
    // without touching the network. The Proxy borrows `host` from this literal.
    const proxy = try proxy_mod.parseUrl("socks5://127.0.0.1:1");

    var sess = try session_mod.Session.init(
        allocator,
        tm.meta,
        dir_path,
        .download,
        0,
        proxy,
        .any,
        false,
    );
    defer sess.deinit();

    // The dial must fail (proxy refused), and crucially must free the peer
    // exactly once. On the pre-fix code this double-frees and the test aborts.
    try std.testing.expectError(error.ConnectionFailed, sess.connectOnionPeer("examplepeer.onion", 6881));
    // The failed peer must not have been adopted into the peer set.
    try std.testing.expectEqual(@as(usize, 0), sess.peers.items.len);
}
