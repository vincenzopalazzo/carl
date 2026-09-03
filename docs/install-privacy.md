---
name: carl
description: Install carl desktop (DMG) and CLI with full privacy routing (direct, proxy, Tor hidden service, I2P) plus Nostr discovery, drive sync and follow mirroring.
---

# carl — Install & Privacy Skill

This skill explains how to install carl on macOS/Linux and use every privacy feature. Use it whenever the user asks to install, update, seed, or download anonymously.

## Install

### Desktop DMG (macOS)

**From GitHub Releases (recommended for other devices):**

1. Download `carl_<arch>.dmg` from the latest Release (e.g. `v0.3.2`). The Release workflow builds on `macos-latest` with `zig build -Doptimize=ReleaseSafe` + `npx tauri build`. The sidecar daemon is bundled via `externalBin: ["binaries/carl"]` and staged by `desktop/scripts/stage-sidecar.sh` (`beforeBuildCommand`), so the DMG is self-contained — no `$PATH` needed.

2. **If the Release was signed + notarized** (repo secrets `APPLE_CERTIFICATE`/`APPLE_ID`/`APPLE_TEAM_ID` set):
   - Double-click DMG → drag `carl.app` to Applications → launch. Gatekeeper passes.

3. **If the Release is unsigned** (ad-hoc signature, current default when secrets absent):
   - macOS will show *"carl is damaged / can’t be opened"*. On the **other device**:
     ```sh
     # Option A — Finder
     # Right-click carl.app → Open → Open

     # Option B — Terminal (clears quarantine)
     xattr -cr /Applications/carl.app
     open /Applications/carl.app

     # Option C — allow once
     sudo spctl --add /Applications/carl.app
     ```
   - Verify sidecar bundled: `ls /Applications/carl.app/Contents/MacOS/carl` should exist (4–5 MB ReleaseSafe).

**From source (you, super fine locally):**

```sh
git clone github.com/vincenzopalazzo/carl && cd carl
zig build -Doptimize=ReleaseSafe
desktop/scripts/stage-sidecar.sh   # stages zig-out/bin/carl → desktop/src-tauri/binaries/carl-$(rustc -Vv | awk '/host:/{print $2}')
cd desktop && npm ci && npx tauri build   # -> desktop/src-tauri/target/release/bundle/dmg/*.dmg
cp zig-out/bin/carl /Applications/carl.app/Contents/MacOS/carl  # hot-swap for dev
```

**CLI symlink (like Docker):** Desktop → Settings → *Install CLI* creates `/usr/local/bin/carl` (admin prompt, root-owned symlink into the bundle) or `~/.local/bin/carl` (per-user). Remove via Settings → *Remove*.

### Linux

- Download `*.deb` / `*.AppImage` + `carl-x86_64-unknown-linux-gnu` from Releases.
- Or `zig build -Doptimize=ReleaseSafe && sudo install -m755 zig-out/bin/carl /usr/local/bin/carl`.

### Verify install

```sh
carl --version   # carl 0.3.1
carl --help
carl whoami      # npub / hex
# Desktop: check daemon live
lsof -i :8077   # daemon LISTEN 127.0.0.1:8077
curl -s -H "X-Carl-Token: wrong" http://127.0.0.1:8077/api/state -w "%{http_code}\n" # 401
```

## Privacy Routes — pick one per transfer

All routes persist per-transfer; `carl daemon` enforces **fail-closed**: if the chosen transport cannot be built, the transfer never leaks to clearnet.

| Route | Flag | How it hides you | When to use | What it disables |
|---|---|---|---|---|
| **direct** | `--route direct` (default) | No hiding — real IP to trackers/peers/relays | Fastest, testing | — |
| **proxy** | `--route proxy --socks socks5h://` | Peers + trackers tunneled via SOCKS5h (**remote DNS**, no leak). Supports `socks5h://` (recommended), `socks5://` (local DNS, leaks), `http://` CONNECT. Auth `user:pass@` supported. | Hide IP with any SOCKS/HTTP proxy (incl. Tor SOCKS without onion) | DHT/UDP trackers if proxy fails |
| **tor** | `--route tor --tor-control 127.0.0.1:9051` | Seeder publishes ephemeral **v3 .onion** via Tor ControlPort (cookie auth); leecher dials .onion via Tor SOCKS. No public BT port needed. | Seed behind NAT, publish .onion on Nostr | DHT, inbound clearnet, requires `--nostr` |
| **i2p** | `--route i2p --i2p-sam 127.0.0.1:7656` | Seeder gets stable **.b32.i2p** via SAM bridge (destination persisted per infohash); leecher dials via SAM. | I2P-only swarm | Clearnet, needs i2pd/Java I2P + SAM on |

