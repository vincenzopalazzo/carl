# Tor hidden-service seeding + onion peer announce

Brainstorm for Carl: seed behind a Tor v3 hidden service, publish the endpoint on Nostr (kind 30078), and let remote leechers discover and connect only via Tor.

**Context:** Today `carl seed --nostr` requires `--external-ip` (IPv4). Kind 30078 uses `ip` + `port` tags. With `--proxy`, the inbound listener is disabled (fail-closed anonymity), so classic seeding over Tor outbound-only does not work. Remote confirmation (Hetzner `65.108.246.14`) showed Nostr discovery works but `45.80.136.155:6881` is unreachable from the internet (firewall/NAT).

**Relevant code today:**

- `src/peer_announce.zig` — kind 30078, IPv4-only schema
- `src/main.zig` — `publishNostr`, `collectNostrPeers` (dials `initIp4` only)
- `src/session.zig` — listener on `0.0.0.0` when not proxied; no listener when `--proxy`
- `src/proxy.zig` — `connectThroughProxyHost` (socks5h domain connect; suitable for `.onion`)
- `src/ws.zig` — direct `wss` to relays (no proxy)
- `docs/proxy.md` — Tor as SOCKS5 for download; notes exit nodes often block BT

---

## Decisions (from brainstorm Q&A)

| Topic | Choice |
|-------|--------|
| Tor setup | Carl talks to **Tor ControlPort** (`ADD_ONION` / read v3 address) |
| Kind 30078 schema | **Onion-only** in tor mode: `["host", "<v3.onion>"]` + `["port", "<n>"]` — no `ip` tag |
| CLI model | Single **`--tor-seed`** flag: loopback listener + HS + publish; leechers need **`--proxy`** |
| Listen bind | **`127.0.0.1`** only in hidden-service mode |
| Nostr path | **`wss` tunnels through SOCKS5** when tor-seed / proxy workflow is active |

---

## Clarified Problem Statement

**Goal:** Let Carl seed behind a Tor v3 hidden service, publish that endpoint on Nostr (kind 30078), and let remote leechers discover and connect only via Tor (`--proxy socks5h`), without exposing a public IPv4 listener or `--external-ip`.

**Constraints:**

- Must not break existing IPv4 peer announces (`ip` + `port`) for `carl seed --nostr --external-ip`.
- Fail-closed anonymity preserved: no `0.0.0.0` listener in `--tor-seed` mode; generic `--proxy` seed still has no inbound listener.
- Reuse `proxy.connectThroughProxyHost` for `.onion` dials over `socks5h`.
- Zig 0.15; no heavy new deps (Tor control = line protocol over TCP or unix socket).

**Non-goals (v1):**

- I2P, IPv6, or dual `ip` + `host` in one event
- UDP trackers / DHT / web seeds over Tor
- Embedding the `tor` binary (optional follow-up)
- Formal NIP beyond Carl’s existing kind 30078 convention

**Success criteria:**

1. `carl seed <torrent> <data> --tor-seed --nostr` → ControlPort returns v3 hostname; publishes kind 30078 with `host`/`port`; listens on `127.0.0.1:<port>`.
2. Remote host: `carl download <magnet> --nostr --proxy socks5h://127.0.0.1:9050` → finds announce, connects through Tor, completes a small torrent.
3. Inbound probe to the machine’s public IP on the BT port fails while `--tor-seed` is active.
4. Nostr publish/search in tor-seed workflow uses Tor (no direct `wss` leak).
5. Unit tests: onion announce build/parse, malformed host rejected; IPv4 path unchanged.

---

## Approaches Considered

### Approach A: Attach to existing Tor (ControlPort client)

**Sketch:** New `src/tor_control.zig` connects to `127.0.0.1:9051` (or `--tor-control`). `ADD_ONION PORT=…,127.0.0.1:…` → parse `ServiceID`. On exit, `DEL_ONION`. `--tor-seed` binds loopback, `peer_announce.buildOnion`, publishes over proxied `wss`. Downloaders: `collectNostrPeers` → `connectThroughProxyHost` when `--proxy` is set.

**Affected files:** `tor_control.zig` (new), `peer_announce.zig`, `main.zig`, `session.zig`, `ws.zig`, `relay.zig`, `proxy.zig`, `docs/proxy.md`, README.

**Tradeoffs:**

- Gains: matches `apt install tor`; small surface; ops-familiar.
- Costs: user must run `tor` with ControlPort + cookie auth; clear errors if tor is down.
- Does not solve: zero-config on hosts without tor installed.

**Effort:** M

---

### Approach B: Carl spawns Tor subprocess

**Sketch:** `--tor-seed` writes a temp torrc (`DataDirectory`, `ControlPort`, `CookieAuthFile`), execs `tor -f …`, waits for bootstrap, then same ControlPort flow as A. `deinit` kills tor and `DEL_ONION`.

