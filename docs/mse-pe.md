# Message Stream Encryption (MSE/PE)

Carl support for [Vuze MSE/PE v1.0](https://web.archive.org/web/20161231215426/http://wiki.vuze.com/w/Message_Stream_Encryption) (issue [#12](https://github.com/vincenzopalazzo/carl/issues/12)). This is **protocol obfuscation** on peer TCP connections: reduce passive BitTorrent fingerprinting and ISP shaping. It is not a substitute for Tor (`--proxy`, `--tor-seed`) or TLS on trackers.

**Plan and PR stack:** [plans/2026-06-03-mse-pe-protocol-encryption.md](plans/2026-06-03-mse-pe-protocol-encryption.md)  
**Design notes:** [brainstorms/2026-06-03-mse-pe-protocol-encryption.md](brainstorms/2026-06-03-mse-pe-protocol-encryption.md)

---

## Impact of PR #27 (PR 1/6 — crypto module)

[PR #27](https://github.com/vincenzopalazzo/carl/pull/27) adds the **foundation only**. It does **not** turn on encryption for `carl download` / `carl seed` yet.

### What changes when this PR merges

| Area | Impact |
|------|--------|
| **New code** | `src/mse.zig` (~610 lines): 768-bit DH, SHA-1 key derivation, RC4 (+ 1024-byte discard), Vuze 5-step handshake, `mse.Stream` encrypt/decrypt wrapper |
| **Library export** | `carl.mse` from `src/lib.zig` for tests and future peer/session wiring |
| **Tests** | Unit tests: DH vectors, RC4 discard, TCP loopback initiator↔responder handshake |
| **Docs** | Implementation plan in `docs/plans/2026-06-03-mse-pe-protocol-encryption.md` |
| **Binary / CLI** | **No change** — no new flags, no behavior change for end users |
| **Peer I/O** | **No change** — `peer.zig`, `session.zig`, `wire.zig` still use cleartext `std.net.Stream` |
| **Trackers** | **No change** — no `supportcrypto` / `crypto_flags` on announce yet |
| **Tor / proxy** | **No change** — design is `[SOCKS/Tor tunnel] → [MSE RC4] → [BEP 3]`; wiring is PR 2–4 |
| **Dependencies** | **None** — pure Zig (RC4 and DH in-tree; SHA-1 via `std.crypto.hash.Sha1`) |
| **Issue #12** | **Not closed** — integration and tracker extension are follow-up PRs |

### Intended stack (after full feature lands)

```
TCP (direct, or SOCKS CONNECT / .onion)
  → MSE/PE handshake (DH + optional RC4 full stream, crypto_select 0x02)
  → BEP 3 handshake + length-prefixed messages (unchanged wire format, encrypted bytes if RC4)
```

### Public API added (for integrators)

- `mse.handshakeInitiator` / `mse.handshakeResponder` — complete negotiation on a connected `std.net.Stream`
- `mse.Stream` — `read` / `write` / `writeAll` / `close` over RC4 or plaintext payload mode
- `mse.Options` — `skey` (info_hash), `crypto_provide`, optional `ia` (e.g. serialized BEP 3 handshake in step 3)
- Crypto helpers: `hashReq1`, `dhPublicKey`, `dhSharedSecret`, `initRc4FromShared`, etc.

### Security and privacy posture (unchanged for users today)

- **MSE is obfuscation**, not authentication. Anyone who knows the torrent **info_hash** can complete the handshake (SKEY). Effective strength is on the order of tens of bits against passive observers, not modern AEAD.
- **Tor / proxy** still hide IP; MSE hides that the bytes look like BitTorrent once peers are connected.
- **Do not log** shared secrets `S`, RC4 keys, or DH pads in production paths (module is written with that in mind).

### Operational impact today

- **CPU:** No extra cost in normal `carl` runs until peer integration enables MSE on connections.
- **CI:** `zig build test` runs new `mse` tests; existing integration tests unchanged.
- **Interop:** Not validated against libtorrent/qBittorrent until PR 2+ and manual/PCAP tests; PR 27 only proves Carl↔Carl loopback handshake.

### Known gaps in PR 27 (before merge)

Review on PR #27 flagged **RC4 resync** in step 3/4 when data arrives in multiple `read()` chunks: trial decrypt loops must not advance the live `dec` stream or mutate ciphertext in place. Fix before relying on this module with real swarms.

### What comes next (user-visible impact)

| PR | User-visible effect |
|----|-------------------|
| 2 `peer.zig` | Outbound: try MSE first, fall back to plaintext BEP 3 (Vuze mode 2) |
| 3 `session.zig` | Inbound: accept MSE or detect plaintext handshake |
| 4 CLI | `--mse`, `--prefer-encryption`, optional `--require-encryption` |
| 5 `tracker.zig` | `supportcrypto=1`, peer `crypto_flags` bias |
| 6 | This doc expanded + end-to-end integration test |

Until PR 4, **`carl` behaves exactly as before** with respect to encryption.

---

## Protocol summary (reference)

| Piece | Detail |
|-------|--------|
| DH | 768-bit safe prime P (fixed), G=2, 96-byte big-endian Ya/Yb |
| SKEY | BitTorrent **info_hash** (20 bytes) |
| Keys | `HASH('keyA'/'keyB', S, SKEY)` → RC4; discard first **1024** keystream bytes |
| Mode | Target **0x02** RC4 full stream after handshake |
| Handshake | 5 steps; step 3 sends `HASH('req1',S)` and SKEY hash **in plaintext**, then `ENCRYPT(VC, crypto_provide, …, IA)` |

---

## Related docs

- [proxy.md](proxy.md) — Tor SOCKS for peer TCP; clearnet `wss` split when `--proxy` is set
- [tor-hidden-service.md](tor-hidden-service.md) — onion seeding; MSE applies on top of the tunneled stream when enabled