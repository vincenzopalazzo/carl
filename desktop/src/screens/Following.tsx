// Following: mirror everything a Nostr publisher announces (NIP-35).
//
// Each followed npub gets a publisher card: the identity + route up top, then
// one row per mirrored torrent with its live phase (downloading → seeding).
// The daemon runs one mirror worker per follow (see src/follow.zig); this
// screen is a thin view over `state.follows` pushed on the WebSocket tick.

import { useState } from "react";
import { Icon } from "../components/icons";
import {
  RouteBadge,
  StatusPill,
  ProgressBar,
  CopyField,
} from "../components/atoms";
import { fmtSpeed, trunc } from "../components/format";
import { useCarl } from "../api/store";
import type { Follow, FollowTorrent, Route, Status } from "../api/types";

/** Map a mirror phase onto the shared status-pill vocabulary. */
function pillStatus(state: FollowTorrent["state"]): Status {
  switch (state) {
    case "seeding":
      return "seeding";
    case "downloading":
      return "downloading";
    case "failed":
      return "stalled";
    default:
      return "connecting";
  }
}

function TorrentRow({ t }: { t: FollowTorrent }) {
  const status = pillStatus(t.state);
  return (
    <div className="fol-trow">
      <div className="fol-trow-main">
        <span className="seed-name mono">{t.name || trunc(t.hash, 10)}</span>
        <StatusPill status={status} />
      </div>
      {t.state === "downloading" && (
        <div className="fol-trow-bar">
          <ProgressBar pct={t.pct} status={status} />
          <span className="mono dim" style={{ fontSize: 11 }}>
            {t.pct}%
          </span>
        </div>
      )}
      <div className="trow-stat">
        <span className="ts-val mono">{t.peers}</span>
        <span className="ts-lbl">peers</span>
      </div>
      <div className="trow-stat">
        <span className="ts-val mono dl">{fmtSpeed(t.down)}</span>
        <span className="ts-lbl">down</span>
      </div>
      <div className="trow-stat">
        <span className="ts-val mono ul">{fmtSpeed(t.up)}</span>
        <span className="ts-lbl">up</span>
      </div>
    </div>
  );
}

