# carl daemon API

`carl daemon` runs a small HTTP + WebSocket server that the desktop GUI (a
Tauri shell wrapping the design prototype) talks to. It is the backend half of
the desktop app; the frozen JSON contract below lets the frontend be built and
the real `session.zig` wiring be filled in independently.

This is the first increment: the **download path** is wired to a real
`TorrentManager` over `session.zig` (magnet / `.torrent` / HTTP URL, routed
direct or through a SOCKS proxy), Discover search hits real Nostr relays, and
identity/relays/settings read the real config. See **Not yet wired** at the end.

## Running

```sh
carl daemon [--port p] [--bt-port p] [--route direct|proxy|tor] [--socks url] \
            [--download-dir d] [--token tok] [--parent-pid pid] \
            [--tor-control host:port] [--tor-cookie path] [--tor-onion-port p]
```

- `--tor-control` (default `127.0.0.1:9051`) / `--tor-cookie` (default
  `~/.tor/control_auth_cookie`) / `--tor-onion-port` (default `80`): Tor
  ControlPort settings used to create the hidden service for a `tor`-route seed
  (`POST /api/seeds` with `X-Carl-Route: tor`). Tor must have its ControlPort
  enabled with cookie auth.

- `--parent-pid`: when set (the desktop shell passes its own PID), a watchdog
  shuts the daemon down if that process dies — so a hard-killed app never leaves
  an orphaned daemon holding the port.

- Binds **127.0.0.1 only**. Never exposed off the loopback interface.
- `--port` (default `8088`): the HTTP/WebSocket port.
- `--bt-port` (default `6881`): the BitTorrent listen port sessions use.
- `--route` / `--socks`: default route for new transfers and the SOCKS endpoint
  (`proxy` and `tor` both tunnel through `--socks`; default
  `socks5h://127.0.0.1:9050`).
- `--token`: shared secret. If omitted, a random 32-hex token is generated and
  printed. The startup banner is stable and machine-readable:

  ```
  carl daemon
  listen: http://127.0.0.1:8088
  token: <hex>
  route: direct
  ```

  The Tauri sidecar parses the `token:` line and presents it on every request.

## Persistence

The daemon persists its transfers, seeds, and editable settings (route +
download dir) to a **SQLite** database, `<config>/carl.db`, rewritten in a
single transaction on every change (add/remove/settings) — so a crash or
restart loses nothing (verified across `kill -9`). On startup it replays that
state. Transfers are stored as re-create *specs* (kind + source + route +
nostr), not live session state.

For true resume, once a magnet's metadata completes the daemon writes the
resolved `.torrent` next to the data (`<download_dir>/<infohash>.carl.torrent`)
and repoints that transfer's persisted source at it — so after a restart a
finished download comes back as a **complete** torrent (the session verifies the
on-disk pieces) rather than re-fetching metadata. Relays/identity persist
separately via `nostr_config`.

## Authentication

Every request must present the token, or the daemon answers `401`:

- REST: header `X-Carl-Token: <token>`.
- WebSocket: `?token=<token>` query parameter (browsers can't set custom headers
  on the WebSocket handshake).

`OPTIONS` (CORS preflight) is answered `204` without a token. Responses send
permissive CORS headers (`Access-Control-Allow-Origin: *`); the token, not CORS,
is the security boundary, and the daemon is loopback-only.

## REST endpoints

All responses are `application/json` with `Connection: close`.

### `GET /api/state`

The combined initial-load payload (and the per-tick WebSocket push). Object:

```jsonc
{
  "transfers": [Transfer],
  "seeds":     [Seed],
  "relays":    [Relay],
  "proxy":     ProxyHealth,
  "identity":  Identity,
  "settings":  Settings
}
```

`ProxyHealth` reports the SOCKS proxy's reachability on the proxy/tor route:

