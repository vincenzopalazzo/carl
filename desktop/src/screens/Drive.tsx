// Drive: local folders synced Google-Drive-style over Nostr (kind-30035 index).
//
// A publisher watches a folder, seeds every file in it, and posts a signed
// index to relays; subscribers mirror the index and converge on edits. The
// daemon pushes drives in the 1s WS full-state under `drives` (same shape as
// GET /api/drives); this screen is a thin view over that push, with a one-shot
// GET fallback for daemons that predate the WS key — mirroring how
// Following.tsx consumes `follows`.
//
// Drive/REST contract (docs/daemon-api.md):
//   Drive = { id, role: "publisher"|"subscriber", name, dir,
//             route: "direct"|"i2p", author: string|null, also: string[],
//             files: [{ path, size, phase, info_hash }], file_count }
//   POST /api/drives  { role, dir, name, author?, also?, route? } -> { id }
//   DELETE /api/drives/<id>
//
// NOTE: AppState in api/types.ts doesn't declare `drives` yet (the daemon
// contract landed first), so the key is read via a narrow local type and the
// REST calls go through a tiny fetch helper built on the shared resolveConfig
// — the store/client wrappers can absorb these once `drives` is typed there.

import { useEffect, useState } from "react";
import { Icon } from "../components/icons";
import {
  RouteBadge,
  StatusPill,
  CopyField,
} from "../components/atoms";
import { fmtBytes, trunc } from "../components/format";
import { useCarl } from "../api/store";
import { resolveConfig, type DaemonConfig } from "../api/client";
import type { AppState, Status } from "../api/types";

export type DriveRole = "publisher" | "subscriber";
export type DriveRoute = "direct" | "i2p";
export type DrivePhase = "starting" | "downloading" | "seeding" | "failed";

export interface DriveFile {
  path: string;
  size: number;
  phase: DrivePhase;
  info_hash: string;
}

export interface Drive {
  id: string;
  role: DriveRole;
  name: string;
  dir: string;
  route: DriveRoute;
  author: string | null;
  also: string[];
  files: DriveFile[];
  file_count: number;
}

interface NewDriveRequest {
  role: DriveRole;
  dir: string;
  name: string;
  author?: string;
  also?: string[];
  route?: DriveRoute;
}

/** state.drives, before AppState declares it. */
function wsDrives(state: AppState): Drive[] | undefined {
  return (state as AppState & { drives?: Drive[] }).drives;
}

// ---------- minimal REST helper (until DaemonClient grows drive methods) ----------

let cfgPromise: Promise<DaemonConfig> | null = null;
function daemonCfg(): Promise<DaemonConfig> {
  return (cfgPromise ??= resolveConfig());
}

async function driveApi<T>(path: string, init: RequestInit = {}): Promise<T> {
  const cfg = await daemonCfg();
  const res = await fetch(`${cfg.base}${path}`, {
    ...init,
    headers: {
      "X-Carl-Token": cfg.token,
      "Content-Type": "application/json",
      ...(init.headers ?? {}),
    },
  });
  if (!res.ok) {
    let detail = "";
    try {
      const body = (await res.json()) as { error?: unknown };
      if (body && typeof body.error === "string") detail = `: ${body.error}`;
    } catch {
      /* non-JSON error body */
    }
    throw new Error(`${res.status} ${res.statusText}${detail}`);
  }
  return (await res.json().catch(() => null)) as T;
}

/** Map a drive file phase onto the shared status-pill vocabulary — same
 *  mapping Following uses for mirror phases. */
