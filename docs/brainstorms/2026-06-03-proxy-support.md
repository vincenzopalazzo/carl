# Brainstorm: Proxy support (HTTP-CONNECT + SOCKS5h)

- **Issue:** [vincenzopalazzo/carl#18](https://github.com/vincenzopalazzo/carl/issues/18) — "please add HTTP(S) and SOCKS proxy support"
- **Date:** 2026-06-03
- **Base:** current `main` (DHT peer discovery + magnet links already landed)
- **Selected approach:** **Approach A — Unified tunnel layer**

## Context

For a torrent client, proxy support is a privacy ask: route outbound traffic through a
proxy so peers and trackers never see the user's real IP.

Five outbound network paths exist today, across two transports:

| Path | Location | Transport | Proxy story |
|------|----------|-----------|-------------|
| HTTP tracker announce | `tracker.zig:199`, `session.zig:1250`, `main.zig:306` | `std.http.Client` | std has `http_proxy`/`https_proxy` + CONNECT, but **HTTP-proxy only, no SOCKS** |
| Peer connections | `peer.zig:92` | raw TCP (`std.posix.connect`) | hand-write SOCKS5 / HTTP-CONNECT handshake before the BT handshake |
| UDP tracker | `udp_tracker.zig:50` | raw UDP | only SOCKS5 UDP-ASSOCIATE, or disable |
| DHT | `dht.zig:97` | raw UDP | only SOCKS5 UDP-ASSOCIATE, or disable |
| Incoming listener | `session.zig:136` | TCP server | can't proxy inbound without proxy-side port forwarding |

**Confirmed constraints:**

- Zig 0.15.2 `std.http.Client` (`Proxy` struct, Client.zig:1265) supports HTTP/HTTPS
  proxies but **not SOCKS**. SOCKS for *anything* (including HTTP trackers) means our
  own handshake code.
- **UDP is the hard fork:** HTTP proxies can't carry UDP at all; SOCKS5 UDP-ASSOCIATE is
  complex and frequently rejected by public SOCKS5 proxies.

## Decisions (from clarifying round)

| Dimension | Decision |
|-----------|----------|
| UDP / DHT while proxied | **Disable** DHT + UDP trackers whenever a proxy is set (TCP-only "anonymous mode"). |
| SOCKS DNS resolution | **Remote / no DNS leak** — SOCKS5h, tracker hostnames resolved proxy-side. |
| Config surface | **`--proxy <url>` CLI flag** (env vars `ALL_PROXY`/`HTTP_PROXY` honored as a bonus via std). |
| Authentication | **Support now** — SOCKS5 user/pass (RFC 1929) + HTTP Basic, parsed from `user:pass@host`. |

## Clarified Problem Statement

**Goal:** Add a `--proxy <url>` option that routes all *outbound TCP* (peer connections +
HTTP tracker announces) through an HTTP-CONNECT or SOCKS5/SOCKS5h proxy with optional
user/pass auth, leaking nothing to the swarm.

**Constraints (must hold):**

- **Fail closed.** When a proxy is set, nothing connects directly — *including the error
  path*. A dead proxy errors out; it never silently falls back to direct.
- DHT + UDP trackers are **disabled** whenever `--proxy` is set (one warning log).
- SOCKS uses **remote DNS** (socks5h) — tracker hostnames resolved proxy-side.
- Preserve the blocking-connect + poll-loop model; the SOCKS/CONNECT handshake must respect
  the existing 5s connect timeout (`peer.zig:105`).
- `proxy == null` → byte-for-byte today's behavior.

**Non-goals:** SOCKS5 UDP-ASSOCIATE (proxying DHT/UDP-trackers); SOCKS4/4a; proxying the
inbound listener; per-tracker/per-peer proxy selection; proxy chaining / PAC / Tor-specific
logic.

**Success criteria:**

- `carl download <src> --proxy socks5h://user:pass@127.0.0.1:1080` → peer SYNs and tracker
  GETs appear **only** at the proxy (verify via a local SOCKS proxy log or `tcpdump`); zero
  direct packets to peers/tracker.
- `--proxy http://127.0.0.1:8080` → peers via CONNECT, trackers via the proxy.
- DHT + UDP trackers emit no UDP when proxied; one warning logged.
- Bad/unreachable proxy → clean error, no leak.
- `zig build test` green; `zig fmt src/` clean.

## Approaches Considered

The crux: `std.http.Client` supports HTTP proxies but **not SOCKS**. Since SOCKS is
required, the HTTP-tracker path can't lean on std for the SOCKS case — that is what splits
these approaches.

### Approach A: Unified tunnel layer — **SELECTED**

- **Sketch:** New `src/proxy.zig` exposing
  `connectThroughProxy(allocator, proxy, target, port) !std.net.Stream` — performs the
  SOCKS5/5h greeting + RFC-1929 user/pass + CONNECT, *or* HTTP `CONNECT host:port` + Basic
  auth, returning a connected stream. Peers use it directly (ATYP=IPv4). HTTP trackers do a
  minimal HTTP/1.1 GET over that stream (response is bencode, already parsed) — uniform for
  both HTTP and SOCKS proxies.
- **Affected files:**
  - new `src/proxy.zig` — `Proxy` struct `{scheme: socks5|socks5h|http|https, host, port, username?, password?}`, `parseUrl`, `connectThroughProxy`.
  - `src/main.zig:61` — parse `--proxy <url>`; thread into `cmdDownload`/`cmdSeed`/`cmdAnnounce`.
  - `src/session.zig:35` — add `proxy: ?proxy.Proxy` to `Session` + `init`; gate DHT startup and UDP-tracker announce (`session.zig:1029`) on `proxy == null`; pass proxy to peer connects (`connectToPeers:1075`, `connectDirectPeer:1114`); web-seed HTTP (`session.zig:1250`).
  - `src/peer.zig:92` — `connect()` routes through `proxy.connectThroughProxy` when set, keeping the 5s timeout; add `proxy: ?*const proxy.Proxy` to `PeerConnection` + `init`.
  - `src/tracker.zig:199` — when proxied, GET over the tunneled stream instead of `std.http.Client.fetch`.
  - `src/udp_tracker.zig` — unchanged; caller skips it when proxied.
- **Tradeoffs:** One code path, leak-proof, extensible to UDP-ASSOCIATE later. Cost:
  HTTPS-tracker-over-SOCKS needs `std.crypto.tls.Client` layered on the stream (see open
  questions).
- **Effort:** **M** (~200–300-line module + thread `?Proxy` through 4 files).

### Approach B: Hybrid — std for HTTP-proxy, custom for SOCKS

- **Sketch:** Keep `std.http.Client.http_proxy` for trackers *when the proxy is HTTP*;
  hand-roll only the SOCKS path. Peers always hand-rolled.
- **Tradeoffs:** Slightly less code for the HTTP-proxy case, but two divergent tracker paths
  to maintain — and SOCKS HTTP-tracker still needs the minimal-GET, so you build most of A
  *plus* a branch.
- **Effort:** **M**, with more long-term maintenance surface.

### Approach C: Per-site split, minimal diff

- **Sketch:** Set std proxy fields at the 3 `http.Client` sites; add a SOCKS-only shim in
  `peer.zig`; declare HTTP-tracker-over-SOCKS unsupported.
- **Tradeoffs:** Smallest diff, but a **leak gap**: `--proxy socks5h://…` proxies peers
  while tracker announces go direct or fail — directly contradicts the fail-closed goal.
  Rejected.
- **Effort:** **S**, but does not meet the constraints.

## Recommendation

**Approach A.** Because SOCKS forces us off `std.http.Client` for tracker GETs regardless, a
single tunnel layer is *less* total work than B's two paths and avoids C's leak gap. Land it
as one PR; shape `proxy.zig` so SOCKS5 UDP-ASSOCIATE can bolt on later without touching
callers.

## Open questions (non-blocking)

- **Inbound listener while proxied** (`session.zig:136`): disable it for true no-leak (fewer
  incoming peers), or keep binding? Lean: disable when proxied.
- **HTTPS trackers over SOCKS:** ship HTTP-tracker + HTTP(S)-proxy first and add
  TLS-over-tunnel (`std.crypto.tls.Client` on the stream) as a fast follow, or include it
  now? Most trackers here are HTTP/UDP.
- **Smaller swarm:** with DHT + UDP-trackers off, peers come only from HTTP trackers + web
  seeds — expected; worth a log line so it is not mistaken for a bug.
