import { useState } from "react";
import { Icon, OnionIcon } from "../components/icons";
import { RouteBadge, CopyField } from "../components/atoms";
import { fmtBytes, fmtSpeed, trunc } from "../components/format";
import { useCarl } from "../api/store";
import type { Route, Seed } from "../api/types";

const VIS_LABEL: Record<Route, string> = {
  direct: "Public IP",
  proxy: "Proxy",
  tor: "Tor hidden service",
};

function OnionCallout({ onion, relays }: { onion: string; relays: number }) {
  return (
    <div className="onion-callout">
      <div className="oc-head">
        <span className="oc-icon">
          <OnionIcon size={18} />
        </span>
        <div>
          <div className="oc-title">Seeding as a Tor hidden service</div>
          <div className="oc-sub">
            Peers reach you over this .onion address. Share it via Discover or
            directly.
          </div>
        </div>
        <span className="oc-live">
          <span className="oc-live-dot" /> online
        </span>
      </div>
      <CopyField value={onion} full />
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

function SeedInfoModal({ onClose }: { onClose: () => void }) {
  return (
    <div className="modal-scrim" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-head">
          <h2 className="modal-title">Seed a file</h2>
          <button className="icon-btn" onClick={onClose}>
            <Icon name="close" size={16} />
          </button>
        </div>
        <div className="modal-body">
          <div className="callout-note">
            <Icon name="shield" size={15} stroke={1.8} />
            <span>
              Creating a torrent from a local file (hashing it and, for Tor,
              standing up a hidden service) is the next milestone — the daemon
              doesn't expose a create endpoint yet. For now, anything you
              download keeps seeding and appears in this list automatically once
              it reaches the seeding state.
            </span>
          </div>
        </div>
        <div className="modal-foot">
          <span />
          <div className="modal-foot-actions">
            <button className="btn btn-primary" onClick={onClose}>
              Got it
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
  const [info, setInfo] = useState(false);
  const upTotal = seeds.reduce((a, s) => a + s.up, 0);
  const torSeed = seeds.find((s) => s.visibility === "tor" && s.onion);

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
          <button className="btn btn-primary" onClick={() => setInfo(true)}>
            <Icon name="plus" size={15} stroke={2} /> Seed a file
          </button>
        </div>
      </div>

      <div className="content">
        {torSeed && torSeed.onion && (
          <OnionCallout onion={torSeed.onion} relays={torSeed.relays} />
        )}
        {seeds.length === 0 ? (
          <div className="empty">
            <div className="empty-glyph">
              <Icon name="seeding" size={26} />
            </div>
            <div className="empty-title">Nothing seeding yet</div>
            <div className="empty-sub">
              Completed downloads keep seeding and show up here. Tor-routed seeds
              surface their <span className="mono">.onion</span> address with a
              "no IP leaked" guarantee.
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

      {info && <SeedInfoModal onClose={() => setInfo(false)} />}
    </div>
  );
}
