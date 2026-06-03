# Pubky discovery in carl

Carl can publish and discover torrents over [Pubky](https://pubky.org/tldr/) alongside Nostr. Pubky uses Ed25519 identity, HTTP homeservers, and optional [Nexus](https://nexus.pubky.app/swagger-ui/) indexing.

## Quick start

```sh
# Generate Ed25519 identity + register on default testnet homeserver
carl pubky-keygen

# Search Nexus for carl.app torrent index files
carl search "ubuntu" --pubky --limit 10

# Seed and publish torrent + peer announce JSON
carl seed file.torrent /data --pubky --external-ip 203.0.113.7

# Download with Pubky peer discovery (combine with --nostr)
carl download file.torrent --pubky
carl download file.torrent --nostr --pubky
```

## Config (`~/.config/carl/`)

| File | Purpose |
|------|---------|
| `pubky_secret` | Hex-encoded 32-byte Ed25519 secret (mode 0600) |
| `pubky_homeserver` | Homeserver public key (z32); defaults to Pubky testnet |
| `pubky_nexus` | Nexus base URL (default `https://nexus.pubky.app`) |

Nostr keys (`nsec`, `relays`) are separate — Pubky does not share Nostr's secp256k1 key.

## Data layout on homeservers

```
/pub/carl.app/torrents/{infohash_hex}.json   # torrent metadata (NIP-35-like fields)
/pub/carl.app/announces/{infohash_hex}.json  # replaceable peer endpoint
```

Peer announce JSON uses `endpoint.type` of `ipv4` or `onion` (same safety rules as Nostr kind 30078).

## Tor

```sh
carl seed file.torrent /data --tor-seed --pubky
carl download file.torrent --pubky --proxy socks5h://127.0.0.1:9050
```

`--tor-seed` requires `--nostr` or `--pubky`.

## Build requirements

Pubky support links a small Rust FFI crate:

```sh
# builds native/carl_pubky_bridge via cargo automatically
zig build

# disable Pubky (Zig-only, no cargo):
zig build -Dpubky=false
```

CI installs stable Rust before `zig build test`.

## Nexus search note

Nexus is optimized for social data; carl queries `/v0/files/search` and filters paths under `/pub/carl.app/torrents/`. If your indexer uses a different route, set `pubky_nexus` or extend `src/nexus.zig`.