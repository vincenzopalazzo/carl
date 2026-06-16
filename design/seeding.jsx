// seeding.jsx — Seeding screen + Seed-a-file flow + onion callout

const VIS_META = {
  direct: { label: "Public IP", route: "direct", desc: "Announced to trackers + DHT. Your IP is visible to peers." },
  proxy: { label: "Proxy", route: "proxy", desc: "Outbound via SOCKS5. Trackers/DHT disabled; peers via Nostr." },
  tor: { label: "Tor hidden service", route: "tor", desc: "Seed as a .onion. No IP, no trackers, no DHT — Nostr only." },
};

function OnionCallout({ onion, relays }) {
  return (
    <div className="onion-callout">
      <div className="oc-head">
        <span className="oc-icon"><OnionIcon size={18} /></span>
        <div>
          <div className="oc-title">Seeding as a Tor hidden service</div>
          <div className="oc-sub">Peers reach you over this .onion address. Share it via Discover or directly.</div>
        </div>
        <span className="oc-live"><span className="oc-live-dot" /> online</span>
      </div>
      <CopyField value={onion} full />
      <div className="oc-foot">
        <span className="oc-published">
          <span className="oc-pub-dot" /> published to <strong>{relays} relays</strong> over Nostr
        </span>
        <span className="oc-leak">
          <Icon name="shield" size={13} stroke={1.8} /> no IP leaked · tracker &amp; DHT announces disabled
        </span>
      </div>
    </div>
  );
}

function SeedRow({ s }) {
  return (
    <div className="seed-row">
      <span className="seed-route"><RouteBadge route={s.visibility} size="sm" /></span>
      <div className="seed-main">
        <div className="seed-name mono">{s.name}</div>
        {s.onion && <div className="seed-onion mono"><OnionIcon size={10} /> {trunc(s.onion, 12)}</div>}
        {!s.onion && <div className="seed-onion dim">{VIS_META[s.visibility].label}</div>}
      </div>
      <div className="trow-stat"><span className="ts-val mono">{fmtBytes(s.size)}</span><span className="ts-lbl">size</span></div>
      <div className="trow-stat"><span className="ts-val mono ul">{"\u2191"} {fmtBytes(s.upTotal)}</span><span className="ts-lbl">uploaded</span></div>
      <div className="trow-stat"><span className="ts-val mono ul">{fmtSpeed(s.up)}</span><span className="ts-lbl">rate</span></div>
      <div className="trow-stat"><span className="ts-val mono">{s.leechers}</span><span className="ts-lbl">leechers</span></div>
      <div className="trow-stat"><span className={"ts-val mono " + (s.ratio >= 1 ? "ratio-ok" : "")}>{s.ratio.toFixed(2)}</span><span className="ts-lbl">ratio</span></div>
    </div>
  );
}

function SeedFlow({ onClose }) {
  const [step, setStep] = React.useState("pick"); // pick | configure | live
  const [file, setFile] = React.useState(null);
  const [vis, setVis] = React.useState("tor");
  const onion = "kx7m2qp9nfz4vw8d6r3slmc0ojtb5haeuyx1qprtkn7fwd5v2sba.onion";

  const pickFile = () => { setFile({ name: "ubuntu-keynote-2026.mp4", size: 1.84 * 1024 * 1024 * 1024 }); setStep("configure"); };

  return (
    <div className="modal-scrim" onClick={onClose}>
      <div className="modal seed-modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-head">
          <h2 className="modal-title">Seed a file</h2>
          <button className="icon-btn" onClick={onClose}><Icon name="close" size={16} /></button>
        </div>

        {step === "pick" && (
          <div className="modal-body">
            <div className="dropzone" onClick={pickFile}>
              <span className="dz-icon"><Icon name="file" size={26} /></span>
              <div className="dz-title">Drop a file or folder, or click to choose</div>
              <div className="dz-sub">carl hashes it locally and creates the torrent — nothing leaves your machine until you publish.</div>
            </div>
          </div>
        )}

        {step !== "pick" && (
          <div className="modal-body">
            <div className="seed-file-card">
              <Icon name="file" size={18} style={{ color: "var(--fg-faint)" }} />
              <span className="mono sfc-name">{file.name}</span>
              <span className="mono dim">{fmtBytes(file.size)}</span>
              <button className="link-btn" onClick={() => setStep("pick")}>change</button>
            </div>

            <div className="field-label">Visibility</div>
            <div className="vis-options">
              {Object.entries(VIS_META).map(([id, m]) => (
                <button key={id} className={"vis-opt" + (vis === id ? " active" : "")} onClick={() => setVis(id)}>
                  <div className="vis-opt-top">
                    <RouteBadge route={m.route} size="sm" />
                    {vis === id && <span className="vis-check"><Icon name="check" size={13} stroke={2.4} /></span>}
                  </div>
                  <div className="vis-opt-name">{m.label}</div>
                  <div className="vis-opt-desc">{m.desc}</div>
                </button>
              ))}
            </div>

            {step === "live" && vis === "tor" && <OnionCallout onion={onion} relays={4} />}
          </div>
        )}

        {step !== "pick" && (
          <div className="modal-foot">
            <label className="chk">
              <input type="checkbox" defaultChecked /> <span>Announce over Nostr (NIP-35)</span>
            </label>
            <div className="modal-foot-actions">
              <button className="btn" onClick={onClose}>Cancel</button>
              {step === "configure" ? (
                <button className="btn btn-primary" onClick={() => setStep("live")}>
                  {vis === "tor" ? "Start hidden service" : "Start seeding"}
                </button>
              ) : (
                <button className="btn btn-primary" onClick={onClose}><Icon name="check" size={14} stroke={2.2} /> Done</button>
              )}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

function SeedingScreen() {
  const [flow, setFlow] = React.useState(false);
  const upTotal = SEEDS.reduce((a, s) => a + s.up, 0);
  const torSeed = SEEDS.find((s) => s.visibility === "tor");
  return (
    <div className="screen">
      <div className="topbar">
        <div className="topbar-l">
          <h1 className="screen-title">Seeding</h1>
          <div className="rate-readout"><span className="mono ul">{"\u2191"} {fmtSpeed(upTotal)}</span><span className="dim" style={{ fontSize: 12 }}>{SEEDS.length} files</span></div>
        </div>
        <div className="topbar-r">
          <button className="btn btn-primary" onClick={() => setFlow(true)}><Icon name="plus" size={15} stroke={2} /> Seed a file</button>
        </div>
      </div>

      <div className="content">
        {torSeed && <OnionCallout onion={torSeed.onion} relays={torSeed.relays} />}
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
          {SEEDS.map((s) => <SeedRow key={s.id} s={s} />)}
        </div>
      </div>

      {flow && <SeedFlow onClose={() => setFlow(false)} />}
    </div>
  );
}

Object.assign(window, { SeedingScreen, OnionCallout });
