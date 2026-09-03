# Using carl with a proxy

The `--proxy` flag routes carl's outbound TCP through a proxy so that peers and
trackers see the proxy's IP instead of yours. This is "anonymous mode": when a
proxy is set, carl **fails closed** -- anything that can't be tunneled safely is
disabled rather than sent directly, so your real IP never leaks to the swarm.

> The proxy is only ever configured with `--proxy`. carl does **not** read
> `ALL_PROXY` / `HTTP_PROXY` environment variables -- if the flag is absent, all
> connections are direct.

## The `--proxy` flag

```
--proxy <url>
```

`<url>` is `scheme://[user:pass@]host:port`. Supported schemes:

| Scheme | Transport | DNS | Notes |
|--------|-----------|-----|-------|
| `socks5h://` | SOCKS5 | **remote** (proxy resolves the hostname) | Recommended -- no DNS leak |
| `socks5://`  | SOCKS5 | local (carl resolves, sends the IP) | Leaks tracker DNS lookups to your resolver |
| `http://`    | HTTP `CONNECT` | proxy resolves | For HTTP proxies (Squid, corporate gateways) |

Optional `user:pass@` enables authentication (SOCKS5 username/password per
RFC 1929, or HTTP Basic). The flag works on `download`, `seed`, and `announce`:

```sh
carl download file.torrent --proxy socks5h://127.0.0.1:1080
carl announce file.torrent --proxy socks5h://user:pass@127.0.0.1:1080
carl seed     file.torrent /data --proxy http://127.0.0.1:3128
```