**Proxy vs Tor vs I2P split:** For seeding, `proxy` only hides leecher TCP; `tor`/`i2p` hide the *seed’s* address. Nostr relay traffic (`wss://`) is *not* proxied on `tor`/`i2p` — see docs.

## Quick start by privacy level

### 1. Direct (no privacy)
```sh
carl download file.torrent --output-dir ./out
carl seed file.torrent ./data --external-ip 1.2.3.4
```

### 2. Proxy / anonymous (recommended minimal)
`tor` must have `SocksPort 9050` + `ControlPort 9051 CookieAuthentication 1` if using Tor SOCKS.

```sh
# leecher via proxy
carl download "magnet:?xt=urn:btih:..." --route proxy --socks socks5h://127.0.0.1:9050 --nostr

# seeder via proxy (outbound peers hidden)
carl seed file.torrent ./data --route proxy --socks socks5h://127.0.0.1:9050 --nostr
```

### 3. Tor hidden-service seed (seed behind NAT)
```sh
# torrc: ControlPort 9051, CookieAuthentication 1, SocksPort 9050
carl seed file.torrent ./data --route tor --tor-control 127.0.0.1:9051 --tor-cookie ~/.tor/control_auth_cookie --nostr --description "My release"
# leecher (any host with Tor SOCKS)
carl download file.torrent --route proxy --socks socks5h://127.0.0.1:9050 --nostr
```

### 4. I2P seed
```sh
# i2pd: sam.enabled=true, sam.address=127.0.0.1, sam.port=7656
carl seed file.torrent ./data --route i2p --i2p-sam 127.0.0.1:7656 --nostr
carl download file.torrent --route i2p --i2p-sam 127.0.0.1:7656 --nostr
```

## Nostr, Drive, Follow

- **Nostr discovery:** `--nostr` publishes NIP-35 kind 30078 peer-announce; `carl search <query> --limit 20` finds torrents.
- **Drive (shared folder):** `carl drive create <dir> --name <drive> --route direct|i2p` watches folder, `carl drive subscribe <npub> <drive> --dir ./mirror --also <npub>` mirrors + re-seeds.
- **Follow (mirror publisher):** `carl follow <npub> --route direct|i2p --dir ./mirror` mirrors every torrent.

Relays: `~/.config/carl/relays` (one `wss://` per line, `#` comments). Invalid lines now warn+skip, no spam. Defaults: `wss://relay.damus.io`, `wss://nos.lol`, `wss://relay.nostr.band`.

## Troubleshooting DMG on other devices

- **Damaged / cannot be opened:** unsigned DMG → `xattr -cr /Applications/carl.app` or Right-click Open. Signing+notarization requires the 6 `APPLE_*` secrets in repo Settings → Secrets.
- **Daemon offline:** check `lsof -i :8077`, `/Applications/carl.app/Contents/MacOS/carl` exists, `~/Library/Logs/carl/daemon.log` (rotated to `daemon.log.old` at 2 MiB).
- **CLI not found:** GUI app PATH is minimal — use the bundled `/Applications/carl.app/Contents/MacOS/carl` or Settings → Install CLI.

## Verify privacy

```sh
# Proxy/Tor is enforced: clearnet disabled when route=proxy/tor/i2p
# Check daemon logs: info(session): proxy enabled (socks5h 127.0.0.1:9050)
# For Tor onion: Settings → Seeds shows .onion, daemon log: "Tor hidden service ... .onion"
# For I2P: log "i2p seed: forwarding <b32>.b32.i2p -> 127.0.0.1:<port>"
```
