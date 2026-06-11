import { useRef, useState } from "react";
import { Icon, OnionIcon } from "../components/icons";
import { RouteBadge, CopyField } from "../components/atoms";
import { fmtBytes, fmtSpeed, trunc } from "../components/format";
import { useCarl } from "../api/store";
import { CreateTorrentModal } from "../modals/CreateTorrentModal";
import type { Route, Seed } from "../api/types";

const VIS_LABEL: Record<Route, string> = {
  direct: "Public IP",
  proxy: "Proxy",
  tor: "Tor hidden service",
  i2p: "I2P destination",
};

// Surfaces the reachable hidden address of an anonymized seed — a `.onion` for
// a Tor hidden service, a `.b32.i2p` destination for an I2P seed. Both expose
// no clearnet IP and are published over Nostr for discovery.
function HiddenAddrCallout({
  kind,
  addr,
  relays,
}: {
  kind: "tor" | "i2p";
  addr: string;
  relays: number;
}) {
  const isI2p = kind === "i2p";
  return (
    <div className="onion-callout">
      <div className="oc-head">
        <span className="oc-icon">
          {isI2p ? <Icon name="shield" size={18} /> : <OnionIcon size={18} />}
        </span>
        <div>
          <div className="oc-title">
            {isI2p
              ? "Seeding as an I2P destination"
              : "Seeding as a Tor hidden service"}
          </div>
          <div className="oc-sub">
            {isI2p
              ? "Peers reach you over this .b32.i2p destination (native SAM v3). Share it via Discover or directly."
              : "Peers reach you over this .onion address. Share it via Discover or directly."}
          </div>
        </div>
        <span className="oc-live">
          <span className="oc-live-dot" /> online
        </span>
      </div>
      <CopyField value={addr} full />
      <div className="oc-foot">
        <span className="oc-published">
          <span className="oc-pub-dot" /> published to{" "}
          <strong>{relays} relays</strong> over Nostr
        </span>
        <span className="oc-leak">
          <Icon name="shield" size={13} stroke={1.8} /> no IP leaked · tracker
          &amp; DHT announces disabled
        </span>
      </div>
    </div>
  );
}

function SeedRow({ s }: { s: Seed }) {
  return (
    <div className="seed-row">
      <span className="seed-route">
        <RouteBadge route={s.visibility} size="sm" />
      </span>
      <div className="seed-main">
        <div className="seed-name mono">{s.name}</div>
        {s.onion ? (
          <div className="seed-onion mono">
            <OnionIcon size={10} /> {trunc(s.onion, 12)}
          </div>
        ) : (
          <div className="seed-onion dim">{VIS_LABEL[s.visibility]}</div>
        )}
      </div>
      <div className="trow-stat">
        <span className="ts-val mono">{fmtBytes(s.size)}</span>
        <span className="ts-lbl">size</span>
      </div>
      <div className="trow-stat">
        <span className="ts-val mono ul">↑ {fmtBytes(s.upTotal)}</span>
        <span className="ts-lbl">uploaded</span>
      </div>
      <div className="trow-stat">
        <span className="ts-val mono ul">{fmtSpeed(s.up)}</span>
        <span className="ts-lbl">rate</span>
      </div>
      <div className="trow-stat">
        <span className="ts-val mono">{s.leechers}</span>
        <span className="ts-lbl">leechers</span>
      </div>
      <div className="trow-stat">
        <span className={"ts-val mono " + (s.ratio >= 1 ? "ratio-ok" : "")}>
          {s.ratio.toFixed(2)}
        </span>
        <span className="ts-lbl">ratio</span>
      </div>
    </div>
  );
}

const VIS_DESC: Record<Route, string> = {
  direct: "Announced to peers over your IP.",
  proxy: "Outbound via SOCKS5. Trackers/DHT disabled; peers via Nostr.",
  tor: "Routed through Tor. No clearnet IP exposed.",
  i2p: "Native I2P (SAM v3). No clearnet IP exposed; peers via Nostr.",
};

