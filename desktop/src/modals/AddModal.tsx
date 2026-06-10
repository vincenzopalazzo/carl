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

// Hints per anonymized download route. Downloads never run clearnet — the
// choice is which anonymity network dials the peers.
const ROUTE_HINT: Record<"tor" | "i2p", string> = {
  tor: "Downloads are routed over Tor — your IP is never exposed. Trackers & DHT off · peers via Nostr. Requires a running Tor SOCKS proxy (127.0.0.1:9050).",
  i2p: "Peers are dialed as .b32.i2p destinations over native I2P (SAM v3) — your IP is never exposed. Trackers & DHT off · peers via Nostr. Requires a running I2P router with SAM (127.0.0.1:7656).",
};

export function AddModal({ onClose }: { onClose: () => void }) {
  const { addTransfer } = useCarl();
  const [tab, setTab] = useState<Tab>("magnet");
  const [val, setVal] = useState("");
  const [nostr, setNostr] = useState(true);
  // Downloads are anonymized-only — Tor by default, native I2P as the
  // alternative. Direct/proxy are deliberately not offered for downloads.
  const [route, setRoute] = useState<Route>("tor");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // The daemon has no I2P-tunneled HTTP fetch yet (P3, #35): an HTTP .torrent
  // source on the i2p route is rejected (fail-closed), so block it up front.
  const urlUnsupported = tab === "url" && route === "i2p";
  const canAdd = val.trim().length > 0 && !busy && !urlUnsupported;

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
                <button
                  className={"rsl-btn" + (route === "tor" ? " active rt-tor" : "")}
                  onClick={() => setRoute("tor")}
                >
                  <OnionIcon size={12} />
                  Tor
                </button>
                <button
                  className={"rsl-btn" + (route === "i2p" ? " active rt-i2p" : "")}
                  onClick={() => setRoute("i2p")}
                >
                  <Icon name="shield" size={12} />
                  I2P
                </button>
              </div>
              <span className="field-hint">
                {ROUTE_HINT[route as "tor" | "i2p"]}
              </span>
              {urlUnsupported && (
                <span className="field-hint" style={{ color: "var(--warn)" }}>
                  HTTP .torrent sources aren't supported on I2P yet (no
                  I2P-tunneled fetch — it would leak). Use a magnet/file, or
                  Tor for URL sources.
                </span>
              )}
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
