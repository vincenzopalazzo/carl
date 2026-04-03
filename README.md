# carl

A BitTorrent client written in pure Zig with zero external dependencies. Carl implements the core BitTorrent protocol and several extensions for decentralized peer discovery, metadata exchange, and web seeding.

## Features

- **Full BitTorrent protocol** -- peer wire protocol, choking algorithm, rarest-first piece selection, endgame mode
- **Multiple peer discovery methods** -- HTTP/HTTPS trackers, UDP trackers, DHT (distributed hash table), magnet links
- **Web seeding** -- download pieces over HTTP when peers are scarce
- **Metadata exchange** -- fetch torrent metadata from peers using the extension protocol
- **Resume support** -- verifies existing pieces on startup and continues where you left off
- **Multi-file torrents** -- single and multi-file torrent support with proper file mapping
- **Seeding** -- upload mode with incoming connection support

## Protocol Support

| BEP | Name | Description |
|-----|------|-------------|
| [3](https://www.bittorrent.org/beps/bep_0003.html) | The BitTorrent Protocol | Core peer wire protocol, handshake, messages, choking |
| [5](https://www.bittorrent.org/beps/bep_0005.html) | DHT Protocol | Kademlia DHT for decentralized peer discovery |
| [9](https://www.bittorrent.org/beps/bep_0009.html) | Extension for Peers to Send Metadata Files | `ut_metadata` for magnet link metadata download |
| [10](https://www.bittorrent.org/beps/bep_0010.html) | Extension Protocol | Standardized extension message framework |
| [12](https://www.bittorrent.org/beps/bep_0012.html) | Multitracker Metadata Extension | Tiered announce-list with failover |
| [15](https://www.bittorrent.org/beps/bep_0015.html) | UDP Tracker Protocol | Binary UDP tracker communication |
| [19](https://www.bittorrent.org/beps/bep_0019.html) | WebSeed - HTTP/FTP Seeding | HTTP piece downloads via `url-list` |

## Building

Requires **Zig 0.15+**. No other dependencies.

```sh
zig build          # compile
zig build test     # run tests
zig fmt src/       # format
```

Or using the Makefile:

```sh
make               # build
make check         # test
make install       # install to /usr/local/bin (PREFIX=/usr/local)
make fmt           # format
```

## Usage

### Download a torrent

```sh
# From a .torrent file
carl download ubuntu-24.04-desktop-amd64.iso.torrent

# From a magnet link (quote the URI to prevent shell splitting)
carl download 'magnet:?xt=urn:btih:...'

# From a URL
carl download https://archlinux.org/releng/releases/2026.04.01/torrent/

# With options
carl download file.torrent --output-dir ~/Downloads --port 6882
```

### Inspect a torrent file

```sh
carl info file.torrent
```

Output:

```
name:         archlinux-2026.04.01-x86_64.iso
announce:     udp://tracker.example.com:1337/announce
piece length: 524288
pieces:       2932
comment:      Arch Linux 2026.04.01
info hash:    157e0a57e1af0e1cfd46258ba6c62938c21b6ee8

files (1):
  archlinux-2026.04.01-x86_64.iso (1536851968 bytes)
```

### Query a tracker

```sh
carl announce file.torrent
```

### Seed existing data

```sh
carl seed file.torrent /path/to/data --port 6881
```

## Architecture

```
src/
  main.zig         CLI entry point (info, announce, download, seed)
  lib.zig          Public library module
  bencode.zig      Bencode encoder/decoder
  metainfo.zig     .torrent file parser
  magnet.zig       Magnet URI parser
  wire.zig         Peer wire protocol (handshake, messages)
  peer.zig         Per-peer TCP connection state machine
  session.zig      Central event loop, choking, piece selection
  piece.zig        Block/piece tracking and SHA-1 verification
  storage.zig      Multi-file disk I/O
  tracker.zig      HTTP/HTTPS tracker client
  udp_tracker.zig  UDP tracker client (BEP 15)
  dht.zig          Kademlia DHT (BEP 5)
  extension.zig    Extension protocol / metadata exchange (BEP 9/10)
```

### Session internals

The session manages the download lifecycle:

- **Choking algorithm** -- 4 upload slots + 1 optimistic unchoke, recalculated every 10s per BEP 3
- **Rarest-first piece selection** -- prioritizes pieces with lowest availability across connected peers
- **Endgame mode** -- when all remaining pieces are in-flight, duplicate requests are sent to multiple peers
- **Multi-tracker failover** -- tries announce-list tiers in order, falls back to DHT
- **Web seed fallback** -- downloads pieces over HTTP when peer connections are insufficient
- **Piece verification** -- SHA-1 hash check on every completed piece
- **Resume** -- on startup, existing data is verified and only missing pieces are requested

## License

[GPL-2.0](LICENSE)