```jsonc
{
  // "disabled"  — direct route, no proxy configured
  // "checking"  — before the first probe lands
  // "ok"        — reachable and speaks SOCKS5
  // "not_running" — connection refused (e.g. Tor isn't running)
  // "timeout"   — connect/greeting timed out
  // "rejected"  — reachable but not SOCKS5 / no acceptable auth method
  "state": "ok",
  "endpoint": "socks5h://127.0.0.1:9050",
  "detail": ""   // e.g. "SOCKS5 replied 0xff" when state == "rejected"
}
```

### `GET /api/transfers` → `[Transfer]`
### `GET /api/seeds` → `[Seed]`
### `GET /api/relays` → `[Relay]`

A background prober refreshes relay reachability every ~30s (open + close a
connection per relay, through the configured route), so `state` reflects real
`connected` / `unreachable` status rather than just `configured`. The same
prober classifies the SOCKS proxy each cycle (a SOCKS5 method-negotiation
greeting only — no CONNECT, so it opens no upstream connection) and publishes
`proxy`. All of this rides in `GET /api/state` and the WebSocket push.
### `GET /api/identity` → `Identity`
### `GET /api/settings` → `Settings`

### `POST /api/transfers`

Body: `{ "source": "<magnet|.torrent path|http(s) url>", "route": "direct|proxy|tor", "nostr": bool }`.
Adds and starts a transfer. Returns `{ "id": "t<N>" }`. `400` on a bad source.

**Long-running POSTs (`/api/transfers`, `/api/seeds`, `/api/torrents`)** may
block for minutes while the daemon builds an anonymized network session (Tor
hidden service, I2P SAM tunnels) or hashes a large file. While one is in
flight the daemon emits interim `102 Processing` responses every ~20s before
the final response — required so WebKit-based clients (the Tauri shell's
WKWebView kills any request idle for ~60s with `TypeError: Load failed`)
survive slow session setup. Any compliant HTTP client already ignores 1xx
interims; curl and the CLI are unaffected.

### `DELETE /api/transfers/<id>`

Stops and removes a transfer. `204` on success, `404` if unknown.

### `POST /api/seeds`

Create a torrent from a file and start seeding it. The request **body is the
raw file content** (so a browser drag-drop or the Tauri shell can upload
directly); metadata rides in headers:

- `X-Carl-Filename` (required) — the file name (basename only; path components
  are stripped).
- `X-Carl-Route` — `direct|proxy|tor` (default `tor`).
- `X-Carl-Nostr` — `true|false`; when true, publishes a NIP-35 torrent event so
  it's discoverable.

The daemon writes the file into the download dir, hashes it into a torrent
in-process (no external tool), and seeds it. Returns `{ "id": "t<N>" }`. Bodies
are capped at 256 MiB.