function pillStatus(phase: DrivePhase): Status {
  switch (phase) {
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

/** Role reuses the status-pill treatment (no new color): a publisher seeds
 *  its folder, a subscriber pulls it — st-seed/st-down are already that
 *  language. (Not the StatusPill component: the label is the role itself.) */
function RolePill({ role }: { role: DriveRole }) {
  return (
    <span className={"status-pill " + (role === "publisher" ? "st-seed" : "st-down")}>
      <span className="sp-dot" />
      {role}
    </span>
  );
}

function DriveFiles({ files }: { files: DriveFile[] }) {
  return (
    <table className="files-table" style={{ marginTop: 15 }}>
      <thead>
        <tr>
          <th>File</th>
          <th className="num">Size</th>
          <th>Phase</th>
          <th className="num">Info-hash</th>
        </tr>
      </thead>
      <tbody>
        {files.map((f) => (
          <tr key={f.path}>
            <td className="file-name">
              <Icon name="file" size={14} style={{ color: "var(--fg-faint)" }} />
              <span className="mono">{f.path}</span>
            </td>
            <td className="num mono">{fmtBytes(f.size)}</td>
            <td>
              <StatusPill status={pillStatus(f.phase)} />
            </td>
            <td className="num mono dim">{trunc(f.info_hash, 8)}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function DriveCard({
  d,
  onRemoved,
}: {
  d: Drive;
  onRemoved: () => void;
}) {
  const [busy, setBusy] = useState(false);
  const total = d.files.reduce((a, f) => a + f.size, 0);

  async function remove() {
    if (
      !window.confirm(
        `Remove drive "${d.name}"? Synced files stay on disk; carl stops ${
          d.role === "publisher" ? "seeding and publishing the index" : "mirroring"
        }.`,
      )
    )
      return;
    setBusy(true);
    try {
      await driveApi(`/api/drives/${d.id}`, { method: "DELETE" });
      onRemoved();
    } catch (e) {
      window.alert(String(e));
      setBusy(false);
    }
  }

  return (
    <div className="dcard">
      <div className="dcard-head">
        <div className="dcard-title-wrap">
          <h3 className="dcard-title">{d.name}</h3>
          <div className="dcard-sig">
            <RolePill role={d.role} />
            <RouteBadge route={d.route} size="sm" />
            {d.role === "subscriber" && d.author && (
              <span className="dcard-author mono">{trunc(d.author, 10)}</span>
            )}
            {d.also.length > 0 && (
              <span className="dcard-age">
                +{d.also.length} writer{d.also.length === 1 ? "" : "s"}
              </span>
            )}
          </div>
        </div>
        <button
          className="icon-btn"
          title="Remove drive (files stay on disk)"
          disabled={busy}
          onClick={remove}
        >
          <Icon name="close" size={15} />
        </button>
      </div>

      <div className="dcard-meta">
        <div className="dm-item">
          <span className="dm-val mono">{d.file_count}</span>
          <span className="dm-lbl">files</span>
        </div>
        <div className="dm-item">
          <span className="dm-val mono">{fmtBytes(total)}</span>
          <span className="dm-lbl">size</span>
        </div>
        <div className="dm-item">
          <span className="dm-val mono" style={{ fontSize: 12 }}>
            {d.dir}
          </span>
          <span className="dm-lbl">folder</span>
        </div>
        {d.role === "subscriber" && d.author && (
          <div className="dm-item dm-hash">
            <CopyField value={d.author} label={"author " + trunc(d.author, 7)} />
          </div>
        )}
      </div>

      {d.files.length === 0 ? (
        <div className="dcard-desc">
          Watching the folder — publish or wait for the author's next index.
        </div>
      ) : (
        <DriveFiles files={d.files} />
      )}
    </div>
  );
}

const ROUTE_DESC: Record<DriveRoute, string> = {
  direct: "Peers see your IP. Fastest sync.",
  i2p: "Synced over I2P · no clearnet IP exposed.",
};

function NewDriveModal({
  onClose,
  onCreated,
}: {
  onClose: () => void;
  onCreated: () => void;
}) {
  const [role, setRole] = useState<DriveRole>("publisher");
  const [dir, setDir] = useState("");
  const [name, setName] = useState("");
  const [author, setAuthor] = useState("");
  const [also, setAlso] = useState("");
  const [route, setRoute] = useState<DriveRoute>("i2p");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const authorValid =
    author.trim().startsWith("npub1") || /^[0-9a-fA-F]{64}$/.test(author.trim());
  const canCreate =
    !!name.trim() && (role === "publisher" ? !!dir.trim() : authorValid);

  /** Native folder picker under Tauri; no-op elsewhere (field stays typed). */
  async function browse() {
    setErr(null);
    try {
      const { open } = await import("@tauri-apps/plugin-dialog");
      const sel = await open({
        directory: true,
        multiple: false,
        title: "Choose a folder",
      });
      if (typeof sel === "string") setDir(sel);
    } catch (e) {
      setErr(String(e));
    }
  }

  async function submit() {
    if (!canCreate || busy) return;
    setBusy(true);
    setErr(null);
    try {
      const body: NewDriveRequest = { role, dir: dir.trim(), name: name.trim(), route };
      if (role === "subscriber") {
        body.author = author.trim();
        const extra = also
          .split(",")
          .map((s) => s.trim())
          .filter(Boolean);
        if (extra.length > 0) body.also = extra;
        if (!body.dir) delete (body as Partial<NewDriveRequest>).dir;
      }
      await driveApi<{ id: string }>("/api/drives", {
        method: "POST",
        body: JSON.stringify(body),
      });
      onCreated();
      onClose();
    } catch (e) {
      setErr(String(e));
      setBusy(false);
    }
  }

  return (
    <div className="modal-scrim" onClick={onClose}>
      <div className="modal add-modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-head">
          <h2 className="modal-title">New drive</h2>
          <button className="icon-btn" onClick={onClose}>
            <Icon name="close" size={16} />
          </button>
        </div>

        <div className="modal-body">
          <div className="add-tabs">
            {(
              [
                ["publisher", "Publish a folder"],
                ["subscriber", "Subscribe"],
              ] as [DriveRole, string][]
            ).map(([id, l]) => (
              <button
                key={id}
                className={"add-tab" + (role === id ? " active" : "")}
                onClick={() => setRole(id)}
              >
                {l}
              </button>
            ))}
          </div>

          {role === "publisher" ? (
            <>
              <div className="field">
                <div className="field-label">
                  Folder <span className="fl-hint">watched &amp; seeded</span>
                </div>
                <div style={{ display: "flex", gap: 8 }}>
                  <input
                    className="text-input mono add-input"
                    style={{ flex: 1 }}
                    autoFocus
                    value={dir}
                    onChange={(e) => setDir(e.target.value)}
                    placeholder="~/Music/mixtapes"
                  />
                  <button className="btn" onClick={browse}>
                    <Icon name="folder" size={14} /> Browse
                  </button>
                </div>
                <span className="field-hint">
                  carl hashes every file in this folder and keeps seeding it.
                  Edits are re-published as a new signed index.
                </span>
              </div>
              <div className="field">
                <div className="field-label">Drive name</div>
                <input
                  className="text-input add-input"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  placeholder="mixtapes"
                />
              </div>
            </>
          ) : (
            <>
              <div className="field">
                <div className="field-label">
                  Author <span className="fl-hint">npub1… or 64-char hex</span>
                </div>
                <input
                  className="text-input mono add-input"
                  autoFocus
                  value={author}
                  onChange={(e) => setAuthor(e.target.value)}
                  placeholder="npub1…"
                />
                <span className="field-hint">
                  The key that signs this drive's index on your relays. carl
                  mirrors everything it publishes and converges on edits.
                </span>
              </div>
              <div className="field">
                <div className="field-label">Drive name</div>
                <input
                  className="text-input add-input"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  placeholder="fieldnotes"
                />
              </div>
              <div className="field">
                <div className="field-label">
                  Extra writers{" "}
                  <span className="fl-hint">optional · comma-separated</span>
                </div>
                <input
                  className="text-input mono add-input"
                  value={also}
                  onChange={(e) => setAlso(e.target.value)}
                  placeholder="npub1…, npub1…"
                />
                <span className="field-hint">
                  Additional keys allowed to write to this drive (multi-writer
                  merge; the author wins conflicts).
                </span>
              </div>
              <div className="field">
                <div className="field-label">
                  Mirror into <span className="fl-hint">optional</span>
                </div>
                <div style={{ display: "flex", gap: 8 }}>
                  <input
                    className="text-input mono add-input"
                    style={{ flex: 1 }}
                    value={dir}
                    onChange={(e) => setDir(e.target.value)}
                    placeholder="default: ~/carl/drive-<pubkey>-<name>"
                  />
                  <button className="btn" onClick={browse}>
                    <Icon name="folder" size={14} /> Browse
                  </button>
                </div>
              </div>
            </>
          )}

          <div className="field">
            <label className="field-label">Route</label>
            <div className="route-select route-select-lg">
              {(
                [
                  ["direct", "Direct"],
                  ["i2p", "I2P"],
                ] as [DriveRoute, string][]
              ).map(([id, l]) => (
                <button
                  key={id}
                  className={"rsl-btn" + (route === id ? " active rt-" + id : "")}
                  onClick={() => setRoute(id)}
                >
                  {id === "i2p" ? (
                    <Icon name="shield" size={12} />
                  ) : (
                    <Icon name="globe" size={12} />
                  )}
                  {l}
                </button>
              ))}
            </div>
            <span className="field-hint">{ROUTE_DESC[route]}</span>
          </div>

          {err && (
            <div className="callout-note" style={{ color: "var(--danger)" }}>
              <Icon name="close" size={15} stroke={1.8} />
              <span>{err}</span>
            </div>
          )}
        </div>

        <div className="modal-foot">
          <div className="modal-foot-route">
            <RouteBadge route={route} size="sm" />
          </div>
          <div className="modal-foot-actions">
            <button className="btn" onClick={onClose}>
              Cancel
            </button>
            <button
              className={"btn btn-primary" + (canCreate && !busy ? "" : " disabled")}
              disabled={!canCreate || busy}
              onClick={submit}
            >
              <Icon name="plus" size={14} stroke={2.2} />
              {busy
                ? "Starting…"
                : role === "publisher"
                  ? "Publish drive"
                  : "Subscribe"}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

export function DriveScreen() {
  const { state, refresh } = useCarl();
  const [showNew, setShowNew] = useState(false);

  // Live drives from the WS full-state push. On daemons that predate the
  // `drives` key, fall back to a one-shot GET /api/drives (the established
  // initial-load pattern is snapshot-then-WS; this covers the gap).
  const fromWs = wsDrives(state);
  const [httpDrives, setHttpDrives] = useState<Drive[] | null>(null);
  useEffect(() => {
    if (fromWs !== undefined) return;
    let dead = false;
    driveApi<{ drives: Drive[] }>("/api/drives")
      .then((d) => {
        if (!dead && d && Array.isArray(d.drives)) setHttpDrives(d.drives);
      })
      .catch(() => {});
    return () => {
      dead = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [fromWs === undefined]);
  const drives = fromWs ?? httpDrives ?? [];

  /** Re-pull after a mutation: refresh the snapshot (WS path) and the GET
   *  fallback when that's what's feeding the screen. */
  async function reload() {
    if (fromWs === undefined) {
      try {
        const d = await driveApi<{ drives: Drive[] }>("/api/drives");
        if (d && Array.isArray(d.drives)) setHttpDrives(d.drives);
      } catch {
        /* daemon unreachable — list stays as-is */
      }
    }
    await refresh();
  }

  const totalBytes = drives.reduce(
    (a, d) => a + d.files.reduce((x, f) => x + f.size, 0),
    0,
  );

  return (
    <div className="screen">
      <div className="topbar">
        <div className="topbar-l">
          <h1 className="screen-title">Drive</h1>
          <div className="rate-readout">
            <span className="dim" style={{ fontSize: 12 }}>
              {drives.length} drive{drives.length === 1 ? "" : "s"} ·{" "}
              <span className="mono">{fmtBytes(totalBytes)}</span> synced
            </span>
          </div>
        </div>
        <div className="topbar-r">
          <button className="btn btn-primary" onClick={() => setShowNew(true)}>
            <Icon name="plus" size={15} stroke={2} /> New drive
          </button>
        </div>
      </div>

      <div className="content">
        {drives.length === 0 ? (
          <div className="empty">
            <div className="empty-glyph">
              <Icon name="folder" size={26} />
            </div>
            <div className="empty-title">No drives yet</div>
            <div className="empty-sub">
              Publish a folder or subscribe to someone's npub — carl keeps both
              sides in sync over Nostr, Google-Drive-style, with no server in
              the middle.
            </div>
            <button
              className="btn btn-primary"
              style={{ marginTop: 10 }}
              onClick={() => setShowNew(true)}
            >
              <Icon name="plus" size={15} stroke={2} /> New drive
            </button>
          </div>
        ) : (
          <div className="dcard-list">
            {drives.map((d) => (
              <DriveCard key={d.id} d={d} onRemoved={reload} />
            ))}
          </div>
        )}
      </div>

      {showNew && (
        <NewDriveModal onClose={() => setShowNew(false)} onCreated={reload} />
      )}
    </div>
  );
}