If you pass `--proxy` without a value (e.g. it's the last argument), carl exits
with an error instead of silently running unproxied.

## What changes in proxied mode

| Path | Without `--proxy` | With `--proxy` |
|------|-------------------|----------------|
| Peer connections | direct TCP | **tunneled** through the proxy |
| `.onion` peer connections | not used | **tunneled** (requires `socks5h://`; see [tor-hidden-service.md](tor-hidden-service.md)) |
| Nostr relay `wss://` | direct (TLS) | **clearnet** (proxy not applied; see [tor-hidden-service.md](tor-hidden-service.md)) |
| `http://` trackers | direct | **tunneled** through the proxy |
| `https://` trackers | direct (TLS) | **tunneled** -- TLS runs over the proxied stream, with certificate verification |
| UDP trackers (BEP 15) | direct UDP | **disabled** (UDP can't traverse a CONNECT tunnel) |
| DHT (BEP 5) | direct UDP | **disabled** |
| Web seeds (BEP 19) | direct HTTP | **disabled** |
| Incoming listener | bound | **not bound** (inbound peers would see your real IP) |
| Seeding after complete | inbound + outbound | **outbound only** — carl keeps dialing tracker peers so a completed proxied download can still upload; nobody can connect in |

carl prints a one-line banner on startup when a proxy is active so you know the
above is in effect.

## Important: you need an `http(s)://` tracker

Because DHT and UDP trackers are disabled in proxied mode, an **`http://` or
`https://` tracker is the only peer source left**. A trackerless magnet, or a
torrent whose trackers are all `udp://`, has nothing to discover peers with --
carl warns about this at startup:

```
warning(session): no proxy-usable peer source: DHT and UDP trackers are disabled
and this torrent has no http(s):// tracker. No peers can be found -- add an
http(s):// tracker or run without --proxy.
```

Check a torrent's tracker before relying on it:

```sh
carl info file.torrent      # look at the "announce:" line -- you want http://
```

## Setting up a proxy

Any standard SOCKS5 or HTTP proxy works. A few easy options:

### Linux

**SSH dynamic forwarding** (no extra software -- tunnels through any host you can
SSH into; SOCKS5 with remote DNS):

```sh
ssh -D 1080 -N user@your-server
# then:  --proxy socks5h://127.0.0.1:1080
```

**Tor** (real anonymizing network):

```sh
sudo apt install tor    # or: dnf install tor / pacman -S tor
tor                     # SOCKS5 on 127.0.0.1:9050
# then:  --proxy socks5h://127.0.0.1:9050
```

**microsocks** (tiny standalone SOCKS5 server):

```sh
microsocks -p 1080                 # no auth
microsocks -p 1080 -u me -P secret # with auth -> socks5h://me:secret@127.0.0.1:1080
```

**Dante** (`danted`) is a fuller-featured SOCKS daemon; **Squid** gives you an
HTTP proxy for the `http://` scheme (default port 3128).

### macOS

**SSH dynamic forwarding** (built in, identical to Linux):

```sh
ssh -D 1080 -N user@your-server
# then:  --proxy socks5h://127.0.0.1:1080
```

**Tor** via Homebrew:

```sh
brew install tor
tor                     # SOCKS5 on 127.0.0.1:9050
# then:  --proxy socks5h://127.0.0.1:9050
```

**microsocks** via Homebrew:

```sh
brew install microsocks
microsocks -p 1080
# then:  --proxy socks5h://127.0.0.1:1080
```

## Running carl through the proxy

```sh
# Confirm the proxy works and the torrent has an http:// tracker:
carl info    debian-12.iso.torrent
carl announce debian-12.iso.torrent --proxy socks5h://127.0.0.1:1080

# Download through the proxy:
carl download debian-12.iso.torrent --output-dir ~/Downloads \
  --proxy socks5h://127.0.0.1:1080
```

> Tor note: Tor is excellent for the announce/leak test, but many Tor exit nodes
> block BitTorrent peer ports, so a full download may stall. Use `ssh -D` or
> `microsocks` for a complete download.

## Is the proxy actually reachable? (health detection)

On a proxy/tor route, carl tells you *why* the route isn't working instead of
silently failing:

- **At startup**, `carl daemon --route tor` (or `proxy`) probes the SOCKS port
  and logs one of: `reachable`, `unreachable (connection refused) -- is Tor
  running?`, `timed out`, or `rejected the SOCKS5 handshake`.
- **Continuously**, the daemon re-probes every ~30s and publishes the result as
  `proxy` in `GET /api/state` + the WebSocket push (see `docs/daemon-api.md`).
  The desktop **Settings → Anonymity** panel shows it live: reachable / not
  running / timed out / rejected.

The probe only performs the SOCKS5 **method-negotiation greeting** — it never
issues a `CONNECT`, so it opens no upstream connection and leaks no traffic. It
distinguishes "nothing listening" (Tor down) from "timed out" from "rejected"
(not a SOCKS5 proxy, or auth required). Full SOCKS5 `CONNECT` reply codes only
arise on real peer dials; surfacing those per-transfer is a follow-up.

## Verifying there are no leaks

This is the test that matters for a privacy feature -- prove that **nothing**
leaves your machine except to the proxy.

### Read the proxy's logs (easiest)

microsocks, Dante, Squid, and Tor all log the connections they make. Every peer
and tracker carl talks to should appear there, and nothing should bypass it.

### Packet capture with a remote proxy (cleanest)

Use a **remote** proxy (e.g. `ssh -D` to a server at `SERVER_IP`) so "via proxy"
and "direct" are distinguishable by destination IP. While downloading, watch for
any traffic that is *not* going to the proxy:

Linux:

```sh
sudo tcpdump -ni any 'tcp and not host SERVER_IP and not port 22'
```

macOS (find your interface with `route get default | grep interface`):

```sh
sudo tcpdump -ni en0 'tcp and not host SERVER_IP and not port 22'
```

During a proxied download this should stay **silent**. Any TCP connection to a
peer or tracker IP is a leak -- report it.

(With a proxy on `127.0.0.1`, carl only ever connects to loopback, so the host's
real outbound traffic comes from the *proxy* process, not carl -- which is why a
remote proxy or the proxy's own logs give a clearer picture.)

### Strongest: lock carl to the proxy (Linux)

Run carl in a network namespace whose only route is to the proxy. If the download
still works, carl *must* be tunneling; if it leaked, it would have no
connectivity at all. This is the gold-standard fail-closed check (`ip netns` +
a single veth route to the proxy host).

## Tor hidden-service seeding (`--tor-seed`)

For seeding without a public IP, Carl can create an ephemeral v3 onion via Tor
ControlPort and publish it on Nostr (kind 30078 `host` + `port` tags, no IPv4).

```sh
# tor must be running with ControlPort (default 9051) and cookie auth
carl seed file.torrent /data --tor-seed --nostr

# Remote leecher (onion dials require Tor SOCKS)
carl download file.torrent --nostr --proxy socks5h://127.0.0.1:9050
```

`--tor-seed` binds the BitTorrent listener to `127.0.0.1` only and disables
tracker/DHT announces. It is mutually exclusive with `--proxy` on seed.

**Proxy split:** when a leecher passes `--proxy`, BitTorrent peer TCP (including
`.onion` hosts) uses the proxy, but Nostr relay `wss://` connections use
**clearnet** today (proxied WebSocket+TLS is not implemented). See
[tor-hidden-service.md](tor-hidden-service.md) for setup, security, E2E test
results, and limitations.

Optional flags: `--tor-control host:port`, `--tor-cookie path`,
`--tor-onion-port` (virtual port on the onion, default 80),
`--tor-socks url` (reserved for future proxied Nostr; peer traffic uses
`--proxy` on download).

## Limitations

- **Nostr `wss` over `--proxy` is not tunneled** -- relay subscribe/publish uses
  clearnet `wss` while peer TCP (including `.onion`) uses the proxy. See
  [tor-hidden-service.md](tor-hidden-service.md).
- **Web seeds are not tunneled yet** -- they're disabled when proxied (a
  proxied + Range-aware path is a planned follow-up).
- **No UDP** -- DHT and UDP trackers are disabled; SOCKS5 UDP `ASSOCIATE` is not
  implemented.
- **IPv4 only** -- consistent with the rest of carl.
- **Connects are blocking** -- each proxied peer handshake runs synchronously
  (up to ~10s), so a batch of unreachable peers can briefly stall progress.
- **Seeding is outbound-only** -- with no inbound listener, a completed
  proxied download can only upload on connections carl dials (SOCKS CONNECT
  to a reachable leecher). The session keeps replenishing that pool from the
  tracker compact list; it cannot accept incoming peers.

## Tor vs I2P for BitTorrent

The `--proxy`/Tor path tunnels over SOCKS5/SOCKS5h/HTTP. carl also supports
**I2P** as a separate transport route (`--route i2p`, native SAM v3), which is
purpose-built for P2P and avoids the Tor-over-BitTorrent baggage (Tor is slow
for swarms, strains the network, and is leak-prone if misconfigured).

| | Tor / `--proxy` | I2P (`--route i2p`) |
|---|---|---|
| Built for | general anonymity | peer-to-peer / file sharing |
| BitTorrent fit | discouraged | purpose-built |
| Addressing | `.onion` (v3) | `.b32.i2p` destination |
| carl transport | SOCKS5h (`--proxy`/`--socks`) | native SAM v3 (`--i2p-sam`) |

carl's discovery (signed NIP-35 / kind-30078 over Nostr) is the same on either
network. See [i2p.md](i2p.md) for I2P setup and usage.
