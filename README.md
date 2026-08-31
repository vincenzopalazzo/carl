# carl

A BitTorrent client written in pure Zig. The BitTorrent core has zero Zig package dependencies; the optional Nostr integration vendors [libsecp256k1](https://github.com/bitcoin-core/secp256k1) (C) for BIP-340 Schnorr signatures.

## Features

- **Full BitTorrent protocol** -- peer wire protocol, choking algorithm, rarest-first piece selection, endgame mode
- **Multiple peer discovery methods** -- HTTP/HTTPS trackers, UDP trackers, DHT (distributed hash table), magnet links
- **Web seeding** -- download pieces over HTTP when peers are scarce
- **Metadata exchange** -- fetch torrent metadata from peers using the extension protocol
- **Resume support** -- verifies existing pieces on startup and continues where you left off
- **Multi-file torrents** -- single and multi-file torrent support with proper file mapping
- **Seeding** -- upload mode with incoming connection support
- **Proxy / anonymous mode** -- route peers and trackers through a SOCKS5/SOCKS5h or HTTP proxy, hiding your real IP from the swarm ([docs](docs/proxy.md))
- **Nostr discovery** -- publish torrents you seed as NIP-35 events and find others' torrents via `carl search`; per-seeder peer-announces over a custom kind 30078 feed peers into download sessions
- **Shared drives over Nostr** -- sync a folder across machines and people: publishers watch a directory, subscribers mirror it and re-seed, converging on every edit via a custom kind 30035 drive index ([docs](docs/drive.md))

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

### Nostr (optional discovery layer)

| Spec | Purpose |
|------|---------|
| [NIP-01](https://github.com/nostr-protocol/nips/blob/master/01.md) | Events, relay protocol, REQ/EVENT/CLOSE messages |
| [NIP-19](https://github.com/nostr-protocol/nips/blob/master/19.md) | bech32 encoding (`npub`, `nsec`, `note`) |
| [NIP-35](https://github.com/nostr-protocol/nips/blob/master/35.md) | Kind 2003 torrent index events |
| custom kind 30078 | Carl's NIP-33-parameterized peer-announce events (one per `(pubkey, infohash)`) |
| custom kind 30035 | Carl's NIP-33-parameterized drive-index events (one per `(pubkey, drive)`) |

## Building

Requires **Zig 0.16.0**, matching the version pinned in CI and `build.zig.zon`.
The build fetches `libsecp256k1`
via `build.zig.zon` on first run; everything else is pure Zig.

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

Without `--output-dir`, downloads land in carl's **work dir** — the single
download + seed directory shared by the CLI, the daemon, and the desktop app:
`$CARL_DIR` if set, else the download folder picked in the app's Settings,
else `~/Downloads/carl`. Anything in that directory can be reseeded directly:
`carl seed <file.torrent>` (no data-dir needed) and the desktop app both read
from it, and finished downloads keep seeding from it.

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

# data-dir omitted: seeds from the shared carl work dir (~/Downloads/carl),
# where downloads land — drop a file there to reseed it
carl seed file.torrent
```

### Anonymous mode (proxy)

Route peers and trackers through a SOCKS5/SOCKS5h or HTTP proxy with `--proxy`:

```sh
# SOCKS5 with remote DNS (recommended -- no DNS leak)
carl download file.torrent --proxy socks5h://127.0.0.1:1080

# With authentication
carl download file.torrent --proxy socks5h://user:pass@127.0.0.1:1080

# HTTP CONNECT proxy
carl announce file.torrent --proxy http://127.0.0.1:3128
```

When a proxy is set, carl fails closed: DHT, UDP trackers, web seeds, and the
incoming listener are disabled so nothing bypasses the proxy. `http://` and
`https://` trackers are tunneled (HTTPS runs cert-verified TLS over the proxied
stream); UDP trackers are not. See [docs/proxy.md](docs/proxy.md) for proxy
setup on Linux/macOS and how to verify there are no leaks.

### Discover torrents on Nostr

```sh
# Generate a keypair (written to ~/.config/carl/nsec with 0600 perms)
carl nostr-keygen

# Search public relays for kind-2003 torrent events
carl search "ubuntu" --limit 20

# Use a specific relay
carl search "linux iso" --relay wss://relay.damus.io
```

### Seed and announce on Nostr

```sh
# Publish a NIP-35 (kind 2003) torrent event and a kind 30078 peer-announce
# every time you start seeding. Peers using `carl download --nostr` will see
# your announce and dial you directly.
carl seed file.torrent /path/to/data --nostr --external-ip 203.0.113.7 \
    --description "My release notes"
```

### Seed behind Tor (hidden service)

Requires a running `tor` with ControlPort and cookie auth (default
`127.0.0.1:9051`, cookie at `~/.tor/control_auth_cookie`):

```sh
carl seed file.torrent /path/to/data --tor-seed --nostr \
    --description "Seeded over Tor"

# Leechers must use Tor SOCKS (remote DNS)
carl download file.torrent --nostr --proxy socks5h://127.0.0.1:9050
```

Carl creates an ephemeral v3 onion, listens on `127.0.0.1`, and publishes the
`.onion` endpoint in kind 30078 (no public IPv4). Leechers dial the onion via
`--proxy socks5h://127.0.0.1:9050`. Tracker/DHT announces are disabled so your
real IP is not leaked to trackers.

Full details (proxy split, security, E2E test, troubleshooting):
[docs/tor-hidden-service.md](docs/tor-hidden-service.md).

#### Keeping relay traffic off clearnet

With `--proxy`, relay connections are tunneled too, so the relay never learns
your real IP:

- `wss://` relays run cert-verified TLS on top of the proxied stream -- the
  proxy only ever sees ciphertext. Works with public relays over Tor.
- `ws://` relays (e.g. a relay's `.onion` address) ride the SOCKS tunnel
  directly; Tor secures the plaintext WebSocket. CA verification is skipped for
  `.onion` hosts since Tor authenticates the address.

```sh
# Public wss relay, fully over Tor:
carl search "ubuntu" --relay wss://nos.lol --proxy socks5h://127.0.0.1:9050

# Onion relay (clearnet never touched at all):
carl search "ubuntu" --relay ws://<relay-v3-address>.onion \
    --proxy socks5h://127.0.0.1:9050
```

Relays default to `~/.config/carl/relays` (one URL per line) when not passed
explicitly. See [issue #30](https://github.com/vincenzopalazzo/carl/issues/30).

### Download using Nostr peer-discovery

```sh
# Subscribes to kind 30078 events filtered by infohash and dials IPv4 or
# `.onion` peers (onion requires --proxy socks5h://…). Routable IPv4 only.
carl download file.torrent --nostr
```

The relay list lives at `~/.config/carl/relays` (one URL per line, `#` for
comments); if absent, carl falls back to three well-known public relays.

**Privacy note:** publishing peer-announce events ties your Nostr pubkey to
the infohashes you seed. If that bothers you, generate a fresh key per
seeding session and don't share it.

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
  proxy.zig        SOCKS5/SOCKS5h + HTTP CONNECT proxy tunneling

  # Nostr (optional discovery layer)
  secp.zig         BIP-340 Schnorr wrapper over vendored libsecp256k1
  ws.zig           Minimal RFC 6455 WebSocket client (wss via std.http.Client)
  nostr.zig        NIP-01 events, canonical id hashing, sign/verify, filters
  nip19.zig        Bech32 codec for npub/nsec/note + TLV decoder
  nip35.zig        Kind 2003 torrent index event builder/parser
  peer_announce.zig  Kind 30078 peer-announce builder/parser + IP safety filter
  tor_control.zig  Tor ControlPort ADD_ONION / DEL_ONION for v3 hidden services
  relay.zig        Connect to a relay, subscribe-collect-until-EOSE, publish-and-wait
  nostr_config.zig  ~/.config/carl/{nsec,relays} read/write
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

## Links

- Source & releases: https://github.com/vincenzopalazzo/carl
- Listed on [nostrapps.com](https://nostrapps.com/) (Nostr apps directory)

## License

[GPL-2.0](LICENSE)
