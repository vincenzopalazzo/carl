# Carl - BitTorrent Light Client

## References

- BEP Index: https://www.bittorrent.org/beps/bep_0000.html
- BEP 3 (The BitTorrent Protocol): https://www.bittorrent.org/beps/bep_0003.html
- BEP 7 (IPv6 Tracker Extension): https://www.bittorrent.org/beps/bep_0007.html
- BEP 5 (DHT Protocol): https://www.bittorrent.org/beps/bep_0005.html
- BEP 10 (Extension Protocol): https://www.bittorrent.org/beps/bep_0010.html
- NIP-01 (Nostr basic protocol): https://github.com/nostr-protocol/nips/blob/master/01.md
- NIP-19 (bech32 entities): https://github.com/nostr-protocol/nips/blob/master/19.md
- NIP-35 (Torrents): https://github.com/nostr-protocol/nips/blob/master/35.md
- BIP-340 (Schnorr): https://github.com/bitcoin/bips/blob/master/bip-0340.mediawiki
- RFC 6455 (WebSocket): https://datatracker.ietf.org/doc/html/rfc6455

## Reference implementation

qBittorrent (https://github.com/qbittorrent/qBittorrent) is the reference
implementation for client behavior. Its transfer engine is libtorrent-rasterbar
(https://github.com/arvidn/libtorrent), so engine-level behavior — peer
management, connection limits, request pipelining, choking/unchoking, piece
picking, tracker/DHT retry policy — should be checked against libtorrent's
implementation and defaults; UI/UX conventions against qBittorrent itself.
When tuning constants (timeouts, backoff schedules, queue depths, peer caps),
prefer values justified by what libtorrent/qBittorrent ships over invented ones.

## Build

- Language: Zig 0.15
- Build: `zig build`
- Test: `zig build test`
- Format: `zig fmt src/`

## Install (always use a fresh binary)

Whenever you test `carl` by hand or run it via `$PATH`, rebuild and reinstall
first so you are never running a stale binary (a stale `~/.local/bin/carl`
silently produces wrong results — e.g. a 0-byte `unknown` file). After any code
change, before manual/e2e testing:

```sh
zig build -Doptimize=ReleaseSafe
cp zig-out/bin/carl ~/.local/bin/carl   # the binary `carl` on $PATH resolves to
```

Prefer invoking the freshly built `./zig-out/bin/carl` directly in scripts, and
keep the installed `~/.local/bin/carl` in sync after every change.

## UI / design fidelity

The `design/` directory is the **design source of truth** — the high-fidelity
prototype handed off from Claude Design (`carl.html`, `landing.html`, the `*.jsx`
mockups, and the `:root` design tokens at the top of `carl.html`).

Every UI change MUST match the design 1-1 with the code. Before and after touching
any UI (the `desktop/` app or the `site/` landing page):

- Open the relevant prototype in `design/` and match it exactly — layout, spacing,
  colors, typography, component structure, and states.
- Use the design tokens verbatim (colors, fonts, radii, the route/privacy system:
  `clearnet`/`proxied`/`tor` and `tracker`/`dht`/`nostr`). Do not invent new
  values, components, or visual treatments that aren't in `design/`.
- If a needed UI is not covered by the design, update `design/` first (keep it in
  sync), then implement the code to match — never let the code drift from `design/`.

The implementation tech may differ (Tauri/React vs. the prototype's Babel-in-browser
setup), but the rendered result must be pixel-perfect against `design/`.
