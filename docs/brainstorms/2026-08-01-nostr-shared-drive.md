# Clarified Problem Statement — Nostr Shared Drive

**Goal:** A carl "drive" — a local directory synced Google-Drive-macOS-app-style across devices and people: the owner drops/edits files in the folder, carl publishes signed index updates to a Nostr relay, and anyone with access to that relay auto-downloads and stays in sync.

**Constraints:**
- Mutable: editing a file must propagate a new version to subscribers (torrents are immutable → mutability lives in a Nostr index layer, NIP-33 parameterized-replaceable events).
- Access control is relay-scoped: public drive = public relay; private drive = access-restricted relay (NIP-42 auth or private relay). No per-recipient encryption in v1.
- Multi-writer: multiple npubs can publish into the same drive; coexistence modeled on kind-30078 semantics (per-author, per-path replaceable events — last-writer-wins per (author, path)).
- Reuse existing engine: download/seed lifecycle and restart-safety come from `follow.zig`'s Mirror; transport is standard carl sessions (direct/i2p routes as follow supports).
- Ships as CLI first, with daemon API + desktop GUI tab in the same release.

**Non-goals:**
- Per-recipient encrypted sharing (NIP-44/NIP-17 private drops) — later layer.
- Conflict-free merging (CRDTs), two-way sync of deletions with tombstone UX polish.
- Browsable public catalog ("paste npub, pick files") — that's a separate, smaller feature.
- Relay implementation itself — carl consumes relays, doesn't ship one.

**Success criteria:**
- `carl drive create <dir>` starts seeding the folder and publishing index events; `carl drive subscribe <drive-addr>` mirrors it into a local folder.
- Edit a file on machine A → machine B's mirror converges to the new version without manual intervention.
- Same flow works private by pointing both sides at an access-restricted relay.
- Restart A or B → both resume from checkpoints (existing `.follow.torrent`-style pattern).
- Desktop app: drive tab shows folders, members, per-file sync state.

## Approaches Considered

### Approach A: Mutable index event per drive (recommended)
- Sketch: one NIP-33 parameterized-replaceable event per drive (the "index": path → infohash, size, version/created_at, author). A folder watcher re-torrents changed files and republishes the index; subscribers diff against their local state and fetch new infohashes via the follow/Mirror engine. Multi-writer = merge per-author indexes, last-writer-wins per path.
- Affected: new `src/drive.zig` (watcher, index build/parse/merge), reuse `follow.zig` Mirror + `nip35.zig` event plumbing, `nostr_config.zig` (per-drive relay sets), `api.zig` + daemon (drive lifecycle), `main.zig` (CLI verbs), `desktop/` new tab.
- Tradeoffs: simple mental model (one event = whole drive state), easy diffing; but index event grows with file count (relay event-size limits ~64KB typical → cap ~a few thousand files per drive, shard later if needed).
- Effort: M/L.

### Approach B: Per-file addressable events (no index)
- Sketch: one NIP-33 event per (author, file path) — each file is its own replaceable event carrying its latest infohash. No central index; subscribers REQ all events tagged with the drive id.
- Affected: same modules, simpler publisher (no index rebuild), heavier subscriber (N events, per-file merge logic).
- Tradeoffs: scales to huge folders, natural per-file LWW; but no atomic drive snapshot, deletion signaling is awkward (NIP-09 per file), and relaysREQ fan-out is noisier. More protocol surface for the same UX.
- Effort: M.

### Approach C: Versioned log (append-only event chain)
- Sketch: every change is an immutable event (git-log-style); subscribers replay the log to reconstruct state.
- Tradeoffs: full history/audit trail; but unbounded growth, replay cost, and relays aren't great log stores — overkill for "keep my folder in sync."
- Effort: L.

## Recommendation

**Approach A** — a single replaceable index event per drive gives an atomic, diffable snapshot, maps cleanly onto the existing follow/Mirror machinery, and keeps deletion trivial (path disappears from index). Sharding into per-subdirectory indexes is a compatible future upgrade if event-size limits bite.

## Open questions (defer, not blocking v1)
- Event kind: new custom kind (e.g. 30035-range, NIP-33 addressable) vs. overloading NIP-35 — propose a new kind, document it like kind 30078.
- Multi-writer identity: does a "drive" have its own keypair shared among members, or per-member indexes merged client-side? (Per-member is trust-simpler; shared key is UX-simpler.)
- Private relay story: recommend NIP-42 auth relays; document a known-good setup.
- Sub-second watcher coalescing / debounce policy for large file writes.
- GUI fidelity: needs a `design/` prototype pass before the desktop tab is implemented (per project UI rule).
