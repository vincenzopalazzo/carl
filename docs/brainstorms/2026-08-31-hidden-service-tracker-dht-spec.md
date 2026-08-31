# Hidden-service tracker + DHT spec (BEP draft + NIP)

Decisions from `/brainstorm` Q&A (2026-08-31):

| Topic | Choice |
|-------|--------|
| Spec surface | **(c)** BEP draft in-repo **and** NIP/kind-30078 alignment |
| Discovery | **(c)** Tracker **and** DHT |
| Interop | **(b)** qBittorrent / i2psnark (I2P-BT), not Carl-only, not clearnet opentrackr |
| Delivery | **All complete**, split into **separate commits** (not one blob) |
| Git | Rebase the work branch onto **updated `origin/main` first** (Zig 0.16 as of 4e78a7c). Do not stack this on `#103` (`fix/proxy-seed-outbound`, still 0.15). |

Prior art in-tree: `docs/brainstorms/2026-06-03-tor-hidden-service-peer-announce.md` (Nostr 30078 onion; **non-goal then:** UDP/DHT/trackers over Tor), `docs/brainstorms/2026-06-08-i2p-transport-sam.md` (P3 I2P trackers, P4 I2P DHT — **not shipped**; `#35`). Live behavior: `--tor-seed` / `--i2p-seed` speak BEP 3 on the stream, skip tracker/DHT (fail-closed), discover via kind 30078.

---

## Clarified Problem Statement

**Goal:** Specify and implement how a Carl hidden seed (`--tor-seed` / `--i2p-seed`) is found via **tracker and DHT**, with an in-repo BEP draft plus aligned NIP-35/kind-30078 text, at interop with **i2psnark / qBittorrent I2P** — without leaking the clearnet IP and without pretending BEP 3 compact / BEP 5 already carry `.onion` / `.b32.i2p`.

**Constraints:**

- Rebase onto `origin/main` (Zig **0.16**) before the first spec or code commit.
- Fail-closed: no clearnet UDP, no `0.0.0.0` listener, no HTTP tracker announce that would show the Mac IP (same gates as `anonymized()` / `tor_hidden` today).
- BEP 3 **compact** stays IPv4 6-byte. Hostname peers live in the **dictionary** `peers` list (`ip` = DNS name per BEP 3) or in an I2P-native tracker body — never stuffed into compact.
- BEP 5 compact values stay IPv4/IPv6. Tor hidden seeds **do not** join the clearnet DHT. I2P DHT is the I2P overlay (not BEP 5).
- Kind 30078 `host`+`port` remains valid; the BEP/NIP text must map 30078 ↔ tracker dict hostname so a peer found either way dials the same endpoint.
- I2P tracker HTTP is over **SAM STREAM**, not SOCKS-to-clearnet.
- Separate commits, each reviewable (docs ≠ parser ≠ dial ≠ announce ≠ DHT).
- Do not regress `direct` / `proxy` compact announce.

**Non-goals:**

