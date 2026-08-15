// Drive — local folders synced Google-Drive-style over Nostr (kind-30035 index).
//
// 1:1 rebuild from design/Carl-App-redesign.dc.html (Drive cards mode +
// directory/breadcrumb view + New-drive modal). A publisher watches a folder,
// seeds every file, and posts a signed index to relays; subscribers mirror it.
// The daemon pushes drives in the 1s WS full-state under `drives`
// (state.drives), consumed the same way Following consumes `follows`.
//
// Drive/REST contract (docs/daemon-api.md):
//   Drive = { id, role:"publisher"|"subscriber", name, dir,
//             route:"direct"|"i2p", author: string|null, also: string[],
//             files:[{path,size,phase,info_hash}], file_count, trash? }
//   POST   /api/drives      { role, dir, name, author?, also?, route? } -> { id }
//   DELETE /api/drives/<id>
//
// REST helper note: the DaemonClient (api/client.ts) attaches
// AbortSignal.timeout to every call; the driveApi helper below mirrors that so a
// hung daemon socket can't wedge this screen (the prior review flagged the
// missing timeout). The fetch helper can absorb these once DaemonClient grows
// drive methods.

import { useState, type CSSProperties } from "react";
import { Icon } from "../components/icons";
import { fmtBytes } from "../components/format";
import { useCarl } from "../api/store";
import { resolveConfig, type DaemonConfig } from "../api/client";
import type {
  Drive,
  DriveFile,
  DrivePhase,
  DriveRole,
  DriveRoute,
} from "../api/types";

/* ---------------------------------------------------------------------------
 * mimetype / folder icon helpers — ported verbatim from the design JS.
 * La Capitaine icon theme (keeferrourke/la-capitaine-icon-theme, CC-BY-SA 4.0),
 * served from desktop/public/icons. Vite exposes /public at the site root, so
 * the URLs are /icons/mimetypes/*.svg and /icons/places/*.svg (same convention
 * the app uses for /fonts/*).
 * ------------------------------------------------------------------------- */

const MIME_BASE = "/icons/mimetypes/";
const PLACE_BASE = "/icons/places/";

const EXT_ICON: Record<string, string> = {
  flac: "application-audio.svg", mp3: "application-audio.svg", m4a: "application-audio.svg",
  wav: "application-audio.svg", aiff: "application-audio.svg",
  pdf: "application-pdf.svg",
  png: "application-image-png.svg", jpg: "application-image-png.svg", jpeg: "application-image-png.svg",
  gif: "application-image-png.svg",
  tif: "application-image-tiff.svg", tiff: "application-image-tiff.svg",
  pack: "application-archive.svg", tar: "application-archive.svg", zip: "application-archive.svg",
  gz: "application-archive.svg", xz: "application-archive.svg", iso: "application-archive.svg",
  json: "application-json.svg",
  mp4: "application-video.svg", mov: "application-video.svg", mkv: "application-video.svg",
  txt: "application-text.svg", md: "application-text.svg", log: "application-text.svg",
};
const KIND_FOLDER: Record<string, string> = {
  audio: "folder-music.svg", image: "folder-pictures.svg", doc: "folder-documents.svg",
};

function extOf(p: string): string {
  const i = p.lastIndexOf(".");
  return i === -1 ? "" : p.slice(i + 1).toLowerCase();
}
function fileIcon(p: string): string {
  return MIME_BASE + (EXT_ICON[extOf(p)] || "application-text.svg");
}
function extKind(e: string): "audio" | "image" | "doc" | "other" {
  if (["flac", "mp3", "m4a", "wav", "aiff"].indexOf(e) > -1) return "audio";
  if (["png", "jpg", "jpeg", "gif", "tif", "tiff"].indexOf(e) > -1) return "image";
  if (["pdf", "txt", "md", "log"].indexOf(e) > -1) return "doc";
  return "other";
}
/** Folder icon chosen from the dominant non-"other" file kind inside the list. */
function folderIconFor(paths: string[]): string {
  const tally: Record<string, number> = {};
  paths.forEach((p) => {
    const k = extKind(extOf(p));
    tally[k] = (tally[k] || 0) + 1;
  });
  let best: string | null = null;
  let n = 0;
  Object.keys(tally).forEach((k) => {
    if (k !== "other" && tally[k] > n) {
      n = tally[k];
      best = k;
    }
  });
  return PLACE_BASE + (KIND_FOLDER[best || ""] || "folder.svg");
}

