# Kind 30078 ↔ tracker dictionary `ip`

Carl’s Nostr peer-announce (kind 30078, NIP-33 parameterized replaceable)
and a BEP 3 dictionary tracker peer name the **same endpoint**.

## Bijection

| Kind 30078 | Tracker dict peer | Dial |
|------------|-------------------|------|
| `d` = infohash hex | torrent info-hash (announce query) | — |
| `host` = v3 `.onion` | `ip` = same string | `connectOnionPeer` (SOCKS5h) |
| `host` = `.b32.i2p` | `ip` = same string | `connectI2pPeer` (SAM) |
| `port` | `port` | virtual port; I2P `0` = default |
| `ip` = IPv4 (legacy) | `ip` = dotted quad | TCP / SOCKS |

`host` **wins** over `ip` when both are present (no clearnet smuggle).

## What this is not

Kind 30078 is **not** a BEP. Public compact trackers will not grow a `host`
tag. Hidden seeds still publish 30078 so Carl leechers find them without a
tracker. I2P-BT trackers are an additional path for i2psnark/qBittorrent
interop ([i2p-bt-tracker.md](i2p-bt-tracker.md)).

## Code

`src/peer_announce.zig` — `buildOnion` / `buildI2p` / `parse`.  
`src/tracker.zig` — dictionary `ip` hostname peers.  
`src/session.zig` — same dial helpers for both sources.