- Making opentrackr / public UDP trackers store onions (they won't; compact-only).
- A new DHT overlay on Tor (no BEP 5 encoding for `.onion`; not in qBittorrent).
- Publishing a BEP to bittorrent.org in v1 (in-repo draft is enough; submission is follow-up).
- Changing `#103` proxy replenish (independent; merge/rebase separately).
- I2P outproxy, µTP/datagram over I2P, embedding `tor`/`i2pd`.

**Success criteria:**

1. `docs/beps/` contains a draft: BEP 3 dict `ip` may be `.onion` / `.b32.i2p`; compact unchanged; announce must not source a clearnet IP for hidden seeds.
2. Same folder (or `docs/i2p.md` extension) describes **I2P-BT** as Carl will speak it (HTTP tracker over SAM, destination as peer id) with a table vs i2psnark/qBittorrent.
3. Kind 30078 / NIP notes state the bijection: `host` tag = tracker dict `ip` hostname; `port` = virtual port (I2P port 0 remains allowed).
4. `tracker.zig` parses dictionary peers whose `ip` is a hostname; compact path unchanged. Unit tests for onion, `.b32.i2p`, IPv4, rejection of mixed smuggling if we keep the 30078 “host wins” rule.
5. Hidden I2P seed: HTTP-over-SAM announce to a documented I2P tracker; compact/dict peers that are destinations get `connectI2pPeer`, not `connectDirectPeer`.
6. Hidden Tor seed: if a tracker reachable **through Tor** returns dict hostname peers, Carl dials them via SOCKS5h; Carl does **not** announce the onion to a clearnet tracker.
7. I2P DHT: find/announce peers without clearnet UDP (SAM datagram or I2P-BT equivalent). If the first slice cannot land DHT, the branch still documents the wire and leaves a dedicated follow-up commit/PR — not silent drop of (2c).
8. `zig build test` green on 0.16; no IP leak in the hidden-seed paths (tracker/DHT still skipped on clearnet URLs).

---

## Approaches Considered

### Approach A: Dual-spec, speak I2P-BT as it exists (recommended)

- **Sketch:** Two in-repo specs, not one fake BEP. (1) **BEP-style draft** extending BEP 3 dictionary peers: `ip` may be a DNS name that is a v3 `.onion` or `.b32.i2p`; compact forbidden for those. Tor hidden seeds announce only to trackers reached over SOCKS (none of the public UDP ones). (2) **I2P-BT profile** documenting HTTP-over-SAM announce and I2P DHT as used by i2psnark/qBittorrent — this is the interop target, not a new encoding. Align `peer_announce.zig` comments + a short NIP note so 30078 `host` is the same string a tracker dict would carry. Implement in commits: docs → parse hostname dict peers → dial → I2P tracker announce → I2P DHT.
- **Affected files:** `docs/beps/` (new), `docs/i2p.md`, `docs/tor-hidden-service.md`, `docs/brainstorms/2026-06-08-i2p-transport-sam.md` (P3/P4 status), `src/tracker.zig` (`Peer` + `parseDictPeers`), `src/session.zig` (`handleAnnounceResponse`, `tryAnnounceUrl` I2P gate, `connectI2pPeer` / onion dial from tracker list), `src/i2p_sam.zig` (HTTP GET over STREAM), `src/peer_announce.zig` / NIP notes, later I2P DHT module.
- **Tradeoffs:** Interop (3b) is actually possible on I2P. Tor tracker/DHT stay weak (no public onion tracker, no BEP 5 onion) — discovery there remains 30078 plus any dict-hostname peers a Tor-tunneled tracker might return. Does not get Valley-of-the-Boom/opentrackr to see the onion. Two specs to maintain.
- **Effort:** L (docs + parser + I2P tracker = M; I2P DHT = L on its own)

### Approach B: One unified “non-IP peer” BEP for Tor and I2P

- **Sketch:** Draft a single BEP (tracker dict + DHT value = hostname/destination blob) and implement both ends in Carl. Submit-shaped text from day one. NIP 30078 becomes a Nostr encoding of the same BEP record.
- **Affected files:** same as A plus a DHT value codec in `src/dht.zig` that BEP 5 peers will ignore.
- **Tradeoffs:** Clean story on paper. **qBittorrent/i2psnark will not speak it** until they adopt a brand-new BEP — violates interop (3b) for the foreseeable future. Clearnet DHT still cannot store onions without forking the overlay. Political/standards cost with no near-term swarm.
- **Effort:** XL

### Approach C: Spec-only first PR, then implementation PRs

- **Sketch:** PR 1 = `docs/beps/` + NIP notes + i2p.md (no `src/` behavior change). PR 2 = parser. PR 3 = I2P tracker. PR 4 = I2P DHT. Matches “separate commits” even more, but the user asked for **all complete** as one delivery.
- **Affected files:** same as A, split across PRs.
- **Tradeoffs:** Easier review; longer calendar; easy to stall after docs (P3/P4 of `#35` already stalled). User wanted complete + commits, not complete + many PRs.
- **Effort:** L calendar, M per PR

---

## Recommendation

**Approach A.** Interop with i2psnark/qBittorrent means **speaking I2P-BT**, not inventing a BEP they do not implement. A small BEP-3-dict draft covers Tor hostname peers without lying about compact or BEP 5. I2P DHT stays in scope as the last commit(s) on the same branch; if review explodes, split only that commit to a follow-up PR — do not drop tracker.

Do **not** turn on clearnet tracker/DHT for `--tor-seed`/`--i2p-seed`. The spec update is “how hidden endpoints are represented and which overlays carry them,” not “call `doMultiTrackerAnnounce` toward opentrackr.”

### Suggested commit series (after rebase onto `origin/main`)

1. `docs(bep): dictionary hostname peers for .onion / .b32.i2p`
2. `docs(i2p): I2P-BT tracker profile (HTTP-over-SAM, vs i2psnark)`
3. `docs(nip): map kind 30078 host/port to tracker dict ip`
4. `fix(tracker): parse dict peers with hostname ip`
5. `feat(session): dial tracker hostname peers (SOCKS onion / SAM i2p)`
6. `feat(i2p): HTTP-over-SAM tracker announce`  (closes P3 of the 2026-06-08 brainstorm)
7. `feat(i2p): DHT announce/get_peers over I2P`  (P4; largest — split PR only if needed)

Zig 0.16: use Homebrew `zig` 0.16 after rebase; do not build this series with 0.15.2.

---

## Open questions

- Which I2P tracker URL is the v1 default (postman `tracker2.postman.i2p` vs configurable announce-list only)?
- I2P DHT: SAM DATAGRAM vs I2P-BT’s existing DHT conventions — confirm against qBittorrent/i2psnark before commit 7.
- Tor: is a documented onion HTTP tracker in scope for v1, or is Tor discovery 30078 + parse-only until one exists?
- BEP number: unassigned in-repo (`docs/beps/draft-hostname-peers.md`) vs unofficial `BEP XXX` placeholder.
- Whether to allow a tracker dict event that carries **both** IPv4 and hostname (30078 already prefers `host` and ignores `ip`).