function FollowCard({ f }: { f: Follow }) {
  const { removeFollow } = useCarl();
  const [busy, setBusy] = useState(false);

  async function unfollow() {
    setBusy(true);
    try {
      await removeFollow(f.id);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="fol-card">
      <div className="fol-head">
        <span className="fol-ic">
          <Icon name="pulse" size={16} />
        </span>
        <div className="fol-id">
          <CopyField value={f.npub} />
          <span className="fol-sub dim">
            mirroring into <span className="mono">{f.dir}</span>
          </span>
        </div>
        <RouteBadge route={f.route} size="sm" />
        <div className="fol-counts mono">
          <span className="ul">{f.seeding} seeding</span>
          {f.downloading > 0 && <span className="dl">{f.downloading} downloading</span>}
          {f.failed > 0 && <span className="fol-failed">{f.failed} failed</span>}
        </div>
        <button
          className="icon-btn"
          title="Unfollow (mirrored files stay on disk)"
          disabled={busy}
          onClick={unfollow}
        >
          <Icon name="trash" size={15} />
        </button>
      </div>
      {f.torrents.length === 0 ? (
        <div className="fol-empty dim">
          Watching relays — nothing published by this key yet.
        </div>
      ) : (
        <div className="fol-trows">
          {f.torrents.map((t) => (
            <TorrentRow key={t.hash} t={t} />
          ))}
        </div>
      )}
    </div>
  );
}

const ROUTE_LABEL: Partial<Record<Route, string>> = {
  direct: "Direct",
  i2p: "I2P",
};
const ROUTE_DESC: Partial<Record<Route, string>> = {
  direct:
    "Download and reseed over the clearnet. Fast; your IP is visible to peers.",
  i2p: "Download AND reseed over I2P. Each mirrored torrent gets a stable .b32.i2p address; no clearnet IP exposed.",
};

function FollowModal({ onClose }: { onClose: () => void }) {
  const { state, addFollow } = useCarl();
  const [pubkey, setPubkey] = useState("");
  const [route, setRoute] = useState<Route>(
    state.settings.route === "i2p" ? "i2p" : "direct",
  );
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const valid =
    pubkey.trim().startsWith("npub1") || /^[0-9a-fA-F]{64}$/.test(pubkey.trim());

  async function submit() {
    if (!valid) return;
    setBusy(true);
    setErr(null);
    try {
      await addFollow(pubkey.trim(), route);
      onClose();
    } catch (e) {
      setErr(String(e));
      setBusy(false);
    }
  }

  return (
    <div className="modal-scrim" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-head">
          <h2 className="modal-title">Follow a publisher</h2>
          <button className="icon-btn" onClick={onClose}>
            <Icon name="close" size={16} />
          </button>
        </div>

        <div className="modal-body">
          <div className="field">
            <div className="field-label">
              Publisher key
              <span className="fl-hint">npub1… or 64-char hex</span>
            </div>
            <input
              className="text-input add-input mono"
              placeholder="npub1…"
              value={pubkey}
              autoFocus
              onChange={(e) => setPubkey(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") submit();
              }}
            />
            <div className="field-hint">
              carl watches this key's NIP-35 torrent events on your relays,
              downloads everything it publishes, and keeps reseeding it —
              announcing your mirror under your own identity so others can
              fetch from it too.
            </div>
          </div>

          <div className="field-label">Mirror route</div>
          <div className="vis-options">
            {(["direct", "i2p"] as const).map((id) => (
              <button
                key={id}
                className={"vis-opt" + (route === id ? " active" : "")}
                onClick={() => setRoute(id)}
              >
                <div className="vis-opt-top">
                  <RouteBadge route={id} size="sm" />
                  {route === id && (
                    <span className="vis-check">
                      <Icon name="check" size={13} stroke={2.4} />
                    </span>
                  )}
                </div>
                <div className="vis-opt-name">{ROUTE_LABEL[id]}</div>
                <div className="vis-opt-desc">{ROUTE_DESC[id]}</div>
              </button>
            ))}
          </div>

          {err && (
            <div className="callout-note" style={{ color: "var(--danger)" }}>
              <Icon name="close" size={15} stroke={1.8} />
              <span>{err}</span>
            </div>
          )}
        </div>

        <div className="modal-foot">
          <span className="field-hint">
            Mirrors restart with the daemon and resume from disk.
          </span>
          <div className="modal-foot-actions">
            <button className="btn" onClick={onClose}>
              Cancel
            </button>
            <button
              className={"btn btn-primary" + (valid && !busy ? "" : " disabled")}
              disabled={!valid || busy}
              onClick={submit}
            >
              <Icon name="plus" size={14} stroke={2.2} />
              {busy ? "Starting…" : "Follow"}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

export function FollowingScreen() {
  const { state } = useCarl();
  const follows = state.follows ?? [];
  const [showAdd, setShowAdd] = useState(false);
  const mirrored = follows.reduce((a, f) => a + f.seeding, 0);
  const pulling = follows.reduce((a, f) => a + f.downloading, 0);

  return (
    <div className="screen">
      <div className="topbar">
        <div className="topbar-l">
          <h1 className="screen-title">Following</h1>
          <div className="rate-readout">
            <span className="dim" style={{ fontSize: 12 }}>
              {follows.length} publisher{follows.length === 1 ? "" : "s"} ·{" "}
              <span className="ul">{mirrored} mirrored</span>
              {pulling > 0 && (
                <>
                  {" "}
                  · <span className="dl">{pulling} downloading</span>
                </>
              )}
            </span>
          </div>
        </div>
        <div className="topbar-r">
          <button className="btn btn-primary" onClick={() => setShowAdd(true)}>
            <Icon name="plus" size={15} stroke={2} /> Follow publisher
          </button>
        </div>
      </div>

      <div className="content">
        {follows.length === 0 ? (
          <div className="empty">
            <div className="empty-glyph">
              <Icon name="pulse" size={26} />
            </div>
            <div className="empty-title">Not following anyone yet</div>
            <div className="empty-sub">
              Follow a publisher's npub and carl becomes their mirror: every
              torrent they announce over Nostr is downloaded and reseeded from
              here — over I2P if you want the mirror itself to stay anonymous.
              Their files outlive their laptop.
            </div>
            <button
              className="btn btn-primary"
              style={{ marginTop: 10 }}
              onClick={() => setShowAdd(true)}
            >
              <Icon name="plus" size={15} stroke={2} /> Follow a publisher
            </button>
          </div>
        ) : (
          <div className="fol-list">
            {follows.map((f) => (
              <FollowCard key={f.id} f={f} />
            ))}
          </div>
        )}
      </div>

      {showAdd && <FollowModal onClose={() => setShowAdd(false)} />}
    </div>
  );
}
