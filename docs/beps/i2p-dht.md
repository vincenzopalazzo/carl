# I2P DHT (follow-up wire)

**Status:** specified, **not implemented** in this series  
**Why deferred:** I2P DHT is a separate overlay (not BEP 5). Shipping a
half-wired BEP 5 announce over SAM DATAGRAM would not interop with
i2psnark/qBittorrent and would risk UDP-shaped traffic on the wrong network.

P4 of [2026-06-08-i2p-transport-sam.md](../brainstorms/2026-06-08-i2p-transport-sam.md).

## What BEP 5 is not

BEP 5 `get_peers` / `announce_peer` values are compact IPv4 (BEP 32: IPv6).
A `.b32.i2p` destination does not fit. Tor hidden seeds likewise must not
join the **clearnet** DHT (`tor_hidden` / `anonymized()` stay on).

I2P-BT DHT (i2psnark, qBittorrent I2P) stores **destinations** in an I2P
Kademlia overlay, typically over I2P datagrams — not SAM STREAM and not
BEP 5 UDP to router.bittorrent.com.

## Wire Carl should speak later

Until the I2P-BT DHT packet layout is confirmed against qBittorrent/i2psnark
(open question in the 2026-08-31 brainstorm):

1. Do **not** call `tryDhtPeerDiscovery` / `announce_peer` on `--route i2p`
   or `--tor-seed`.
2. Discovery until then: Nostr kind 30078 + I2P HTTP tracker (P3).
3. Implementation belongs in a dedicated module (`src/i2p_dht.zig`), not a
   branch of `src/dht.zig` that reuses compact values.

## Success criteria for the follow-up commit

- `get_peers` / `announce_peer` over I2P datagrams (or the I2P-BT equivalent)
  without any clearnet UDP.
- Peers returned as `.b32.i2p` (+ port) and dialed with `connectI2pPeer`.
- Unit tests against a mock datagram peer; live i2pd interop documented in
  `docs/i2p.md`.
- `zig build test` still green with the I2P DHT code compiled in but idle on
  `direct` / `proxy` / `tor`.
