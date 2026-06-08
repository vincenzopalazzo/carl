import { useState } from "react";
import { Icon } from "../components/icons";
import { CopyField } from "../components/atoms";
import { fmtBytes } from "../components/format";
import { useCarl } from "../api/store";
import type { CreateTorrentResult } from "../api/types";

/** True inside the Tauri shell — gates the native file/folder picker. In a
 *  plain browser the user types an absolute path the daemon can read instead. */
function isTauri(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

/**
 * Build a .torrent from a local file or directory. The daemon reads the path
 * server-side (folders can't be uploaded as bytes) and writes `<path>.torrent`,
 * so this is path-based: in Tauri we open a native picker; in a browser the
 * user pastes an absolute path. Trackers are optional — carl discovers peers
 * over Nostr/DHT — and live one-per-line.
 */
export function CreateTorrentModal({ onClose }: { onClose: () => void }) {
  const { createTorrent } = useCarl();
  const [path, setPath] = useState("");
  const [trackers, setTrackers] = useState("");
  const [comment, setComment] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [result, setResult] = useState<CreateTorrentResult | null>(null);

  const canCreate = path.trim().length > 0 && !busy;

  async function browse(directory: boolean) {
    setErr(null);
    try {
      const { open } = await import("@tauri-apps/plugin-dialog");
      const sel = await open({
        directory,
        multiple: false,
        title: directory ? "Choose a folder" : "Choose a file",
      });
      if (typeof sel === "string") setPath(sel);
    } catch (e) {
      setErr(String(e));
    }
  }

  async function submit() {
    if (!canCreate) return;
    setBusy(true);
    setErr(null);
    try {
      const list = trackers
        .split("\n")
        .map((t) => t.trim())
        .filter(Boolean);
      const r = await createTorrent(
        path.trim(),
        list,
        comment.trim() || undefined,
      );
      setResult(r);
    } catch (e) {
      setErr(String(e));
    }
    setBusy(false);
  }

  return (
    <div className="modal-scrim" onClick={onClose}>
      <div className="modal seed-modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-head">
          <h2 className="modal-title">Create a .torrent</h2>
          <button className="icon-btn" onClick={onClose}>
            <Icon name="close" size={16} />
          </button>
        </div>

        <div className="modal-body">
          {result ? (
            <>
              <div className="callout-note">
                <Icon name="check" size={15} stroke={2} />
                <span>
                  Created a torrent with {result.files} file
                  {result.files === 1 ? "" : "s"} ({fmtBytes(result.size)}).
                </span>
              </div>
              <div className="field">
                <label className="field-label">Saved to</label>
                <CopyField value={result.path} full />
              </div>
              <div className="field">
                <label className="field-label">Info hash</label>
                <CopyField value={result.infoHash} full />
              </div>
            </>
          ) : (
            <>
              <div className="field">
                <label className="field-label">File or folder</label>
                <div className="add-input-row" style={{ display: "flex", gap: 8 }}>
                  <input
                    className="text-input mono add-input"
                    style={{ flex: 1 }}
                    value={path}
                    autoFocus
                    onChange={(e) => setPath(e.target.value)}
                    placeholder="/absolute/path/to/file-or-folder"
                  />
                  {isTauri() && (
                    <>
                      <button className="btn" onClick={() => browse(false)}>
                        File…
                      </button>
                      <button className="btn" onClick={() => browse(true)}>
                        Folder…
                      </button>
                    </>
                  )}
                </div>
                <span className="field-hint">
                  A directory becomes a multi-file torrent. The daemon hashes it
                  locally and writes <span className="mono">&lt;name&gt;.torrent</span>{" "}
                  next to it.
                </span>
              </div>

              <div className="field">
                <label className="field-label">Trackers (optional)</label>
                <textarea
                  className="text-input mono"
                  rows={3}
                  value={trackers}
                  onChange={(e) => setTrackers(e.target.value)}
                  placeholder={"http://tracker.example/announce\nudp://tracker2.example:6969"}
                />
                <span className="field-hint">
                  One per line. Leave empty for a trackerless torrent (peers via
                  Nostr/DHT).
                </span>
              </div>

              <div className="field">
                <label className="field-label">Comment (optional)</label>
                <input
                  className="text-input"
                  value={comment}
                  onChange={(e) => setComment(e.target.value)}
                  placeholder="e.g. release notes or a description"
                />
              </div>

              {err && (
                <div className="callout-note" style={{ color: "var(--danger)" }}>
                  <Icon name="close" size={15} stroke={1.8} />
                  <span>{err}</span>
                </div>
              )}
            </>
          )}
        </div>

        <div className="modal-foot">
          <div className="modal-foot-route" />
          <div className="modal-foot-actions">
            <button className="btn" onClick={onClose}>
              {result ? "Done" : "Cancel"}
            </button>
            {!result && (
              <button
                className={"btn btn-primary" + (canCreate ? "" : " disabled")}
                disabled={!canCreate}
                onClick={submit}
              >
                <Icon name="plus" size={14} stroke={2.2} />{" "}
                {busy ? "Creating…" : "Create .torrent"}
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
