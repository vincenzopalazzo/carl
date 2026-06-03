# Plan: MSE/PE protocol encryption (issue #12)

Source: `docs/brainstorms/2026-06-03-mse-pe-protocol-encryption.md`

## Goal

Vuze MSE/PE on peer TCP: DH + RC4 full stream (`0x02`), then existing BEP 3. Prefer encrypted peers; plaintext fallback (mode 2). Tracker `supportcrypto` in v1.

## PR stack

| PR | Branch | Scope |
|----|--------|--------|
| 1 | `feat/mse-crypto` | `src/mse.zig`: DH, SHA1, RC4, handshake, unit tests |
| 2 | `feat/mse-peer-outbound` | `peer.zig`: MSE-first outbound + plaintext fallback |
| 3 | `feat/mse-session-inbound` | `session.zig`: accept detect + responder |
| 4 | `feat/mse-cli` | `main.zig` flags `--mse`, `--prefer-encryption` |
| 5 | `feat/mse-tracker` | `tracker.zig`: supportcrypto / crypto_flags |
| 6 | `feat/mse-docs` | `docs/mse-pe.md` + integration test |

## PR 1 acceptance

- Fixed 768-bit DH prime; modpow; Ya/Yb 96-byte BE wire form
- RC4 with 1024-byte keystream discard
- `HASH('req1'|'req2'|'req3'|'keyA'|'keyB', …)` per Vuze spec
- Initiator/responder complete 5-step handshake over `std.net.Stream`
- Unit tests: DH vectors, RC4 discard, req hashes, loopback handshake

## Non-goals (v1)

AES, BEP 8, UDP encryption, DHT crypto_flags.