# `carl drive` — shared folders over Nostr

`carl drive` turns a local folder into a **shared drive**, Google-Drive-style:
a publisher watches a directory, every file in it becomes its own torrent, and
a signed **drive index** on Nostr relays maps each path to its torrent's
infohash. Subscribers mirror the folder, converge on every index update, and
re-seed what they download — publishing their **own** kind-30078
peer-announces so other subscribers can dial them too.

The headline use case: drop a file in a folder on your laptop, and a server
(or a friend's machine) that subscribes to your npub + drive name picks it up
automatically — edits propagate the same way, and nothing is ever deleted
remotely, only quarantined.

```
carl drive create <dir> --name <drive> [--route direct|i2p] [--external-ip ip] [--interval secs]
carl drive subscribe <npub|pubkey-hex> <drive-name> [--also <npub>]... [--dir d]
       [--route direct|i2p] [--interval secs]
```

- `create` watches a **flat** folder (v1: no subdirectories) and publishes
  every file in it as a torrent plus the kind-30035 (NIP-33) drive index.
  `--interval` is the folder-scan period (default 5s).
- `subscribe` mirrors a publisher's drive into `--dir` (default
  `<work dir>/drive-<pubkey prefix>-<name>`), converging on every index
  update. `--interval` is the relay-poll period (default 15s). `--also` adds
  extra writer pubkeys (multi-writer, last-writer-wins per path).

## How it works

### The drive index (custom kind 30035)

A drive's whole mutable state lives in ONE Nostr event per (author, drive): a
**kind-30035 drive index**, a NIP-33 parameterized-replaceable event whose `d`
tag is `carl-drive:<name>` (the explicit namespace keeps it from ever
colliding with kind-30078 peer-announces, which share the replaceable range).
The content is empty; every file is a tag:

```
["d", "carl-drive:<name>"],
["file", "<path>", "<infohash_hex>", "<size_dec>", "<mtime_dec>"], ...
```

Paths are relative and validated (no absolute paths, no `..`, no NUL) so a
malicious publisher can't make a subscriber write outside the sync folder.
Relays and subscribers keep only the newest `created_at` per (pubkey, `d`);
the publisher persists its last `created_at` and always publishes with
`created_at = max(now, last + 1)`, so the NIP-33 monotonicity invariant
survives restarts and clock skew.

### Publisher (`create`)

Every `--interval` seconds the folder is scanned:

1. A new or changed file must be **stable across two consecutive scans**
   (same size + mtime) before it's touched — this catches files still being
   written.
2. It's hashed into a single-file torrent (path == filename == torrent name)
   with a **stat guard**: if the file moved between the stat before and the
   stat after hashing, the hash is discarded and retried next pass.
3. The `.torrent` is checkpointed to `<dir>/.carl-drive/<infohash>.follow.torrent`
   and seeded through an embedded `follow.Mirror` — the same download→seed
   engine `carl follow` uses, including its kind-30078 peer-announces under
   the local identity (run `carl nostr-keygen` once; `carl whoami` prints
   your npub).
4. The index is republished with the bumped `created_at`, and the file table
   plus `created_at` are persisted to `.carl-drive/state.json` (atomic
   tmp+rename) **before** the relay publish, so a crash mid-publish still
   leaves the next index strictly newer.

A changed file evicts its old torrent first (new content == new infohash); a
deleted file evicts its torrent and drops the checkpoint. The publisher
**never deletes the user's data files** — they deleted it, carl just stops
seeding it.

### Subscriber (`subscribe`)

Every `--interval` seconds the subscriber polls the configured relays for the
author's (and each `--also` writer's) drive index:

1. For each writer it keeps only the **newest `created_at` across all
   relays**, and rejects regressions against its persisted `applied.json` —
   a re-delivered or back-dated index is stale by definition (replay
   defense). Signatures are verified and the author is checked against the
   expected pubkey, so a malicious relay can't inject foreign files.
