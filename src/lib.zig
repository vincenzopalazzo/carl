pub const bencode = @import("bencode.zig");
pub const metainfo = @import("metainfo.zig");
pub const tracker = @import("tracker.zig");
pub const wire = @import("wire.zig");
pub const piece = @import("piece.zig");
pub const storage = @import("storage.zig");
pub const peer = @import("peer.zig");
pub const session = @import("session.zig");

test {
    _ = bencode;
    _ = metainfo;
    _ = tracker;
    _ = wire;
    _ = piece;
    _ = storage;
    _ = peer;
    // session tests require network, skip in CI
}