function MimeIcon({ path, size }: { path: string; size: number }) {
  return (
    <img
      src={fileIcon(path)}
      width={size}
      height={size}
      alt=""
      draggable={false}
      style={{ width: size, height: size, flex: "0 0 auto", display: "block" }}
    />
  );
}
function FolderKindIcon({ paths, size }: { paths: string[]; size: number }) {
  return (
    <img
      src={folderIconFor(paths)}
      width={size}
      height={size}
      alt=""
      draggable={false}
      style={{ width: size, height: size, flex: "0 0 auto", display: "block" }}
    />
  );
}

/* ---------------------------------------------------------------------------
 * inline glyph icons (paths not present in components/icons.tsx, kept local so
 * that shared icon module stays untouched): ext (open/external), play, pause,
 * up (directory ".."). Everything else reuses <Icon name=... />.
 * ------------------------------------------------------------------------- */
function Glyph({
  d,
  size = 16,
  stroke = 1.7,
  style,
}: {
  d: string;
  size?: number;
  stroke?: number;
  style?: CSSProperties;
}) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={stroke}
      strokeLinecap="round"
      strokeLinejoin="round"
      style={{ flex: "0 0 auto", display: "block", ...style }}
    >
      <path d={d} />
    </svg>
  );
}
const GLYPH = {
  ext: "M14 4h6v6M20 4l-9 9M18 14v5H5V6h5",
  play: "M7 4l12 8-12 8z",
  pause: "M9 5v14M15 5v14",
  up: "M12 19V5m0 0-6 6m6-6 6 6",
  back: "M15 6l-6 6 6 6",
};

/* ---------------------------------------------------------------------------
 * route / role / phase presentation (design tokens, reusing shared CSS classes
 * where they already match): rt-clearnet (amber) for a direct drive,
 * rt-proxy (blue) for an i2p drive — DRIVE_ROUTE = { direct:"direct",
 * i2p:"proxy" } from the design. The shared <RouteBadge> can't express this
 * (it labels i2p "i2p"), so drives own a local badge.
 * ------------------------------------------------------------------------- */
const DRIVE_ROUTE_DISPLAY: Record<DriveRoute, { cls: string; icon: string; label: string }> = {
  direct: { cls: "rt-clearnet", icon: "globe", label: "clearnet" },
  i2p: { cls: "rt-proxy", icon: "shield", label: "proxied" },
};
function DriveRouteBadge({ route }: { route: DriveRoute }) {
  const m = DRIVE_ROUTE_DISPLAY[route];
  return (
    <span className={"route-badge rb-sm " + m.cls} title={"Routed: " + m.label}>
      <Icon name={m.icon} size={11} stroke={1.7} />
      <span>{m.label}</span>
    </span>
  );
}

function DriveRolePill({ role }: { role: DriveRole }) {
  const pub = role === "publisher";
  return (
    <span className={"drv-role " + (pub ? "drv-role-pub" : "drv-role-sub")}>
      {role}
    </span>
  );
}

const PHASE_META: Record<DrivePhase, { label: string; cls: string }> = {
  seeding: { label: "seeding", cls: "st-seed" },
  downloading: { label: "downloading", cls: "st-down" },
  starting: { label: "starting", cls: "st-meta" },
  paused: { label: "paused", cls: "st-done" },
  failed: { label: "failed", cls: "st-stall" },
};
function DrivePhasePill({ phase }: { phase: DrivePhase }) {
  const m = PHASE_META[phase] ?? PHASE_META.starting;
  return (
    <span className={"status-pill " + m.cls}>
      <span className="sp-dot" />
      {m.label}
    </span>
  );
}

function shortHash(h: string): string {
  return h ? h.slice(0, 8) + "…" : "";
}
function authorShort(a: string): string {
  return a ? a.slice(0, 10) + "…" + a.slice(-4) : "";
}

/* ---------------------------------------------------------------------------
 * REST helper — same shape as DaemonClient.fetch (token header + JSON error
 * surfacing) but with the AbortSignal.timeout the prior review asked for. Lives
 * here until DaemonClient gains typed drive methods.
 * ------------------------------------------------------------------------- */
