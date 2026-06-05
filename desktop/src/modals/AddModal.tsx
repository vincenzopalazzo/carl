import { useState } from "react";
import { Icon, OnionIcon } from "../components/icons";
import { RouteBadge, SourceChip } from "../components/atoms";
import { useCarl } from "../api/store";
import type { Route } from "../api/types";

type Tab = "magnet" | "file" | "url";

const PLACEHOLDER: Record<Tab, string> = {
  magnet: "magnet:?xt=urn:btih:…",
  file: "/absolute/path/to/file.torrent",
  url: "https://example.org/file.torrent",
};

const HINT: Record<Tab, string> = {
  magnet: "Paste a magnet URI. The info-hash is parsed and verified locally.",
  file: "Absolute path to a .torrent the daemon can read on this machine.",
  url: "carl fetches the .torrent over your selected route.",
};

export function AddModal({ onClose }: { onClose: () => void }) {
  const { addTransfer } = useCarl();
  const [tab, setTab] = useState<Tab>("magnet");
  const [val, setVal] = useState("");
  const [nostr, setNostr] = useState(true);
  // Downloads are Tor-only — privacy by default; the IP is never exposed.
  const route: Route = "tor";
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const canAdd = val.trim().length > 0 && !busy;

  async function submit() {
    if (!canAdd) return;
    setBusy(true);
    setError(null);
    try {
      await addTransfer(val.trim(), route, nostr);
      onClose();
    } catch (e) {
      setError(String(e));
      setBusy(false);
    }
  }

  return (
    <div className="modal-scrim" onClick={onClose}>
      <div className="modal add-modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-head">
          <h2 className="modal-title">Add transfer</h2>
          <button className="icon-btn" onClick={onClose}>
            <Icon name="close" size={16} />
          </button>
        </div>

        <div className="modal-body">
          <div className="add-tabs">
            {(
              [
                ["magnet", "Magnet link"],
                ["file", ".torrent file"],
                ["url", "HTTP URL"],
              ] as const
            ).map(([id, l]) => (
              <button
                key={id}
                className={"add-tab" + (tab === id ? " active" : "")}
                onClick={() => setTab(id)}
              >
                {l}
              </button>
            ))}
          </div>

          <div className="field">
            <input
              className="text-input mono add-input"
              autoFocus
              value={val}
              onChange={(e) => setVal(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") submit();
              }}
              placeholder={PLACEHOLDER[tab]}
            />
            <span className="field-hint">{HINT[tab]}</span>
          </div>

          <div className="add-options">
            <div className="field">
              <label className="field-label">Route</label>
              <div className="route-select route-select-lg">
                <button className="rsl-btn active rt-tor" disabled>
                  <OnionIcon size={12} />
                  Tor
                </button>
              </div>
              <span className="field-hint">
                Downloads are routed over Tor only — your IP is never exposed.
                Trackers &amp; DHT off · peers via Nostr. Requires a running Tor
                SOCKS proxy (127.0.0.1:9050).
              </span>
            </div>

            <label
              className={"toggle-row" + (nostr ? " on" : "")}
              onClick={() => setNostr(!nostr)}
            >
              <span className="tr-switch">
                <span className="tr-knob" />
              </span>
              <span className="tr-txt">
                <span className="tr-label">--nostr · find peers via Nostr</span>
                <span className="tr-desc">
                  Query relays for peer-announce events in addition to
                  trackers/DHT.
                </span>
              </span>
            </label>

            {error && (
              <div className="callout-note" style={{ color: "var(--danger)" }}>
                <Icon name="close" size={15} stroke={1.8} />
                <span>{error}</span>
              </div>
            )}
          </div>
        </div>

        <div className="modal-foot">
          <div className="modal-foot-route">
            <RouteBadge route={route} size="sm" />
            {nostr && <SourceChip kind="nostr" />}
          </div>
          <div className="modal-foot-actions">
            <button className="btn" onClick={onClose}>
              Cancel
            </button>
            <button
              className={"btn btn-primary" + (canAdd ? "" : " disabled")}
              disabled={!canAdd}
              onClick={submit}
            >
              <Icon name="plus" size={14} stroke={2.2} />{" "}
              {busy ? "Adding…" : "Add transfer"}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
