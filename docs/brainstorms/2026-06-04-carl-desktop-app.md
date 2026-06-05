# carl Desktop App — Brainstorm

_2026-06-04_

Turn the `carl` BitTorrent CLI into a cross-platform desktop app that pixel-faithfully
reproduces the design prototype (Claude Design handoff bundle `cart-tor-ux`), with every
screen wired to a live `carl` backend.

## Clarified Problem Statement

**Goal:** Build `carl` into a real cross-platform desktop app (macOS-first) that
pixel-faithfully reproduces the prototype's four screens — Transfers, Discover, Seeding,
Settings — plus the Add-transfer modal and Tor-seed onion callout, with every screen wired
to a live `carl` backend.

**Architecture (locked with the user):**

- **Shell:** Tauri (Rust + system webview); `carl` ships as a sidecar.
- **Backend link:** a new `carl daemon` mode exposing a localhost API; the GUI is a thin client.
- **Scope:** all screens fully wired — no permanent mock data.
- **Communication (chosen):** localhost HTTP + WebSocket sidecar (Approach A below).

**The core challenge:** `carl` today is a *one-shot text CLI*
(`info` / `announce` / `download` / `seed` / `search` / `nostr-keygen`). `session.zig`
(~60KB) drives a single download or seed to completion and prints human-readable lines. The
GUI needs the inverse: a **persistent process managing N concurrent torrents + seeds**, that
exposes structured state and live updates. That refactor is ~70% of the work; the UI port is
the visible 30%.

### The API surface the screens demand

Grounded in `data.jsx` and the screen `.jsx` files:

- **Live state (stream):** transfers (status / route / sources / pct / size / down / up /
  eta / peers / seeds / ratio / onion), per-transfer **peers** (addr / port / client / rates /
  pct / flags / onion-flag), **pieces** heatmap (have / downloading / missing), **files**
  (name / size / pct / prio), **sources** (tracker / DHT / Nostr with state + interval),
  **relays** (url / state / net / events), **seeds** (visibility / onion / upTotal /
  leechers / ratio).
- **Commands:** add transfer (magnet | .torrent path | HTTP URL) × route × `--nostr`; seed
  file × visibility (direct / proxy / tor) × announce → returns `.onion`; Nostr NIP-35 search;
  pause / resume / remove; set route + SOCKS endpoint; edit relay list; keygen / import-nsec
  → npub; leak-check.
- **Identity rule:** expose npub only — never the nsec (design stores it in the OS keychain).

**Constraints:**

- Reuse `ws.zig` / `relay.zig` / `proxy.zig` rather than reinventing.
- Keep the privacy model (3 routes × 3 sources) consistent across every screen.
- No accounts / social features.
- Serif (Newsreader) + IBM Plex Sans / Mono type system; self-hosted fonts (matching commit `4abcbb7`).

**Non-goals:** mobile, a hosted/multi-user service, changing the wire/BitTorrent internals,
auth beyond a local-only token.

**Success criteria:** launch the app → add a real magnet over Tor → watch live piece/peer
progress → seed a file as a hidden service and copy its `.onion` → search Nostr in Discover →
all matching the mock visually.

## Chosen Approach — A: Localhost HTTP + WebSocket sidecar

- **Sketch:** `carl daemon` runs an HTTP + WS server on `127.0.0.1:<port>` (reusing `ws.zig`,
  which already speaks WebSocket for relays). REST/JSON for commands, a WS channel pushing
  live transfer/peer/relay deltas. Tauri spawns it as a sidecar; React fetches + subscribes
  directly.
- **Affected:** new `src/daemon.zig` + `src/api.zig`; refactor `session.zig` →
  `TorrentManager`; `main.zig` gains a `daemon` command; new `desktop/` (Tauri + Vite/React
  port of the `.jsx` files).
- **Tradeoffs:**
  - Debuggable with `curl` / browser devtools.
  - The daemon is independently useful (headless, future web UI, reuses the existing `site/`).
  - Clean language boundary between Zig and the web UI.
  - Needs a port + a local-only auth token; a second listening socket to secure.
- **Effort:** L

**Why A over the alternatives:** It's the most debuggable, reuses `ws.zig` directly for the
live channel, and makes `carl daemon` a first-class headless capability (not just GUI
plumbing) — which also pays off for the existing `site/`. Secure the port with a random token
that Tauri passes to both sides; bind to loopback only.

The two rejected alternatives were **B: stdio JSON-RPC through Tauri** (no open socket, but
harder to debug and all traffic funnels through Rust) and **C: in-process Zig↔Rust FFI** (zero
IPC, but the riskiest path across a threaded, allocating, async-networking core, and it
contradicts the daemon decision).

## Sequencing (de-risks the refactor)

Freeze the JSON contract from `data.jsx` first and ship the daemon **serving that mock data**,
build the entire Tauri + React UI against the frozen contract, *then* replace mock handlers
with real `TorrentManager` calls one endpoint at a time. UI and backend progress in parallel;
the UI is never blocked on the Zig refactor.

1. **Contract** — freeze the JSON schema from `data.jsx`; document endpoints + WS message types.
2. **Mock daemon** — `carl daemon` serves the frozen contract from static fixtures.
3. **Tauri + React port** — scaffold `desktop/`, port the `.jsx` near-verbatim, wire to the
   mock daemon. Pixel-parity pass against the screenshots.
4. **TorrentManager refactor** — turn `session.zig` into a persistent multi-torrent/seed manager.
5. **Wire endpoints** — replace mock handlers with real manager calls, one screen at a time:
   Transfers → Discover → Seeding → Settings.

## Open questions (non-blocking — sensible defaults exist)

- **Tauri v2** assumed (current; better sidecar + mobile story). OK?
- **React port fidelity:** keep React (Vite + TS, port the `.jsx` near-verbatim) vs. rewrite
  in another framework. Default: keep React — fastest route to pixel-parity.
- **Daemon lifecycle:** app-managed sidecar (starts/stops with the window) vs. a standalone
  daemon the app attaches to. Default: app-managed, with attach-if-running.
- **Tor/keychain:** assume a system Tor at `127.0.0.1:9050` and OS keychain for the nsec
  (matches the mock). Confirm vs. bundling Tor.
