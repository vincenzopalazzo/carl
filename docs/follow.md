# `carl follow` — mirror a publisher

`carl follow <npub>` turns a machine into a **mirror** of everything a Nostr
pubkey publishes: it watches the publisher's NIP-35 torrent events (kind 2003),
downloads every torrent it doesn't have yet, and re-seeds each one
indefinitely — publishing its **own** kind-30078 peer-announce so leechers can
dial the mirror too.

The headline use case: seed files from your laptop, and a server elsewhere
(e.g. on I2P) follows your npub and keeps everything alive even when the
laptop is offline.

```
carl follow <npub|pubkey-hex> [--route direct|i2p] [--dir d]
            [--i2p-sam host:port] [--external-ip ip] [--interval secs]
```

## How it works

Per torrent, the mirror runs a two-phase, restart-safe lifecycle:

1. **download** — an outbound-only session. With no local `.torrent` yet, the
   metadata is bootstrapped over BEP 9 (magnet-style) from the publisher's
   seed; peers come from kind-30078 peer-announces on the configured relays
   and are re-queried whenever the transfer has zero peers. The resolved
   `.torrent` is checkpointed to `<dir>/<infohash>.follow.torrent`, so a
   restart resumes from disk (verifying existing pieces) instead of
   re-bootstrapping.
2. **seed** — a fresh session built from the resolved metainfo:
   - `--route i2p`: same shape as `carl seed --i2p-seed` — a SAM session with
     a **persisted destination** (stable `.b32.i2p` per torrent, key under
     `<config>/i2p-seeds/`) feeds a loopback listener via `STREAM FORWARD`.
   - `--route direct`: a public listener on a free port; with
     `--external-ip <ip>` the mirror publishes a dialable IPv4 announce.

   Either way the mirror publishes its peer-announce **under the local Nostr
   identity** (run `carl nostr-keygen` once on the mirror host; `carl whoami`
   prints the configured npub). Kind 30078 is parameterized-replaceable keyed
   by infohash *per author*, so the publisher's announce and any number of
   mirrors' announces coexist — leechers discover and dial all of them.

The relay poll repeats every `--interval` seconds (default 60), so torrents
published while the mirror is running are picked up live. Events are verified
(Schnorr) and the author is checked against the followed pubkey — a malicious
relay can't inject foreign torrents into the mirror.

## Why Nostr (and not BEP 46)

The closest BitTorrent-native analog is BEP 46 (mutable DHT pointers,
`urn:btpk:`), but it carries only the *latest* item per key — no back-catalog —
and has very sparse client support. A relay-stored event log gives the full
catalog, works behind NAT/I2P, and survives the publisher being offline.
RSS-style auto-download (autobrr/flexget) is the same architecture with a
centralized feed; here the feed is the publisher's signed events on relays.

## Demo: laptop seeds, server mirrors over I2P

Prereqs on both machines: an I2P router with SAM enabled (default
`127.0.0.1:7656`).

On the **laptop** (publisher):

```sh
carl nostr-keygen            # once; `carl whoami` prints your npub
carl create myfile.bin -o myfile.torrent
carl seed myfile.torrent /path/to/dir --port 17901 --i2p-seed --nostr
```

On the **server** (mirror):

```sh
carl nostr-keygen            # the mirror's own identity, used for announces
carl follow <your npub> --route i2p
```

The server discovers the kind-2003 event, downloads over I2P from the
laptop's `.b32.i2p`, then logs:

```
info(follow): mirror seeding myfile.bin at <mirror>.b32.i2p
info(follow): peer-announce published: 2/3 relays
```

From then on the file is fetchable even with the laptop off — any client
following the same npub (or downloading the magnet with `--nostr` on an
i2p-routed daemon) finds the mirror's announce and pulls from it.

## Desktop / daemon

The desktop app has a **Following** tab with the same engine embedded in the
daemon: paste an npub, pick `direct` or `i2p`, and each followed publisher
shows its mirrored torrents with live phase (downloading → seeding) and rates.
Follows persist in the daemon's SQLite state and are restored (resuming from
the checkpointed torrents) on restart. The HTTP API is
`GET/POST /api/follows` + `DELETE /api/follows/<id>` (see
`docs/daemon-api.md`).

### Running as a service

A systemd user unit (`%i` is the npub):

```ini
# ~/.config/systemd/user/carl-follow@.service
[Unit]
Description=carl follow mirror for %i (download + reseed over I2P)
After=network-online.target

[Service]
ExecStart=%h/bin/carl follow %i --route i2p --interval 60
StandardOutput=append:%h/carl-follow.log
StandardError=append:%h/carl-follow.log
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
```

```sh
systemctl --user enable --now carl-follow@<npub>.service
loginctl enable-linger   # keep it running after logout (may need an admin)
```

## Limits / follow-ups

- Routes: `direct` and `i2p`. A `tor` mirror needs per-torrent hidden
  services via the ControlPort (the seeding machinery exists; wiring it into
  follow is a follow-up).
- NIP-09 deletions (kind 5) are not yet honored — a polite mirror should stop
  seeding a torrent its publisher deleted.
- A failed mirror thread (e.g. invalid checkpoint) is retried on the next
  process restart, not in-session.
- The mirror dials every announce for an infohash; it doesn't yet dedupe
  endpoints across relays (harmless duplicate connections).
