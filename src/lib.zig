pub const bencode = @import("bencode.zig");
pub const metainfo = @import("metainfo.zig");
pub const tracker = @import("tracker.zig");
pub const udp_tracker = @import("udp_tracker.zig");
pub const wire = @import("wire.zig");
pub const piece = @import("piece.zig");
pub const storage = @import("storage.zig");
pub const peer = @import("peer.zig");
pub const session = @import("session.zig");
pub const magnet = @import("magnet.zig");
pub const extension = @import("extension.zig");
pub const dht = @import("dht.zig");

test {
    _ = bencode;
    _ = metainfo;
    _ = tracker;
    _ = udp_tracker;
    _ = wire;
    _ = piece;
    _ = storage;
    _ = peer;
    _ = magnet;
    _ = extension;
    _ = dht;
    _ = @import("integration_test.zig");
}