**Affected files:** Approach A plus spawn/lifecycle in `tor_control.zig` or `tor_spawn.zig`.

**Tradeoffs:**

- Gains: one command; good for demos.
- Costs: process management, temp dirs, cleanup on crash; platform-specific `tor` paths; heavier CI.
- Does not solve: environments without a `tor` binary.

**Effort:** L

---

### Approach C: Phased delivery (schema + dial, then ControlPort)

**Sketch:** PR1: `host`/`port` tags, `parseOnion`, downloader dial via `--proxy`, optional manual `--onion` for dev. PR2: ControlPort + `--tor-seed` + `wss` over SOCKS.

**Affected files:** PR1: `peer_announce.zig`, `main.zig`, `session.zig`. PR2: `tor_control.zig`, `ws.zig`.

**Tradeoffs:**

- Gains: smaller reviews; test onion dial without tor in CI (mock host).
- Costs: two CLI stories temporarily; delays full ControlPort UX.

**Effort:** M total (S + M split)

---

## Recommendation

**Ship Approach A for v1**, implemented in the order of Approach C internally:

1. Extend `PeerAnnounce` → `enum { ipv4, onion }` in `peer_announce.zig`.
2. `collectNostrPeers` → onion branch → `proxy.connectThroughProxyHost` (require `--proxy` or exit with a clear error).
3. `session.zig`: `--tor-seed` → bind `127.0.0.1` only; mutually exclusive with `--proxy` on seed.
4. `tor_control.zig`: `ADD_ONION` / `DEL_ONION` + cookie auth (`~/.tor/control_auth_cookie` or `--tor-cookie`).
5. `ws.zig`: optional SOCKS path for `wss` (may share patterns with HTTPS-over-proxy in `proxy.zig`).
6. Manual integration test: tor + `carl seed --tor-seed` locally; `carl download` from VPS with `--proxy`.

**Defer Approach B** (spawn tor) unless attach-to-existing-tor proves too painful in practice.

---

## Proposed CLI (v1)

```sh
# Seeder (tor daemon running with ControlPort)
carl seed file.torrent ./data --tor-seed --nostr \
  [--tor-control 127.0.0.1:9051] [--port 6881]

# Leecher (must use Tor SOCKS)
carl download "magnet:?xt=urn:btih:…" --output-dir ./out \
  --nostr --proxy socks5h://127.0.0.1:9050
```

**Incompatibilities:**

- `--tor-seed` + `--proxy` on seed: error (tor-seed owns listen path; proxy remains download/outbound-only elsewhere).
- `--tor-seed` + `--external-ip`: error (onion-only announce).
- Onion peer without `--proxy` on download: error (not silent skip).

---

## Kind 30078 schema (onion mode)

```json
{
  "kind": 30078,
  "tags": [
    ["d", "<infohash_hex>"],
    ["host", "<56-char-v3-onion>.onion"],
    ["port", "<port>"],
    ["client", "carl/0.1"]
  ],
  "content": ""
}
```

**Validation:**

- `host` ends with `.onion`, v3 length (56 chars + suffix), charset check
- `port` non-zero u16
- No `ip` tag in events we publish in tor mode; parsers accept legacy `ip` events for backward compatibility

---

## Tor ControlPort sketch

```
AUTHENTICATE <cookie-hex>
ADD_ONION NEW:ED25519-V3 Port=80,127.0.0.1:6881
→ 250-ServiceID=…
→ 250 PrivateKey=…
… on shutdown …
DEL_ONION <ServiceID>
```

Open question: virtual port on the onion (`80` → local `6881` is common) vs exposing `6881` on the onion — affects published `port` tag and `ADD_ONION` line.

---

## Open questions

- **Onion virtual port:** HS port 80 vs 6881 mapping to local listener?
- **Control auth:** cookie file only, or password / `HASCOOKIE` flag?
- **Replaceable events:** after restart, new `ADD_ONION` + republish same `d=infohash` (NIP-33 replaceable).
- **Trackers in tor-seed mode:** disable public tracker announce of real IP, or HTTP tracker only via proxy?
- **`wss` over SOCKS:** full TLS+WS handshake through tunnel (largest implementation risk).

---

## Test plan (acceptance)

- [ ] Unit: build/parse onion announce; reject bad host; IPv4 round-trip unchanged
- [ ] Unit: `isRoutable` / IPv4 parse unchanged
- [ ] Local: tor running → `carl seed --tor-seed --nostr` logs onion + publish acks
- [ ] Remote VPS: `carl download … --nostr --proxy socks5h://127.0.0.1:9050` completes small fixture torrent
- [ ] Negative: `nc <public-ip> <bt-port>` fails during tor-seed
- [ ] Negative: download onion peer without `--proxy` → clear error

---

## Next step

```
/ship --from-brainstorm docs/brainstorms/2026-06-03-tor-hidden-service-peer-announce.md
```

or:

```
/ship --plan-only implement Tor hidden-service seeding per brainstorm doc
```