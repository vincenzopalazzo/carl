# I2P-BT tracker profile (HTTP-over-SAM)

**Status:** Carl v1 profile — speak I2P-BT as i2psnark / qBittorrent I2P do  
**Transport:** SAM v3 `STREAM CONNECT` (not SOCKS, not clearnet HTTP)  
**Closes:** P3 of [2026-06-08-i2p-transport-sam.md](../brainstorms/2026-06-08-i2p-transport-sam.md)

## Why this is not BEP 3 compact

I2P peers are destinations, not IPv4:port. A compact 6-byte peer list cannot
name them. I2P-BT therefore runs the **same HTTP announce query string** as
BEP 3 (info_hash, peer_id, port, uploaded, downloaded, left, event, compact)
but:

1. The tracker host is `.i2p` (named or `.b32.i2p`).
2. The GET is sent over an I2P stream (SAM), never a clearnet TCP socket.
3. `peers` in the response is typically **non-compact** (dictionary), with
   `ip` a destination hostname. Compact IPv4, if present, is ignored on the
   I2P route (dialing it would leak the real IP).

See [draft-hostname-peers.md](draft-hostname-peers.md) for the dictionary
`ip` = hostname rule.

## What Carl does

| Announce URL | `--route i2p` / `--i2p-seed` |
|--------------|------------------------------|
| `http://*.i2p/...` | HTTP GET over SAM STREAM |
| `https://*` | skipped (TLS-over-SAM not in v1) |
| `http://` clearnet | **skipped** (fail-closed) |
| `udp://` | **skipped** (no UDP on SAM STREAM) |

No default tracker is hard-coded. If the torrent’s `announce` / `announce-list`
contains an `http://…i2p/…` URL, Carl uses it. A common I2P-BT tracker is
`http://tracker2.postman.i2p/announce` (user/torrent supplied).

`port` in the announce is the I2CP virtual port Carl advertised (0 = destination
default, matching kind 30078 for I2P seeds).

## vs i2psnark / qBittorrent I2P

| | Carl | i2psnark / qBittorrent I2P |
|--|------|---------------------------|
| Transport | SAM v3 STREAM | I2P socket / SAM |
| Announce query | BEP 3 | BEP 3 |
| Peer in compact | ignored on i2p route | I2P-BT often non-compact |
| Peer in dict `ip` | `.b32.i2p` (and `.onion` skipped on i2p) | destination string |
| Discovery besides tracker | Nostr kind 30078 | I2P DHT + trackers |

Carl does **not** invent a second encoding. Interop is “same HTTP query, same
dict hostname peers, over I2P.”

## Mapping to kind 30078

`host` = tracker dict `ip` (the `.b32.i2p` string). `port` = announce `port`.
A leecher may find the same seed via Nostr or via an I2P tracker; both dial
`connectI2pPeer`.

## Non-goals

- I2P outproxy (I2P → clearnet HTTP).
- Announcing an I2P seed to opentrackr / any clearnet tracker.
- UDP trackers on I2P.
