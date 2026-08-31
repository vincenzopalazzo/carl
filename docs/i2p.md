# Using carl over I2P

carl can route BitTorrent transport over **I2P**, a peer-to-peer anonymity
network purpose-built for P2P traffic. Unlike Tor — which is discouraged for
BitTorrent (slow, hard on the Tor network, leak-prone if misconfigured) — I2P
is designed for swarms and has a mature torrenting ecosystem.

Peers are addressed by **`.b32.i2p` destinations** (not IP:port). carl speaks
**SAM v3** to a local I2P router and dials each peer as a destination, the same
way the Tor path dials `.onion` hostnames.

> **Status (P1 + P2):** carl can both **leech** (outbound) and **seed**
> (inbound) over native SAM. A seed opens a SAM `STREAM FORWARD` to a loopback
> listener and is reachable at a stable `.b32.i2p` destination (its private key
> is persisted under `<config>/i2p-seeds/`, so the address survives restarts).
> I2P trackers and the I2P DHT remain tracked follow-ups (see issue #35); peers
> are discovered via carl's Nostr peer-announce layer (a `.b32.i2p` destination
> is carried like a `.onion` host).

## Prerequisites: a running I2P router with SAM

carl does **not** embed an I2P router; it connects to the SAM bridge of one you
run, exactly like the Tor path expects a running Tor daemon.

### i2pd (recommended, lightweight C++)

```sh
# macOS
brew install i2pd

# Enable the SAM bridge in i2pd.conf (usually ~/.i2pd/i2pd.conf or
# /opt/homebrew/etc/i2pd/i2pd.conf):
[sam]
enabled = true
address = 127.0.0.1
port = 7656

i2pd            # start the router
```

### Java I2P