2. All writers' indexes are merged **last-writer-wins per path** (highest
   mtime) — that's the multi-writer model: several npubs publish into the
   same drive name, each with their own per-author replaceable index.
3. The merged index is diffed against the applied state:
   - **added / changed** → mirror the torrent via the embedded follow engine
     (BEP 9 metadata bootstrap when needed, peers from kind-30078 announces,
     checkpointed to `.carl-drive/`, then re-seeded indefinitely).
   - **removed** → the local file is **quarantined** into
     `.carl-drive/.trash/` — never unlinked. Publisher wins, but a
     locally-modified file is quarantined loudly (a warning is logged).
   - **renamed** (same infohash at a new path) → the local file is renamed
     in place and re-mirrored under the new name.

The applied table (per-writer indexes) is persisted to
`.carl-drive/applied.json` after every merge.

### Transport and announces

Both roles embed ONE `follow.Mirror` for the per-torrent download→seed
lifecycle; the drive loop replaces follow's NIP-35 poll loop, but
checkpointing, peer discovery, and kind-30078 announces all come from there.
Routes are the same as `carl follow`'s:

- `--route i2p`: every seed gets a stable `.b32.i2p` destination (persisted
  per torrent under `<config>/i2p-seeds/`) and announces it — subscribers
  dial it over their own SAM session. **The default for local/private
  setups** (works between two instances on one machine).
- `--route direct`: seeds bind a public listener; pass `--external-ip <ip>`
  on `carl drive create` so the publisher's seeds publish a **dialable**
  kind-30078 announce (same plumbing as `carl follow --external-ip`). The IP
  must be routable — carl rejects loopback/private IPv4 announces by design,
  so two instances on one LAN/machine still can't discover each other this
  way. Without the flag a direct-route publisher seeds but stays
  undiscoverable.

### Restart resume

Kill and restart either side and it picks up where it left off: per-torrent
`.torrent` checkpoints live in `.carl-drive/` (the follow.Mirror naming is
reused unchanged), the publisher's `state.json` and the subscriber's
`applied.json` record what each side vouches for, and on startup every
vouched-for file is re-seeded or re-mirrored (verifying existing pieces)
before the first scan/poll.

## Public vs private

Access control is **relay-scoped**:

- **Public drive** — publish to public relays. Anyone who knows (or scans
  for) your npub + drive name can read the index and sync the folder.
- **Private drive** — point both sides at a relay you control or an
  access-restricted relay (the relay list lives at
  `~/.config/carl/relays`, one URL per line). Nobody outside that relay sees
  anything.

Two honest caveats for v1:

- **NIP-42 relay auth is not yet honored by carl's relay client** — carl
  ignores `AUTH` challenges, so an auth-requiring relay won't work as a
  private drive relay yet. "Private relay" today means a relay on a private
  network or one restricted by other means.
- **There is no encryption in v1.** On a public relay the whole file catalog
  — every path and size — is world-visible in the cleartext index event, and
  the file contents are fetchable by anyone who reads it. Treat a
  public-relay drive as fully public. Per-recipient encrypted sharing
  (NIP-44/NIP-17-style) is a follow-up layer.

## Demo: two machines sync a folder over I2P

Prereqs on both machines: an I2P router with SAM enabled (default
`127.0.0.1:7656`), and a shared relay (public, or your own — here
`ws://relay.example` stands in).

On the **publisher**:

```sh
carl nostr-keygen                 # once; `carl whoami` prints your npub
mkdir -p ~/drive-demo
carl drive create ~/drive-demo --name demo --route i2p
```

On the **subscriber**:

```sh
carl nostr-keygen                 # the subscriber's own identity (for its re-seed announces)
carl drive subscribe npub1... demo --dir ~/drive-mirror --route i2p
```

Back on the publisher, drop a file in:

```sh
echo "hello from the publisher" > ~/drive-demo/hello.txt
```