function SeedFlow({ onClose }: { onClose: () => void }) {
  const { createSeed } = useCarl();
  const [file, setFile] = useState<File | null>(null);
  const [vis, setVis] = useState<Route>("tor");
  const [nostr, setNostr] = useState(true);
  const [busy, setBusy] = useState(false);
  const [over, setOver] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  async function start() {
    if (!file) return;
    setBusy(true);
    setErr(null);
    try {
      await createSeed(file, vis, nostr);
      onClose();
    } catch (e) {
      setErr(String(e));
      setBusy(false);
    }
  }

  return (
    <div className="modal-scrim" onClick={onClose}>
      <div className="modal seed-modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-head">
          <h2 className="modal-title">Seed a file</h2>
          <button className="icon-btn" onClick={onClose}>
            <Icon name="close" size={16} />
          </button>
        </div>

        <div className="modal-body">
          {!file ? (
            <div
              className={"dropzone" + (over ? " over" : "")}
              onDragOver={(e) => {
                e.preventDefault();
                setOver(true);
              }}
              onDragLeave={() => setOver(false)}
              onDrop={(e) => {
                e.preventDefault();
                setOver(false);
                if (e.dataTransfer.files[0]) setFile(e.dataTransfer.files[0]);
              }}
              onClick={() => inputRef.current?.click()}
            >
              <span className="dz-icon">
                <Icon name="file" size={26} />
              </span>
              <div className="dz-title">Drop a file or archive, or click to choose</div>
              <div className="dz-sub">
                carl hashes it locally and creates the torrent — nothing leaves
                your machine until it's announced.
              </div>
              <input
                ref={inputRef}
                type="file"
                style={{ display: "none" }}
                onChange={(e) => {
                  if (e.target.files?.[0]) setFile(e.target.files[0]);
                }}
              />
            </div>
          ) : (
            <>
              <div className="seed-file-card">
                <Icon
                  name="file"
                  size={18}
                  style={{ color: "var(--fg-faint)" }}
                />
                <span className="mono sfc-name">{file.name}</span>
                <span className="mono dim">{fmtBytes(file.size)}</span>
                <button className="link-btn" onClick={() => setFile(null)}>
                  change
                </button>
              </div>

              <div className="field-label">Visibility</div>
              <div className="vis-options">
                {(["direct", "proxy", "tor", "i2p"] as const).map((id) => (
                  <button
                    key={id}
                    className={"vis-opt" + (vis === id ? " active" : "")}
                    onClick={() => setVis(id)}
                  >
                    <div className="vis-opt-top">
                      <RouteBadge route={id} size="sm" />
                      {vis === id && (
                        <span className="vis-check">
                          <Icon name="check" size={13} stroke={2.4} />
                        </span>
                      )}
                    </div>
                    <div className="vis-opt-name">{VIS_LABEL[id]}</div>
                    <div className="vis-opt-desc">{VIS_DESC[id]}</div>
                  </button>
                ))}
              </div>

              {err && (
                <div
                  className="callout-note"
                  style={{ color: "var(--danger)" }}
                >
                  <Icon name="close" size={15} stroke={1.8} />
                  <span>{err}</span>
                </div>
              )}
            </>
          )}
        </div>

        <div className="modal-foot">
          <label className="chk">
            <input
              type="checkbox"
              checked={nostr}
              onChange={(e) => setNostr(e.target.checked)}
            />
            <span>Announce over Nostr (NIP-35)</span>
          </label>
          <div className="modal-foot-actions">
            <button className="btn" onClick={onClose}>
              Cancel
            </button>
            <button
              className={"btn btn-primary" + (file && !busy ? "" : " disabled")}
              disabled={!file || busy}
              onClick={start}
            >
              <Icon name="plus" size={14} stroke={2.2} />
              {busy ? "Creating…" : "Start seeding"}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

export function SeedingScreen() {
  const { state } = useCarl();
  const seeds = state.seeds;
  const [flow, setFlow] = useState(false);
  const [createFlow, setCreateFlow] = useState(false);
  const upTotal = seeds.reduce((a, s) => a + s.up, 0);
  // The first anonymized seed with a published address gets the hero callout
  // (tor `.onion` or i2p `.b32.i2p`); both carry their address in `onion`.
  const hiddenSeed = seeds.find(
    (s) => (s.visibility === "tor" || s.visibility === "i2p") && s.onion,
  );

  return (
    <div className="screen">
      <div className="topbar">
        <div className="topbar-l">
          <h1 className="screen-title">Seeding</h1>
          <div className="rate-readout">
            <span className="mono ul">↑ {fmtSpeed(upTotal)}</span>
            <span className="dim" style={{ fontSize: 12 }}>
              {seeds.length} file{seeds.length === 1 ? "" : "s"}
            </span>
          </div>
        </div>
        <div className="topbar-r">
          <button className="btn" onClick={() => setCreateFlow(true)}>
            <Icon name="file" size={15} stroke={2} /> Create .torrent
          </button>
          <button className="btn btn-primary" onClick={() => setFlow(true)}>
            <Icon name="plus" size={15} stroke={2} /> Seed a file
          </button>
        </div>
      </div>

      <div className="content">
        {hiddenSeed && hiddenSeed.onion && (
          <HiddenAddrCallout
            kind={hiddenSeed.visibility === "i2p" ? "i2p" : "tor"}
            addr={hiddenSeed.onion}
            relays={hiddenSeed.relays}
          />
        )}
        {seeds.length === 0 ? (
          <div className="empty">
            <div className="empty-glyph">
              <Icon name="seeding" size={26} />
            </div>
            <div className="empty-title">Nothing seeding yet</div>
            <div className="empty-sub">
              Completed downloads keep seeding and show up here. Tor and I2P
              seeds surface their <span className="mono">.onion</span> /{" "}
              <span className="mono">.b32.i2p</span> address with a "no IP leaked"
              guarantee.
            </div>
          </div>
        ) : (
          <>
            <div className="trow-head seed-head">
              <span className="th-route">Route</span>
              <span className="th-name">File</span>
              <span className="th-stat">Size</span>
              <span className="th-stat">Uploaded</span>
              <span className="th-stat">Rate</span>
              <span className="th-stat">Leechers</span>
              <span className="th-stat">Ratio</span>
            </div>
            <div className="trow-list">
              {seeds.map((s) => (
                <SeedRow key={s.id} s={s} />
              ))}
            </div>
          </>
        )}
      </div>

      {flow && <SeedFlow onClose={() => setFlow(false)} />}
      {createFlow && (
        <CreateTorrentModal onClose={() => setCreateFlow(false)} />
      )}
    </div>
  );
}
