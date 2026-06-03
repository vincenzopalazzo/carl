# Brainstorm: Pubky discovery alongside Nostr (carl)

**Date:** 2026-06-03  
**Context:** [Pubky TLDR](https://pubky.org/tldr/) — decentralized identity (Ed25519), homeserver HTTP storage, PKARR/Mainline DHT discovery. Carl already ships Nostr (NIP-35 + kind 30078) as an optional discovery layer.

**Decisions captured from brainstorm:**

| Dimension | Choice |
|-----------|--------|
| Feature parity | Full parity with Nostr: search, seed/download peer announce, keygen/config |
| CLI surface | Parallel flags: `--nostr` and `--pubky` (combinable on download) |
| Integration | Rust FFI to official Pubky SDK |
| Search/indexing | Pubky Nexus REST API |

---

## Clarified Problem Statement

**Goal:** Add optional Pubky discovery alongside Nostr so carl can publish/find torrents and peer endpoints over Pubky (homeserver + Nexus) with the same CLI ergonomics as today's Nostr flags.

**Constraints:**

- Keep existing Nostr behavior unchanged; Pubky is additive.
- Parallel CLI: `--nostr` and `--pubky` on `download` / `seed`; both may be set on download.
- Integrate via Pubky Rust SDK / FFI (not a from-scratch Zig protocol implementation).
- Search via Nexus REST, not relay-style WebSocket subscriptions.
- Stay pure-Zig for BitTorrent core; only the Pubky layer pulls in Rust/FFI.
- Respect carl's privacy model (per-session keys, Tor/onion peer announces, fail-closed proxy rules).

**Non-goals:**

- Replacing or merging Nostr into Pubky.
- One shared keypair across Nostr (BIP-340 Schnorr) and Pubky (Ed25519).
- Pubky Ring / mobile signer integration in v1.
- Paykit, Pubky Noise, or social-graph features unrelated to torrents.
- Dual-publish bridge for third-party Nostr clients (unless explicitly added later).

**Success criteria:**

- `carl pubky-keygen` + config under `~/.config/carl/` (homeserver, credentials).
- `carl search "…"` finds torrent metadata via Nexus when using Pubky discovery.
- `carl seed … --pubky` publishes torrent index + replaceable peer endpoint for the infohash.
- `carl download … --pubky` (and `--nostr --pubky`) ingests peer announces and dials peers (IPv4 + existing Tor rules).
- `zig build test` green; FFI builds on macOS/Linux CI targets.

---

## Current state (Nostr baseline)

Carl's optional Nostr layer (for reference when mirroring Pubky):

| Feature | Nostr implementation |
|---------|---------------------|
| Torrent index | NIP-35 kind 2003 (`nip35.zig`) |
| Peer announce | Custom kind 30078, NIP-33 parameterized (`peer_announce.zig`) |
| Transport | WebSocket relays (`ws.zig`, `relay.zig`) |
| Crypto | BIP-340 Schnorr via vendored libsecp256k1 (`secp.zig`) |
| Config | `~/.config/carl/{nsec,relays}` (`nostr_config.zig`) |
| CLI | `nostr-keygen`, `search`, `seed/download --nostr` |

**Pubky differences that matter for design:**

- Identity: Ed25519 (not secp256k1) — separate keygen and config files.
- Storage: HTTP homeserver paths (not signed event streams on relays).
- Discovery: PKARR/DHT + Nexus indexing (not `REQ` filters on relays).
- Maturity: Pubky ecosystem is beta; Nexus is social-oriented today.

---

## Proposed data model (carl on Pubky)

Define a **carl.app** namespace on homeservers (paths are illustrative; finalize during implementation):

```
/pub/carl.app/torrents/{infohash_hex}.json     # torrent index (NIP-35 analogue)
/pub/carl.app/announces/{infohash_hex}.json    # replaceable peer announce (kind 30078 analogue)
```

**Torrent index JSON** (fields aligned with NIP-35 tags where possible):

- `info_hash` (40-char hex)
- `title`, `description`
- `files`: `[{ "path", "size" }]`
- `trackers`: `["udp://…"]`
- `client`: `"carl/<version>"`
- `created_at` (unix)

**Peer announce JSON** (IPv4 or Tor, same safety rules as `peer_announce.zig`):

- `info_hash`
- `endpoint`: `{ "type": "ipv4", "ip", "port" }` or `{ "type": "onion", "host", "port" }`
- `client`
- `updated_at`

**Replaceability:** One canonical path per `(pubky, infohash)`; PUT overwrites prior announce (like NIP-33 `d` tag).

**Nexus:** Register or query a carl-specific feed/filter so `carl search` can resolve torrent metadata without crawling arbitrary homeservers. Prototype Nexus API early — may require coordination with Pubky/Nexus operators.

---

## Approaches Considered

### Approach A: Mirror the Nostr module tree (recommended)

- **Sketch:** Add a Pubky slice parallel to the Nostr stack: FFI wrapper → homeserver client (signup, PUT/GET/DELETE, signed requests) → `pubky_torrent.zig` + `pubky_peer_announce.zig` → `nexus.zig` for search → wire `main.zig` / `session.zig` like existing Nostr publish/collect paths.
- **Affected files:**
  - `build.zig`, `build.zig.zon` — FFI link to `pubky` / `pubky-core-ffi`
  - New: `src/pubky_ffi.zig`, `src/pubky.zig`, `src/pubky_torrent.zig`, `src/pubky_peer_announce.zig`, `src/nexus.zig`, `src/pubky_config.zig`
  - Touch: `src/main.zig`, `src/session.zig`, `src/lib.zig`, `README.md`, `docs/pubky.md`
- **Tradeoffs:** Clearest mapping for maintainers; some duplicated orchestration. FFI cross-language build is the main cost. Nexus indexing contract may not exist yet.
- **Effort:** L

### Approach B: Shared `Discovery` interface

- **Sketch:** `discovery.zig` with `publishTorrent`, `publishPeer`, `search`, `collectPeers`; Nostr and Pubky backends; session merges peer lists.
- **Affected files:** Same as A, plus refactor `relay.zig`, `nip35.zig`, `peer_announce.zig` behind traits.
- **Tradeoffs:** Less duplication long-term; higher upfront refactor of working Nostr code.
- **Effort:** L+

### Approach C: FFI for writes only, Zig HTTP for reads

- **Sketch:** Rust FFI for signup/sign/PUT; Nexus and homeserver GET in pure Zig.
- **Tradeoffs:** Smaller FFI surface; two implementations of auth rules — drift risk. Conflicts with chosen FFI-first approach.
- **Effort:** M–L

---

## Recommendation

**Ship Approach A.** It matches the decided integration style (Rust FFI), minimizes risk to the working Nostr stack, and gives a 1:1 mental model for contributors.

**Implementation order (suggested PR stack):**

1. **FFI + build** — `pubky-core-ffi` in `build.zig`, smoke test sign-in from Zig tests.
2. **Config + keygen** — `pubky-keygen`, `~/.config/carl/pubky-{key,homeserver}` (exact filenames TBD).
3. **Publish path** — torrent index + peer announce JSON on homeserver; `seed --pubky`.
4. **Collect path** — fetch announce by infohash (direct path or Nexus); `download --pubky`.
5. **Search** — Nexus REST integration; extend `carl search` for Pubky results.
6. **Tor + proxy** — onion schema in JSON; same leecher rules as Nostr (`.onion` requires `--proxy socks5h://…`).
7. **Docs + E2E** — `docs/pubky.md`, integration test against local Pubky Docker stack.

---

## CLI sketch

```sh
# Identity (Ed25519 — separate from nostr-keygen)
carl pubky-keygen

# Search (Nexus)
carl search "ubuntu" --pubky --limit 20

# Seed + announce
carl seed file.torrent /data --pubky --external-ip 203.0.113.7

# Download — both backends
carl download file.torrent --nostr --pubky

# Tor (mirror existing --tor-seed + --nostr behavior)
carl seed file.torrent /data --tor-seed --pubky
carl download file.torrent --pubky --proxy socks5h://127.0.0.1:9050
```

Config additions under `~/.config/carl/` (names TBD):

- Pubky secret / key material (0600 perms, like `nsec`)
- Default homeserver URL
- Optional Nexus base URL override

---

## Open questions

- **Search CLI:** Does `carl search` always hit both backends, or only when `--pubky` / `--nostr` is passed?
- **Nexus contract:** Which endpoint indexes `/pub/carl.app/torrents/`? Custom feed vs generic search?
- **Default homeserver:** Public testnet vs user-configured only?
- **Dual publish:** When `--nostr` and `--pubky` on seed, two identities — document clearly in README privacy section.
- **CI:** Cross-compile FFI artifacts for Linux/macOS; document Docker-based dev stack ([Pubky Docker](https://pubky.org/explore/technologies/pubky-docker/)).

---

## References

- Carl Nostr: `README.md`, `src/nostr.zig`, `src/nip35.zig`, `src/peer_announce.zig`
- Pubky overview: https://pubky.org/tldr/
- Pubky getting started / SDK: https://pubky.org/getting-started/
- Pubky vs Nostr: https://pubky.org/comparisons/
- Nexus API: https://nexus.pubky.app/swagger-ui/

---

## Next step

```
/ship --from-brainstorm docs/brainstorms/2026-06-03-pubky-discovery.md
```

Or:

```
/ship Add Pubky discovery to carl (parallel --pubky, FFI, Nexus search, full parity with Nostr)
```