Within a scan or two the publisher logs:

```
info(drive): publishing hello.txt (<infohash>, 27 bytes)
info(drive): index published: 2/3 relays
info(follow): mirror seeding hello.txt at <publisher>.b32.i2p
```

and the subscriber follows with:

```
info(drive): new drive index from <pubkey hex>: 1 file(s), created_at <ts>
info(drive): syncing hello.txt (<infohash>, 27 bytes)
info(follow): mirror hello.txt: download complete, starting reseed
info(follow): peer-announce published: 2/3 relays
```

`~/drive-mirror/hello.txt` now matches the publisher's copy byte-for-byte —
and the subscriber is itself seeding it, so a third subscriber can fetch from
either. Edit the file and the new version propagates the same way; delete it
and the subscriber moves its copy into `~/drive-mirror/.carl-drive/.trash/`
instead of unlinking it.

`scripts/e2e_drive.sh` runs exactly this scenario (publish → edit → delete,
independent sha256 verification at each stage) against a local mock relay.

## Desktop / daemon

The same engine is embedded in the daemon (one `Drive` per row, same pattern
as follows): `GET/POST /api/drives` + `DELETE /api/drives/<id>` (see
`docs/daemon-api.md`), with a `drives` array in `GET /api/state` and the
per-second WebSocket push feeding the desktop app's **Drive** tab — each
drive shows its role (publisher/subscriber), writers, route, and per-file
sync phase (starting → downloading → seeding). Drives persist in the daemon's
SQLite state and are restored on restart, resuming from
`.carl-drive/state.json` / `applied.json` and the checkpointed torrents.

### Running as a service

A systemd user unit for the subscriber side (`%i` is the publisher's npub,
the drive name is fixed here — template it further if you run several):

```ini
# ~/.config/systemd/user/carl-drive@.service
[Unit]
Description=carl drive subscriber mirroring %i (route i2p)
After=network-online.target

[Service]
ExecStart=%h/bin/carl drive subscribe %i mydrive --route i2p --interval 60
StandardOutput=append:%h/carl-drive.log
StandardError=append:%h/carl-drive.log
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
```

```sh
systemctl --user enable --now carl-drive@<npub>.service
loginctl enable-linger   # keep it running after logout (may need an admin)
```

The publisher side is the same shape with
`ExecStart=%h/bin/carl drive create /path/to/folder --name mydrive --route i2p`.

## Limits / follow-ups

- **Flat folders only** — no subdirectories (path == filename == torrent
  name). Subdirectories are warned about and skipped.
- **~64 files per drive** by default (one session + listener per file →
  thread/port pressure). The hard cap is relay event size: a single index
  event carries one tag per file, and relays typically reject events past
  ~64 KB — `drive_index` refuses more than **2048 files** outright. Sharding
  the index (e.g. per subdirectory) is a compatible future upgrade.
- **Direct route needs `--external-ip`.** A direct-route publisher without
  `--external-ip <ip>` seeds without publishing a dialable kind-30078
  announce, and carl rejects loopback/private IPv4 announces by design — so
  pass a routable address or use `--route i2p`.
- **NIP-42 relay auth is not honored** by carl's relay client (AUTH
  challenges are ignored) — private drives need a network-private relay for
  now.
- **No encryption** — paths, sizes, and contents are cleartext to anyone who
  can read the relay.
- **NIP-09 deletions (kind 5) are not used** — "delete" is the path
  disappearing from the replaceable index, not a deletion event.
- **Renames re-download** — the torrent name is bound to the infohash, so a
  publisher-side rename produces a NEW infohash and surfaces to subscribers
  as remove+add (the in-place rename path in the diff exists for future
  multi-file layouts).
- **NIP-35 search invisibility** — drive files are not published as
  kind-2003 torrent events, so they don't appear in `carl search`; discovery
  is by npub + drive name only.