const DRIVE_TIMEOUT_MS = 8000;
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
    signal: init.signal ?? AbortSignal.timeout(DRIVE_TIMEOUT_MS),
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

interface NewDriveRequest {
  role: DriveRole;
  dir: string;
  name: string;
  author?: string;
  also?: string[];
  route?: DriveRoute;
  ip?: string;
}

const ROUTE_DESC: Record<DriveRoute, string> = {
  direct: "Peers see your IP. Fastest sync.",
  i2p: "Synced over I2P · no clearnet IP exposed.",
};

/* ===================== card (list mode) ===================== */

interface DriveCardProps {
  d: Drive;
  expanded: boolean;
  onToggleExpand: () => void;
  isPaused: boolean;
  onTogglePause: () => void;
  confirming: boolean;
  onAskRemove: () => void;
  onCancelRemove: () => void;
  onDoRemove: () => void;
  onOpenDir: () => void;
  onCopyAuthor: () => void;
  authorCopied: boolean;
}

function DriveCard({
  d,
  expanded,
  onToggleExpand,
  isPaused,
  onTogglePause,
  confirming,
  onAskRemove,
  onCancelRemove,
  onDoRemove,
  onOpenDir,
  onCopyAuthor,
  authorCopied,
}: DriveCardProps) {
  const pub = d.role === "publisher";
  const total = d.files.reduce((a, f) => a + f.size, 0);
  const shown = expanded ? d.files : d.files.slice(0, 3);
  const canToggle = d.files.length > 3;
  const trash = d.trash ?? 0;

  return (
    <div className={"drv-card" + (isPaused ? " paused" : "")}>
      <div className="drv-card-head">
        <div className="drv-card-main">
          <button className="drv-title" title="Open drive" onClick={onOpenDir}>
            <span>{d.name}</span>
            <Icon name="chevron" size={15} stroke={1.8} style={{ color: "var(--fg-faint)" }} />
          </button>
          <div className="drv-sig">
            <DriveRolePill role={d.role} />
            <DriveRouteBadge route={d.route} />
            {!pub && d.author && (
              <button className="drv-author" title={d.author} onClick={onCopyAuthor}>
                <span>
                  Mirroring <span className="mono">{authorShort(d.author)}</span>
                </span>
                <span className="drv-author-ic">
                  <Icon name={authorCopied ? "check" : "copy"} size={12} stroke={1.8} />
                </span>
              </button>
            )}
            {d.also.length > 0 && (
              <span className="drv-also" title={d.also.join("\n")}>
                +{d.also.length} writer{d.also.length === 1 ? "" : "s"}
              </span>
            )}
          </div>
        </div>

        <div className="drv-actions">
          {confirming ? (
            <div className="drv-confirm">
              <span>Remove? Files stay on disk.</span>
              <button className="drv-confirm-rm" onClick={onDoRemove}>
                Remove
              </button>
              <button className="drv-confirm-cancel" onClick={onCancelRemove}>
                Cancel
              </button>
            </div>
          ) : (
            <>
              <button className="drv-mini-btn" title="Open folder">
                <Glyph d={GLYPH.ext} size={13} /> Open folder
              </button>
              <button
                className="drv-mini-btn"
                title={isPaused ? "Resume" : "Pause"}
                onClick={onTogglePause}
              >
                <Glyph d={isPaused ? GLYPH.play : GLYPH.pause} size={13} />{" "}
                {isPaused ? "Resume" : "Pause"}
              </button>
              <button className="drv-trash-btn" title="Remove drive" onClick={onAskRemove}>
                <Icon name="trash" size={14} stroke={1.7} />
              </button>
            </>
          )}
        </div>
      </div>

      <div className="drv-stats">
        <div className="drv-stat">
          <span className="drv-stat-val mono">{d.file_count}</span>
          <span className="drv-stat-lbl">files</span>
        </div>
        <div className="drv-stat">
          <span className="drv-stat-val mono">{fmtBytes(total)}</span>
          <span className="drv-stat-lbl">size</span>
        </div>
        <div className="drv-stat" style={{ minWidth: 0 }}>
          <span className="drv-stat-folder mono">{d.dir}</span>
          <span className="drv-stat-lbl">folder</span>
        </div>
      </div>

      <table className="files-table">
        <thead>
          <tr>
            <th>File</th>
            <th className="num">Size</th>
            <th>Phase</th>
            <th className="num">Info-hash</th>
          </tr>
        </thead>
        <tbody>
          {shown.map((f: DriveFile) => (
            <tr key={f.path}>
              <td>
                <span className="drv-file-cell">
                  <MimeIcon path={f.path} size={17} />
                  <span>{f.path}</span>
                </span>
              </td>
              <td className="num mono">{fmtBytes(f.size)}</td>
              <td>
                <DrivePhasePill phase={f.phase} />
              </td>
              <td className="num mono drv-hash" title={f.info_hash}>
                {shortHash(f.info_hash)}
              </td>
            </tr>
          ))}
        </tbody>
      </table>

      <div className="drv-foot">
        {canToggle && (
          <button className="link-btn" onClick={onToggleExpand}>
            {expanded ? "show less" : `show all ${d.files.length} files`}
          </button>
        )}
        {trash > 0 && (
          <span className="drv-trash-note">
            <span className="drv-trash-dot" />
            {trash} file{trash === 1 ? "" : "s"} moved to .trash
            <button className="link-btn" onClick={(e) => e.preventDefault()}>
              View trash
            </button>
          </span>
        )}
      </div>
    </div>
  );
}

