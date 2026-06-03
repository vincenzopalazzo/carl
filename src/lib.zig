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
pub const secp = @import("secp.zig");
pub const ws = @import("ws.zig");
pub const nip19 = @import("nip19.zig");
pub const nostr = @import("nostr.zig");

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
    _ = secp;
    _ = ws;
    _ = nip19;
    _ = nostr;
    _ = @import("integration_test.zig");
}