On the **`tor` route** the daemon stands up a v3 Tor hidden service for the seed
(via Tor's ControlPort, same as `carl seed --tor-seed`) and publishes a
kind-30078 **onion peer-announce** alongside the NIP-35 metadata — so a Tor
downloader can actually discover *and* dial the seeder. The seed's `.onion` is
returned in the `Seed.onion` field. This requires Tor's ControlPort to be
reachable; if it isn't, the request fails `400` with
`{ "error": "Tor hidden service setup failed: …" }`. `direct`/`proxy` seeds
publish only the discoverable NIP-35 metadata (no routable endpoint to announce).

### `GET /api/follows` → `[Follow]`

The followed publishers (see `docs/follow.md`) with their mirrored torrents and
live per-torrent phase/progress. Also included in `GET /api/state` and the
WebSocket push under `follows`.

### `POST /api/follows`

Body: `{ "pubkey": "<npub1…|64-char hex>", "route": "direct|i2p" }` (`route`
defaults to the configured route when it's one of those, else `direct`).
Follows the publisher: a mirror worker downloads everything that pubkey
announces via NIP-35 and reseeds it, publishing the mirror's own kind-30078
peer-announce under the local identity. Mirror data lands in
`<downloadDir>/follow-<pubkey prefix>`. Returns `{ "id": "f<N>" }`; `400` with
`{ "error": … }` on a malformed pubkey, an unsupported route, or a duplicate
follow. Follows persist and are restored on restart (resuming from
checkpointed torrents).

### `DELETE /api/follows/<id>`

Unfollow: stops the mirror worker (joins its threads — may take a few seconds
if a relay query is mid-flight). Mirrored data stays on disk. `204` on
success, `404` if unknown.

### `POST /api/search`

Body `{ "query": "<text>" }` (or `?q=<text>`). Searches configured Nostr relays
for NIP-35 (kind-2003) torrent events, client-side filtered by title/description.
Returns `[DiscoverResult]`. Routed through the proxy when the route isn't direct.

### `POST /api/settings`

Body may contain any subset of:

- `"route": "direct|proxy|tor"` — default route for new transfers.
- `"downloadDir": "<path>"` — where new transfers download (created if needed;
  existing transfers keep their directory).
- `"relays": ["wss://…", "ws://…onion"]` — replaces the relay list, persisted to
  the carl config so search, peer-announce, and the CLI all use it. The
  background prober picks up the change on its next cycle.

Echoes back the full `Settings`. `listenPort` / `maxActive` / `peerLimit` remain
read-only in this increment.

## WebSocket — `GET /ws?token=<token>`

Upgrades to a WebSocket and pushes a `GET /api/state` snapshot as a text frame
**once per second** — the "live-ish" progress the prototype shows, driven by
real session counters (download/upload rates are recomputed each tick). The
daemon does not read client frames; closing the socket ends the push.

## Types

`Transfer`:

```jsonc
{
  "id": "t1", "name": "...", "hash": "<40-hex|''>", "magnet": "magnet:?...|''",
  "status": "downloading|seeding|complete|metadata|stalled|connecting|no_peers",
  "route": "direct|proxy|tor",
  "sources": ["tracker"|"dht"|"nostr", ...],
  "pct": 0-100, "size": <bytes>|null,
  "down": <bytes/s>, "up": <bytes/s>, "eta": "1m 48s|—|stalled",
  "peers": <n>, "seeds": <n>,
  // BEP 9 metadata bootstrap progress (magnet only); both 0 once metadata is in.
  "metaHave": <n>, "metaTotal": <n>,
  "ratio": <float>|null, "onion": "<addr>"|null
}
```

`Peer` (Peers detail tab — see Not yet wired): `{ addr, port, client, down, up, pct, flags, onion }`.
`FileEntry` (Files tab): `{ name, size, pct, prio }`.
`Source` (Sources tab): `{ kind, label, state, detail, interval }`.
`DiscoverResult`: `{ id, title, hash, size, files, trackers, desc, verified, relays:[url], author, age }`.
`Relay`: `{ url, state: "connected|connecting|unreachable|configured", net: "clearnet|tor", events }`.
`Seed`: `{ id, name, visibility, onion|null, size, upTotal, up, leechers, ratio, relays }`.
`Follow`: `{ id, npub, route, dir, seeding, downloading, failed, torrents:[FollowTorrent] }`.
`FollowTorrent`: `{ name, hash, state: "starting|downloading|seeding|failed", pct, peers, down, up }`.
`Identity`: `{ npub: "<bech32|''>" }` — the nsec is **never** serialized.
`Settings`: `{ route, socks, relays:[url], downloadDir, listenPort, maxActive, peerLimit, publishNip35 }`.

## Not yet wired (follow-ups)

These are part of the contract but return empty / derived values until later PRs:

- **Per-transfer detail tabs** (`Peer` rows, the piece heatmap, per-file
  progress, `Source` rows). `session.zig` mutates its `peers`/`active_pieces`
  collections on its own thread; exposing them safely requires the session to
  publish a locked snapshot. Until then `GET /api/transfers/<id>/peers` etc. are
  not served, and snapshots expose transfer-level state only (peer *count*, real
  `pct` from the bitfield, real rates).
- **"Seed a file" creation flow** — creating a torrent from a local file and Tor
  hidden-service generation. `seeds()` currently reflects transfers that have
  reached the seeding state.
- **Per-relay event counts** — relay reachability is now probed live (see
  `GET /api/relays`), but `events` is still reported as `0`; surfacing real
  per-relay event throughput is a follow-up.