In the router console (http://127.0.0.1:7657) → **I2P Internals → Clients**,
ensure the **SAM application bridge** is enabled and set to start. It listens on
`127.0.0.1:7656` by default.

Give the router a few minutes after first start to integrate into the network
before expecting connections.

Verify the bridge is reachable:

```sh
nc -z 127.0.0.1 7656 && echo "SAM bridge up"
```

## Running carl on the I2P route

The I2P transport is a daemon **route** (like `direct` / `proxy` / `tor`):

```sh
carl daemon --route i2p --i2p-sam 127.0.0.1:7656
```

- `--route i2p` makes the daemon dial peers over native I2P (SAM v3).
- `--i2p-sam host:port` points at your router's SAM bridge
  (default `127.0.0.1:7656`; you may also write `sam://127.0.0.1:7656`).

### Seeding over I2P

Seeding works on the i2p route too: carl opens a SAM `STREAM FORWARD` so the
router delivers every inbound peer stream to a loopback listener (the public
face is the `.b32.i2p` destination, never your IP). The destination's private
key is persisted under `<config>/i2p-seeds/<info-hash>.dest` (0600), so the seed
keeps the **same `.b32.i2p` address across restarts** and previously-published
peer-announces stay valid. With Nostr enabled, carl publishes the `.b32.i2p`
destination as a kind-30078 peer-announce so leechers can find and dial it.

In the desktop app, pick **I2P** in the "Seed a file" visibility selector; the
seed's `.b32.i2p` address is surfaced once the SAM session is up. On the daemon
the seed is created via `POST /api/seeds` with `X-Carl-Route: i2p`. From the CLI,
seed with `--i2p-seed` (the I2P analog of `--tor-seed`):

```sh
carl seed file.torrent ./data --i2p-seed --nostr --i2p-sam 127.0.0.1:7656
```

### Transport health

Like the Tor route (which reports SOCKS-proxy health), the i2p route reports
**SAM-bridge health**: the daemon probes the bridge with a `HELLO` handshake and
surfaces `ok` / `not_running` / `timeout` / `rejected` (not a SAM bridge) in the
`proxy` field of the state API, so the desktop Settings screen shows live I2P
transport status instead of a guess. A missing router shows "SAM bridge not
running" rather than silently failing.

When the I2P route is active, the **BitTorrent transport fails closed** the same
way the proxy/Tor routes do: clearnet DHT, UDP/HTTP trackers, web seeds, and the
inbound listener are all disabled, so no swarm traffic bypasses I2P. **One
caveat:** Nostr peer discovery — the only way to find `.b32.i2p` peers today —
still queries relays over **clearnet**, so a relay sees your IP and the
info-hashes you look up. See *Known limitations* below; for relay privacy run
discovery on the `tor`/`proxy` route.

## How it works (SAM v3)

1. **Session** — carl opens a control connection to the SAM bridge, performs the
   `HELLO` version handshake, and `SESSION CREATE STYLE=STREAM` to get its own
   I2P destination. The control connection is held open for the transfer's
   lifetime (closing it tears the session down).
2. **Dial** — for each peer, carl opens a fresh socket to the bridge, does
   `HELLO` + `STREAM CONNECT` to the peer's `.b32.i2p` destination; on
   `RESULT=OK` the socket becomes a transparent bidirectional stream and the
   normal BitTorrent handshake runs over it.
3. **Seed (inbound)** — carl registers `STREAM FORWARD ID=… PORT=… SILENT=true`
   on a side socket; the router then forwards every inbound stream to that
   loopback port as a raw connection (no SAM header), which the session's normal
   seed listener accepts. The seed's `.b32.i2p` address is
   `base32(SHA-256(destination))`, derived locally and persisted so it's stable.

See `src/i2p_sam.zig` (transport) and `src/i2p_seed.zig` (destination
persistence) for the implementation.

## Tor vs I2P (which to use)

| | Tor (`--route tor`) | I2P (`--route i2p`) |
|---|---|---|
| Built for | general anonymity / browsing | peer-to-peer / file sharing |
| BitTorrent fit | discouraged (slow, strains the network) | purpose-built |
| Addressing | `.onion` (v3) | `.b32.i2p` destination |
| carl transport | SOCKS5h proxy (`--socks`) | native SAM v3 (`--i2p-sam`) |
| Inbound/seeding | Tor hidden service (see tor-hidden-service.md) | SAM `STREAM FORWARD` + stable `.b32.i2p` |
| Downloads (GUI/CLI/daemon) | yes | yes |
| Seeding (GUI/CLI/daemon) | yes | yes |
| Transport health in the UI | SOCKS probe | SAM `HELLO` probe |
| Nostr discovery over the network | yes (via SOCKS) | not yet (relays are clearnet) |

The feature surface is at parity except **Nostr discovery is not yet routed over
I2P** (relay traffic on the i2p route is clearnet; see *Known limitations*).

Either way, carl's **discovery layer is the same** — signed NIP-35 / kind-30078
events over Nostr — so the privacy network you pick is independent of how you
find torrents.

## Verifying end to end (manual)

CI cannot run a live I2P router, so swarm interop is verified manually:

1. Start a router with SAM enabled on two hosts (or two routers locally).
2. On host A, seed a torrent over I2P: create the seed on the `i2p` route
   (desktop "Seed a file" → I2P, or `POST /api/seeds` with `X-Carl-Route: i2p`),
   with Nostr enabled so its `.b32.i2p` destination is published. The daemon
   logs `i2p seed: forwarding <addr>.b32.i2p -> 127.0.0.1:<port>`.
3. On host B: `carl daemon --route i2p`, add the magnet, and confirm carl dials
   host A's `.b32.i2p` destination and the transfer makes progress.

If the SAM bridge is unreachable, adding an I2P transfer fails fast with a clear
error (the daemon stays up); check that your router is running and the
`--i2p-sam` address matches its SAM port.

## Known limitations

- **Nostr relays are not yet routed over I2P.** On the i2p route, relay traffic
  is clearnet (the same as the transfer side), so a relay sees your IP and the
  info-hashes you query. Routing Nostr over I2P is a follow-up. If you need relay
  privacy today, run the daemon on the `tor`/`proxy` route for discovery.
- **The SAM control connection has no keepalive/reconnect.** If the I2P router
  drops the idle session, subsequent peer dials fail until the transfer is
  re-added (restart the transfer). Auto-reconnect is a follow-up.
- **IPv4 SAM bridge only.** carl connects to the SAM bridge over IPv4; point
  `--i2p-sam` at an IPv4 address (e.g. `127.0.0.1:7656`).
- **I2P HTTP trackers (P3):** if the torrent lists an `http://*.i2p/…` announce
  URL, carl GETs it over SAM STREAM and dials dictionary `.b32.i2p` peers.
  Clearnet `http://` / `udp://` announces stay skipped (fail-closed). Profile:
  [beps/i2p-bt-tracker.md](beps/i2p-bt-tracker.md).
- **I2P DHT (P4) is not implemented** — wire notes in
  [beps/i2p-dht.md](beps/i2p-dht.md). Until then, discovery is Nostr kind 30078
  plus I2P HTTP trackers.

## Troubleshooting

- **"failed to add transfer" / SessionInitFailed** — the SAM bridge isn't
  reachable. Confirm the router is running and SAM is enabled on the configured
  address/port.
- **No peers** — give the router time to integrate; confirm the peer's
  `.b32.i2p` destination is reachable (I2P addresses can take time to resolve on
  first use).
