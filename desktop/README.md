# carl desktop

The desktop GUI for `carl` — a Tauri v2 + React + TypeScript app that wraps the
`carl daemon` (see `../docs/daemon-api.md`). It's a faithful build of the design
prototype's four screens — Transfers, Discover, Seeding, Settings — wired to the
real daemon over HTTP + a live WebSocket.

## Architecture

```
React UI (Vite)  ──HTTP + WS──>  carl daemon  ──>  TorrentManager / Nostr / Tor
      │                              ▲
      └── Tauri shell spawns it as a child, reads the token, hands it to the UI
```

- `src/api/` — the daemon client (`client.ts`), TypeScript contract types
  (`types.ts`), and a React store (`store.tsx`) that holds live state from
  `GET /api/state` + the `/ws` push channel, with auto-reconnect.
- `src/components/`, `src/screens/`, `src/modals/` — the ported UI. `styles.css`
  is the prototype's stylesheet verbatim; fonts are self-hosted under `public/`.
- `src-tauri/` — the Tauri v2 shell. On launch it spawns `carl daemon`, parses
  the `token:` line from its banner, and exposes `{ base, token }` to the
  webview via the `daemon_config` command. The daemon is killed on exit.

## Develop

```sh
# 1. Run a daemon the browser build can talk to (dev defaults: :8088 / "carldemo")
carl daemon --port 8088 --token carldemo

# 2. Browser dev (fast iteration):
npm install
npm run dev            # http://localhost:5180

# Override the daemon target with VITE_CARL_BASE / VITE_CARL_TOKEN.
```

Native app (Tauri auto-spawns its own daemon — point `CARL_BIN` at the binary):

```sh
CARL_BIN=../zig-out/bin/carl npm run tauri dev      # dev window
CARL_BIN=../zig-out/bin/carl npm run tauri build     # release bundle
```

## Build / typecheck

```sh
npm run build      # tsc --noEmit && vite build
```

## Not yet wired (follow-ups, tracked in ../docs/daemon-api.md)

- Per-transfer detail tabs (peer rows, real piece heatmap, per-file progress) —
  need a session-published snapshot from the daemon. The Pieces tab currently
  derives a have/missing heatmap from the percentage.
- The "Seed a file" creation flow (torrent creation + Tor onion generation).
- Editable Settings persistence (only the route selector is live; other fields
  reflect the daemon's launch flags).
- Bundling the daemon as a Tauri sidecar resource (today the shell resolves it
  via `CARL_BIN` or `carl` on `PATH`).
