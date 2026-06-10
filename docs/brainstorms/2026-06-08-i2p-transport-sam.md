# I2P transport support (native SAM v3) — issue #35

## Clarified Problem Statement

**Goal:** Add I2P as a first-class transport (`Route.i2p`) via a native SAM v3
bridge — carl dials and accepts BitTorrent peers as `.b32.i2p` destinations,
seeds under a stable destination, and discovers peers via both carl's nostr
layer and I2P-native trackers/DHT — without disturbing the direct/proxy/tor
paths.

Decisions (from brainstorm):
- Scope: **full native SAM v3** (not a SOCKS shim, not docs-only).
- Transport: **native SAM v3 module**.
- Discovery: **I2P-native (trackers/DHT) in scope**, alongside nostr.
- Route surface: **new `i2p` route**.

**Constraints:**
- Must not regress `direct` / `proxy` / `tor`. SAM is additive.
- Requires a running I2P router (i2pd or Java I2P) with the SAM bridge enabled
  (default `127.0.0.1:7656`) — a documented prerequisite, like "Tor must run."
- I2P peers have no IP:port — they're destinations + a virtual stream port.
  Needs an `Endpoint.i2p` type; `PeerConnection.connect_host` (the hostname slot
  used today for `.onion`) can carry the `.b32.i2p`, with a new connect branch
  that calls SAM instead of SOCKS.
- A persistent destination key (stable `.b32.i2p` across restarts for
  seeding/discovery), stored in the config dir like the nostr `nsec` / Tor key.
- Zig 0.15, blocking-socket style matching `src/proxy.zig` / `src/ws.zig`.

**Non-goals:** I2P outproxy (I2P→clearnet); datagram/µTP over I2P (BT uses I2P
streaming = TCP-like); replacing nostr discovery; a SOCKS-to-I2P shim.

**Success criteria:**
- Leech a torrent from another carl I2P peer over native SAM (no SOCKS), peer
  dialed by `.b32.i2p`.
- Seed: stable `.b32.i2p`, accepts inbound SAM streams, announces its
  destination over nostr.
- I2P tracker announce works (HTTP-over-SAM to a `.i2p` tracker); peers found
  via I2P DHT.
- `--route i2p` selectable end-to-end; the other three routes unchanged.
- `docs/proxy.md` documents Tor-vs-I2P; a `docs/i2p.md` covers setup/usage.

## Approaches Considered

### Approach A: Vertical slice first, then widen — phased native SAM (recommended)
- Sketch: native SAM in reviewable phases behind the new route.
  - P1: `src/i2p_sam.zig` (session + `STREAM CONNECT`) + `Endpoint.i2p` + dial
    nostr-announced `.b32.i2p` peers → working leech over SAM.
  - P2: persistent destination + `STREAM FORWARD` inbound + announce our
    `.b32.i2p` → seeding.
  - P3: I2P trackers (HTTP-over-SAM announce).
  - P4: I2P DHT (spin to its own issue — largest/riskiest piece).
- Affected: new `src/i2p_sam.zig`; `src/peer.zig` (third connect branch);
  `src/session.zig` (accept loop + I2P tracker dial); `src/api.zig`
  (`Route.i2p`); `src/peer_announce.zig` (i2p endpoint); `src/manager.zig` +
  `src/main.zig` (flags/threading); `src/nostr_config.zig` (persist i2p key);
  `docs/proxy.md`, `docs/i2p.md`.
- Tradeoffs: proves the SAM protocol end-to-end before the expensive parts;
  small PRs. Cost: the route is leech-only for a while; DHT lands last.
- Effort: L (multi-PR)

### Approach B: Transport-interface refactor, then SAM behind it
- Sketch: introduce a `Transport` seam (`dial(dest)→stream`, `listen()→stream`)
  abstracting direct/SOCKS/Tor and unifying today's `.onion` special-casing,
  then implement SAM as a second backend.
- Tradeoffs: cleanest long-term; pays down onion special-casing debt — but
  refactors the working Tor path (regression risk) for upfront architecture.
- Effort: L+

### Approach C: Big-bang full native in one branch
- Sketch: SAM outbound + inbound + destination + I2P trackers + I2P DHT + route
  in one PR.
- Tradeoffs: matches "full" literally, but huge review surface; I2P DHT alone is
  a multi-week subproject that would block everything.
- Effort: XL

## Recommendation

**Approach A.** Delivers the full native-SAM target, sequenced so the first PR
is a working outbound leech over SAM (validating the protocol and the
`Endpoint.i2p`/route plumbing) before the costly inbound, tracker, and DHT
phases. **I2P DHT should be its own phase/issue** — it's the largest/riskiest
piece, and carl's nostr peer-announce already yields a working I2P swarm among
carl users without it (DHT mainly buys interop with the i2psnark/postman
ecosystem). Start P1 now; spin DHT off.

## Open questions
- Destination persistence: persisted key in the config dir (reuse the nostr
  config-dir convention) — yes, persisted (needed for seeding/discovery).
- I2P DHT: spin off to its own issue (recommended).
- Router assumption: target the SAM bridge generically (i2pd and Java I2P),
  router-agnostic.
- Virtual stream port convention for BT-over-I2P (i2psnark conventions) —
  confirm during P1.

## Implementation note (this environment)
No I2P router is installed on the dev host, so the SAM client is verified with
in-process mock-SAM-server unit tests (handshake + STREAM CONNECT byte-level
assertions and reply parsing). Full swarm interop requires a running router and
is documented as a manual test procedure in `docs/i2p.md`.