/* ===================== directory / breadcrumb view ===================== */

interface DriveDetailProps {
  d: Drive;
  cwd: string;
  setCwd: (c: string) => void;
  onClose: () => void;
  isPaused: boolean;
  onTogglePause: () => void;
}

function DriveDetail({ d, cwd, setCwd, onClose, isPaused, onTogglePause }: DriveDetailProps) {
  const prefix = cwd ? cwd + "/" : "";
  const folderMap = new Map<string, { name: string; count: number; size: number; paths: string[] }>();
  const fileList: { f: DriveFile; name: string }[] = [];
  d.files.forEach((f) => {
    if (!f.path.startsWith(prefix)) return;
    const rest = f.path.slice(prefix.length);
    const slash = rest.indexOf("/");
    if (slash === -1) {
      fileList.push({ f, name: rest });
      return;
    }
    const nm = rest.slice(0, slash);
    const e = folderMap.get(nm) || { name: nm, count: 0, size: 0, paths: [] };
    e.count += 1;
    e.size += f.size;
    e.paths.push(f.path);
    folderMap.set(nm, e);
  });
  const parts = cwd ? cwd.split("/") : [];
  const folders = Array.from(folderMap.values()).sort((a, b) => a.name.localeCompare(b.name));
  const files = fileList.sort((a, b) => a.name.localeCompare(b.name));
  const isEmpty = folderMap.size === 0 && fileList.length === 0;
  const summary =
    (folderMap.size
      ? folderMap.size + " folder" + (folderMap.size === 1 ? "" : "s") + " · "
      : "") +
    fileList.length +
    " file" +
    (fileList.length === 1 ? "" : "s");

  return (
    <div className="drv-dir">
      <div className="topbar">
        <div className="topbar-l">
          <button className="drv-back" title="Back to Drive" onClick={onClose}>
            <Glyph d={GLYPH.back} size={17} stroke={1.8} />
          </button>
          <h1 className="screen-title">{d.name}</h1>
          <DriveRolePill role={d.role} />
          <DriveRouteBadge route={d.route} />
        </div>
        <div className="topbar-r">
          <button className="drv-mini-btn" title="Open folder">
            <Glyph d={GLYPH.ext} size={13} /> Open folder
          </button>
          <button className="drv-mini-btn" onClick={onTogglePause}>
            <Glyph d={isPaused ? GLYPH.play : GLYPH.pause} size={13} />{" "}
            {isPaused ? "Resume" : "Pause"}
          </button>
        </div>
      </div>

      <div className="drv-crumbbar">
        <button className="drv-crumb-root" onClick={() => setCwd("")}>
          <FolderKindIcon paths={d.files.map((f) => f.path)} size={16} />
          <span className="mono">{d.name}</span>
        </button>
        {parts.map((p, i) => (
          <span key={i} className="drv-crumb">
            <span className="drv-crumb-sep">/</span>
            <button
              className={"drv-crumb-btn mono" + (i === parts.length - 1 ? " cur" : "")}
              onClick={() => setCwd(parts.slice(0, i + 1).join("/"))}
            >
              {p}
            </button>
          </span>
        ))}
        <span className="drv-crumb-summary">{summary}</span>
      </div>

      <div className="content">
        <div className="drv-dir-card">
          <table className="drv-dir-table">
            <thead>
              <tr>
                <th>Name</th>
                <th className="num">Size</th>
                <th>Phase</th>
                <th className="num">Info-hash</th>
              </tr>
            </thead>
            <tbody>
              {parts.length > 0 && (
                <tr className="drv-dir-row" onClick={() => setCwd(parts.slice(0, -1).join("/"))}>
                  <td colSpan={4}>
                    <span className="drv-dir-up">
                      <Glyph d={GLYPH.up} size={15} style={{ color: "var(--fg-faint)" }} />
                      <span className="mono">..</span>
                    </span>
                  </td>
                </tr>
              )}
              {folders.map((fd) => (
                <tr
                  key={fd.name}
                  className="drv-dir-row"
                  onClick={() => setCwd((cwd ? cwd + "/" : "") + fd.name)}
                >
                  <td>
                    <span className="drv-file-cell">
                      <FolderKindIcon paths={fd.paths} size={19} />
                      <span>{fd.name}</span>
                      <span className="drv-dir-count">
                        {fd.count} item{fd.count === 1 ? "" : "s"}
                      </span>
                    </span>
                  </td>
                  <td className="num mono dim">{fmtBytes(fd.size)}</td>
                  <td></td>
                  <td className="num drv-dir-chev">
                    <Icon name="chevron" size={14} style={{ color: "var(--fg-faint)" }} />
                  </td>
                </tr>
              ))}
              {files.map((it) => (
                <tr key={it.f.path} className="drv-dir-file">
                  <td>
                    <span className="drv-file-cell">
                      <MimeIcon path={it.f.path} size={19} />
                      <span>{it.name}</span>
                    </span>
                  </td>
                  <td className="num mono">{fmtBytes(it.f.size)}</td>
                  <td>
                    <DrivePhasePill phase={it.f.phase} />
                  </td>
                  <td className="num mono drv-hash" title={it.f.info_hash}>
                    {shortHash(it.f.info_hash)}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          {isEmpty && (
            <div className="drv-dir-empty">
              <div className="drv-dir-empty-glyph">
                <Icon name="folder" size={22} stroke={1.7} />
              </div>
              <div className="drv-dir-empty-title">This folder is empty</div>
              <div className="drv-dir-empty-sub">
                Waiting for the next signed index from the author.
              </div>
            </div>
          )}
        </div>

        <div className="drv-dir-path">
          <Icon name="folder" size={13} stroke={1.7} style={{ color: "var(--fg-faint)" }} />
          <span className="mono">
            {d.dir}
            {cwd ? "/" + cwd : ""}
          </span>
        </div>
      </div>
    </div>
  );
}

/* ===================== new-drive modal ===================== */

function NewDriveModal({
  initialRole,
  onClose,
  onCreated,
}: {
  initialRole: DriveRole;
  onClose: () => void;
  onCreated: () => void;
}) {
  const [role, setRole] = useState<DriveRole>(initialRole);
  const [dir, setDir] = useState("");
  const [name, setName] = useState("");
  const [author, setAuthor] = useState("");
  const [writers, setWriters] = useState<string[]>([""]);
  const [route, setRoute] = useState<DriveRoute>("i2p");
  const [ip, setIp] = useState("");
  const [advanced, setAdvanced] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const npubOk = /^npub1[023456789acdefghjklmnpqrstuvwxyz]{20,}$/.test(author.trim());
  const hexOk = /^[0-9a-fA-F]{64}$/.test(author.trim());
  const authorValid = npubOk || hexOk;
  const authorBad = author.trim().length > 0 && !authorValid;
  const pub = role === "publisher";
  const showIp = pub && route === "direct";
  const canCreate = pub
    ? !!(dir.trim() && name.trim() && (route !== "direct" || ip.trim()))
    : !!(authorValid && name.trim());

  const mirrorPlaceholder =
    "~/carl/drive-" +
    (npubOk ? author.trim().slice(5, 17) : "<npub12>") +
    "-" +
    (name.trim() || "<name>");

  async function browse() {
    try {
      const { open } = await import("@tauri-apps/plugin-dialog");
      const sel = await open({ directory: true, multiple: false, title: "Choose a folder" });
      if (typeof sel === "string") setDir(sel);
    } catch {
      /* not running under Tauri — field stays typed */
    }
  }

  async function submit() {
    if (!canCreate || busy) return;
    setBusy(true);
    setErr(null);
    try {
      const body: NewDriveRequest = { role, dir: dir.trim(), name: name.trim(), route };
      if (!pub) {
        body.author = author.trim();
        const extra = writers.map((w) => w.trim()).filter(Boolean);
        if (extra.length > 0) body.also = extra;
        if (!body.dir) delete (body as Partial<NewDriveRequest>).dir;
      }
      if (showIp && ip.trim()) body.ip = ip.trim();
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
      <div className="modal drv-modal" onClick={(e) => e.stopPropagation()}>
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

          {pub ? (
            <>
              <div className="field">
                <div className="field-label">
                  Folder to share <span className="fl-hint">watched &amp; seeded</span>
                </div>
                <div className="path-input">
                  <Icon name="folder" size={15} stroke={1.7} style={{ color: "var(--fg-faint)" }} />
                  <input
                    className="text-input mono"
                    autoFocus
                    value={dir}
                    onChange={(e) => setDir(e.target.value)}
                    placeholder="~/Music/mixtapes"
                  />
                  <button className="link-btn" onClick={browse}>
                    Browse…
                  </button>
                </div>
                <span className="field-hint">
                  carl hashes every file in this folder and keeps seeding it. Edits are
                  re-published as a new signed index.
                </span>
              </div>
              <div className="field">
                <div className="field-label">Drive name</div>
                <input
                  className="text-input mono"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  placeholder="my-drive"
                />
                <span className="field-hint">
                  Lowercase, no spaces — this becomes the share address.
                </span>
              </div>
            </>
          ) : (
            <>
              <div className="field">
                <div className="field-label">Author npub</div>
                <input
                  className={"text-input mono" + (authorBad ? " drv-input-bad" : "")}
                  autoFocus
                  value={author}
                  onChange={(e) => setAuthor(e.target.value)}
                  placeholder="npub1…"
                />
                {authorBad && (
                  <span className="drv-err">
                    Not a valid npub — must be bech32 and decode to 32 bytes.
                  </span>
                )}
                <span className="field-hint">
                  The key that signs this drive's index on your relays.
                </span>
              </div>
              <div className="field">
                <div className="field-label">Drive name</div>
                <input
                  className="text-input mono"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  placeholder="my-drive"
                />
              </div>
              <div className="field">
                <div className="field-label">
                  Mirror into <span className="fl-hint">optional</span>
                </div>
                <div className="path-input">
                  <Icon name="folder" size={15} stroke={1.7} style={{ color: "var(--fg-faint)" }} />
                  <input
                    className="text-input mono"
                    value={dir}
                    onChange={(e) => setDir(e.target.value)}
                    placeholder={mirrorPlaceholder}
                  />
                  <button className="link-btn" onClick={browse}>
                    Browse…
                  </button>
                </div>
              </div>
              <div className="drv-adv">
                <button
                  className="drv-adv-toggle"
                  onClick={() => setAdvanced(!advanced)}
                >
                  <Glyph d={advanced ? "M6 15l6-6 6 6" : "M6 9l6 6 6-6"} size={14} stroke={1.8} />
                  <span style={{ flex: 1 }}>Advanced · extra writers</span>
                </button>
                {advanced && (
                  <div className="drv-adv-body">
                    {writers.map((w, i) => (
                      <div key={i} className="drv-writer-row">
                        <input
                          className="drv-writer-input"
                          value={w}
                          onChange={(e) => {
                            const v = e.target.value;
                            setWriters((prev) => {
                              const n = prev.slice();
                              n[i] = v;
                              return n;
                            });
                          }}
                          placeholder="npub1…"
                        />
                        {writers.length > 1 && (
                          <button
                            className="drv-writer-rm"
                            title="Remove writer"
                            onClick={() =>
                              setWriters((prev) => prev.filter((_, j) => j !== i))
                            }
                          >
                            <Icon name="close" size={14} />
                          </button>
                        )}
                      </div>
                    ))}
                    <button
                      className="drv-add-writer"
                      onClick={() => setWriters((prev) => prev.concat([""]))}
                    >
                      <Icon name="plus" size={13} stroke={2} /> Add writer
                    </button>
                    <span className="field-hint">
                      All writers' indexes are merged; newest edit per file wins
                      (last-writer-wins).
                    </span>
                  </div>
                )}
              </div>
            </>
          )}

          <div className="field">
            <label className="field-label">Route</label>
            <div className="route-select route-select-lg">
              {(
                [
                  ["direct", "Direct", "rt-direct", "globe"],
                  ["i2p", "I2P", "rt-proxy", "shield"],
                ] as [DriveRoute, string, string, string][]
              ).map(([id, l, cls, icon]) => (
                <button
                  key={id}
                  className={"rsl-btn " + cls + (route === id ? " active" : "")}
                  onClick={() => setRoute(id)}
                >
                  <Icon name={icon} size={12} />
                  {l}
                </button>
              ))}
            </div>
            <span className="field-hint">{ROUTE_DESC[route]}</span>
          </div>

          {showIp && (
            <div className="field">
              <div className="field-label">External IP</div>
              <input
                className="text-input mono"
                value={ip}
                onChange={(e) => setIp(e.target.value)}
                placeholder="203.0.113.42"
              />
              <span className="field-hint">
                Public IPv4 so peers can reach you (loopback/private is rejected).
              </span>
            </div>
          )}

          {pub && (
            <div className="callout-note">
              <Icon name="shield" size={15} stroke={1.8} />
              <span>Anyone who can read your relay can see this drive's file list.</span>
            </div>
          )}

          {err && (
            <div className="callout-note" style={{ color: "var(--danger)" }}>
              <Icon name="close" size={15} stroke={1.8} />
              <span>{err}</span>
            </div>
          )}
        </div>

        <div className="modal-foot">
          <div className="modal-foot-route">
            <DriveRouteBadge route={route} />
            <span className="drv-nostr-chip">nostr</span>
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
              {busy ? "Starting…" : pub ? "Start publishing" : "Subscribe"}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

/* ===================== loading skeleton ===================== */

function DriveSkeleton() {
  return (
    <div className="drv-skel">
      <div className="drv-skel-top">
        <span className="drv-b" style={{ width: 120, height: 17 }} />
        <span className="drv-b" style={{ width: 74, height: 15, borderRadius: 20 }} />
        <span className="drv-b" style={{ width: 62, height: 15, borderRadius: 20 }} />
      </div>
      <div className="drv-skel-statrow">
        <span className="drv-b" style={{ width: 54, height: 26 }} />
        <span className="drv-b" style={{ width: 70, height: 26 }} />
        <span className="drv-b" style={{ width: 150, height: 26 }} />
      </div>
      <div className="drv-skel-rows">
        <span className="drv-b-r" style={{ height: 15 }} />
        <span className="drv-b-r" style={{ height: 15 }} />
        <span className="drv-b-r" style={{ height: 15 }} />
      </div>
    </div>
  );
}

/* ===================== screen ===================== */

export function DriveScreen() {
  const { state, connected, error, refresh } = useCarl();
  const drives = state.drives ?? [];

  const [showNew, setShowNew] = useState(false);
  const [newRole, setNewRole] = useState<DriveRole>("publisher");
  const [driveOpenId, setDriveOpenId] = useState<string | null>(null);
  const [driveCwd, setDriveCwd] = useState("");
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [paused, setPaused] = useState<Set<string>>(new Set());
  const [confirm, setConfirm] = useState<string | null>(null);
  const [copiedId, setCopiedId] = useState<string | null>(null);

  // Derive the design's four states from the live connection + data:
  //  - loading: first connection attempt, no data and no error yet (skeletons)
  //  - error:   daemon offline, showing whatever cached snapshot we have + banner
  //  - empty:   online, but no drives
  //  - list:    one or more drives
  const offline = !connected;
  const isLoading = offline && !error && drives.length === 0;
  const isError = offline && (!!error || drives.length > 0);
  const showEmpty = !isLoading && !isError && drives.length === 0;
  const showList = drives.length > 0;

  const totalBytes = drives.reduce(
    (a, d) => a + d.files.reduce((x, f) => x + f.size, 0),
    0,
  );
  const driveSummary =
    drives.length + " drive" + (drives.length === 1 ? "" : "s") + " · " + fmtBytes(totalBytes) + " synced";

  const openDrive = drives.find((d) => d.id === driveOpenId) ?? null;

  function toggleExpand(id: string) {
    setExpanded((prev) => {
      const n = new Set(prev);
      if (n.has(id)) n.delete(id);
      else n.add(id);
      return n;
    });
  }
  function togglePause(id: string) {
    setPaused((prev) => {
      const n = new Set(prev);
      if (n.has(id)) n.delete(id);
      else n.add(id);
      return n;
    });
  }
  function copyAuthor(d: Drive) {
    if (!d.author) return;
    try {
      navigator.clipboard.writeText(d.author);
    } catch {
      /* clipboard unavailable */
    }
    setCopiedId(d.id);
    window.setTimeout(() => setCopiedId((c) => (c === d.id ? null : c)), 1300);
  }
  async function doRemove(id: string) {
    setConfirm(null);
    try {
      await driveApi(`/api/drives/${id}`, { method: "DELETE" });
      await refresh();
    } catch (e) {
      window.alert(String(e));
    }
  }

  function openNew(role: DriveRole) {
    setNewRole(role);
    setShowNew(true);
  }

  // Directory view takes over the whole screen when a drive is open.
  if (openDrive) {
    return (
      <DriveDetail
        d={openDrive}
        cwd={driveCwd}
        setCwd={setDriveCwd}
        onClose={() => {
          setDriveOpenId(null);
          setDriveCwd("");
        }}
        isPaused={paused.has(openDrive.id)}
        onTogglePause={() => togglePause(openDrive.id)}
      />
    );
  }

  return (
    <div className="screen">
      <div className="topbar">
        <div className="topbar-l">
          <h1 className="screen-title">Drive</h1>
          <span className="drv-summary mono">{driveSummary}</span>
        </div>
        <div className="topbar-r">
          <button className="btn btn-primary" onClick={() => openNew("publisher")}>
            <Icon name="plus" size={15} stroke={2} /> New drive
          </button>
        </div>
      </div>

      <div className="drv-sub">Sync a folder across your devices over Nostr relays.</div>

      <div className="content">
        {isError && (
          <div className="drv-banner">
            <span className="drv-banner-dot" />
            <span className="drv-banner-msg">Couldn't reach the daemon — showing cached drives.</span>
            <button className="link-btn" onClick={() => refresh()}>
              Retry
            </button>
          </div>
        )}

        {isLoading && (
          <div className="drv-cards">
            <DriveSkeleton />
            <DriveSkeleton />
            <DriveSkeleton />
          </div>
        )}

        {showEmpty && (
          <div className="empty">
            <div className="empty-glyph">
              <Icon name="folder" size={26} stroke={1.7} />
            </div>
            <div className="empty-title">No drives yet</div>
            <div className="empty-sub" style={{ maxWidth: "46ch" }}>
              Publish a folder to share it, or subscribe to someone's npub to mirror theirs.
            </div>
            <div className="drv-empty-actions">
              <button className="btn btn-primary" onClick={() => openNew("publisher")}>
                <Icon name="plus" size={15} stroke={2} /> Publish a folder
              </button>
              <button className="btn" onClick={() => openNew("subscriber")}>
                Subscribe
              </button>
            </div>
            <div className="drv-listen">
              <span className="drv-listen-dot" /> listening for relay updates
            </div>
          </div>
        )}

        {showList && (
          <div className="drv-cards">
            {drives.map((d) => (
              <DriveCard
                key={d.id}
                d={d}
                expanded={expanded.has(d.id)}
                onToggleExpand={() => toggleExpand(d.id)}
                isPaused={paused.has(d.id)}
                onTogglePause={() => togglePause(d.id)}
                confirming={confirm === d.id}
                onAskRemove={() => setConfirm(d.id)}
                onCancelRemove={() => setConfirm(null)}
                onDoRemove={() => doRemove(d.id)}
                onOpenDir={() => {
                  setDriveOpenId(d.id);
                  setDriveCwd("");
                }}
                onCopyAuthor={() => copyAuthor(d)}
                authorCopied={copiedId === d.id}
              />
            ))}
          </div>
        )}
      </div>

      {showNew && (
        <NewDriveModal
          initialRole={newRole}
          onClose={() => setShowNew(false)}
          onCreated={() => refresh()}
        />
      )}
    </div>
  );
}
