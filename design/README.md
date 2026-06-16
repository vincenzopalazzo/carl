# carl — design prototype

This directory is a cloned handoff bundle from [Claude Design](https://claude.ai/design):
a high-fidelity, clickable prototype of a desktop GUI for `carl`, the privacy-first
BitTorrent client. It is the **design source of truth** — HTML/CSS/JS mockups meant to be
recreated in the real desktop app (`../desktop`, Tauri + React) and marketing site
(`../site`).

> The prototype medium is HTML/CSS/JS — these are mockups, not production code. When
> implementing for real, match the visual output (tokens, layout, components); don't copy
> the prototype's internal structure unless it happens to fit.

## What's here

| File | Screen / purpose |
|------|------------------|
| `carl.html` | App shell — loads everything below; the primary design |
| `landing.html` | Marketing / landing page (standalone, plain HTML) |
| `app.jsx` | Shell: sidebar nav, routing, tweaks panel, mount |
| `data.jsx` | Mock domain data (transfers, peers, pieces, relays, seeds, discover) |
| `components.jsx` | Shared atoms — route badge, status pill, progress bar, piece grid, relay dots, copy field, source chips, icons |
| `transfers.jsx` | **Transfers** screen + expandable detail panel (Peers / Pieces / Sources / Files) |
| `discover.jsx` | **Discover** — Nostr (NIP-35) search, relay-status strip, result cards |
| `seeding.jsx` | **Seeding** screen + "Seed a file" flow + Tor onion callout |
| `settings.jsx` | **Settings** — Anonymity (Direct/SOCKS5/Tor), Nostr relays + identity, General |
| `addmodal.jsx` | Add-transfer modal (magnet / .torrent / HTTP URL, route selector, `--nostr` toggle) |
| `tweaks-panel.jsx` | Reusable design-tweak panel (accent, density, route labels) — design-tool scaffold |
| `assets/` | Hero screenshot used by `landing.html` |
| `screenshots/` | Reference captures of each screen |
| `chats/chat1.md` | The full design conversation — where the intent lives |

## Design system

- **Brand:** `carl`, lowercase wordmark (curl, but for torrents). Newsreader (serif) for the
  wordmark, screen titles, and big numbers; IBM Plex Sans for UI; IBM Plex Mono for hashes,
  onions, IPs, ports, magnets.
- **Accent:** violet `#8b7cf6` (teal alternate available in Tweaks) — kept distinct from the
  route colors so "brand" is never confused with "how a transfer is routed".
- **Surface:** near-black charcoal in four elevation layers (`--bg-0` … `--bg-3`), dark-first.
- **The privacy system** (consistent everywhere):
  - three **routes** — `clearnet` (amber), `proxied` (blue), `tor` (green + onion ring)
  - three **discovery sources** — `tracker`, `dht`, `nostr`
  - Surfaced as badges and dots, never buried in a menu.

All design tokens live in the `:root` block at the top of `carl.html` (and are duplicated in
`landing.html`).

## Running the prototype

`carl.html` pulls React, ReactDOM, and Babel from a CDN and loads the `.jsx` files with
`<script type="text/babel" src="…">`. Browsers block those `src` fetches over `file://`, so
serve the directory over HTTP:

```sh
cd design
python3 -m http.server 8000
# then open http://localhost:8000/carl.html   (the app)
#           http://localhost:8000/landing.html (the landing page)
```

`landing.html` is plain static HTML and also opens directly via `file://`.
