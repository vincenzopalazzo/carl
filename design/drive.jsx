// drive.jsx — Drive screen: local folders synced Google-Drive-style over Nostr.
//
// A "drive" is a watched folder: a publisher seeds it and posts a signed index
// to relays; subscribers mirror it and converge on edits. Mirrors the daemon's
// REST contract (docs/daemon-api.md):
//   Drive = { id, role: "publisher"|"subscriber", name, dir, route: "direct"|"i2p",
//             author: string|null, also: string[],
//             files: [{ path, size, phase, info_hash }], file_count }
// Mock data lives here (data.jsx is shared); shapes match the API 1-1.

const DRIVES = [
  {
    id: "drv-7f3a2c",
    role: "publisher",
    name: "mixtapes",
    dir: "~/Music/mixtapes",
    route: "direct",
    author: null,
    also: [],
    file_count: 3,
    files: [
      { path: "ambient-2026-04.flac", size: 312_460_288, phase: "seeding", info_hash: "9f2c8d41b7e6a053c1d4f8e2b9a30761d5c84f2a" },
      { path: "live-at-the-bunker.mp3", size: 98_304_512, phase: "seeding", info_hash: "3b7e91a4c6d208f5e1b4a7c9d2f60385e4a91b7c" },
      { path: "notes-on-side-b.txt", size: 4_096, phase: "seeding", info_hash: "c41d5f8e2b9a30761d5c84f2a9f2c8d41b7e6a05" },
    ],
  },
  {
    id: "drv-b21c90",
    role: "subscriber",
    name: "fieldnotes",
    dir: "~/carl/drive-8d3f1a2c4b9e/fieldnotes",
    route: "i2p",
    author: "npub1fieldn0tes9x2k4m8q3v7w5z1c6b4n8m2l0k9j7h5g3f1ds8d3f1a2",
    also: ["npub1collab0writer7h5g3f1d2s4a6q8w0e2r4t6y8u0i2o4p6m8n0b2v4c6x8z"],
    file_count: 3,
    files: [
      { path: "index.md", size: 18_432, phase: "seeding", info_hash: "1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d" },
      { path: "svalbard-log-07.md", size: 61_440, phase: "downloading", info_hash: "f5e4d3c2b1a09876f5e4d3c2b1a09876f5e4d3c2" },
      { path: "map-tiles.pack", size: 486_539_264, phase: "starting", info_hash: "08f7e6d5c4b3a291807f6e5d4c3b2a1908f7e6d5" },
    ],
  },
];

// Drive routes map onto the existing route-badge system: direct → clearnet,
// i2p → proxied (the prototype's badge vocabulary is direct/proxy/tor).
const DRIVE_ROUTE = { direct: "direct", i2p: "proxy" };
const DRIVE_ROUTE_DESC = {
  direct: "Peers see your IP. Fastest sync.",
  i2p: "Synced over I2P · no clearnet IP exposed.",
};

// Role reuses the status-pill treatment (no new color): a publisher seeds its
// folder, a subscriber pulls it — st-seed / st-down are already that language.
function RolePill({ role }) {
  return (
    <span className={"status-pill " + (role === "publisher" ? "st-seed" : "st-down")}>
      <span className="sp-dot" />
      {role}
    </span>
  );
}

// Live phase per file, mapped onto the shared status-pill vocabulary
// (starting → metadata indeterminate, failed → stalled) — same mapping the
// Following screen uses for mirror phases.
function filePillStatus(phase) {
  switch (phase) {
    case "seeding": return "seeding";
    case "downloading": return "downloading";
    case "failed": return "stalled";
    default: return "metadata";
  }
}

function DriveFiles({ files }) {
  return (
    <table className="files-table" style={{ marginTop: 15 }}>
      <thead>
        <tr><th>File</th><th className="num">Size</th><th>Phase</th><th className="num">Info-hash</th></tr>
      </thead>
      <tbody>
        {files.map((f) => (
          <tr key={f.path}>
            <td className="file-name"><Icon name="file" size={14} style={{ color: "var(--fg-faint)" }} /><span className="mono">{f.path}</span></td>
            <td className="num mono">{fmtBytes(f.size)}</td>
            <td><StatusPill status={filePillStatus(f.phase)} /></td>
            <td className="num mono dim">{trunc(f.info_hash, 8)}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function DriveCard({ d }) {
  const total = d.files.reduce((a, f) => a + f.size, 0);
  return (
    <div className="dcard">
      <div className="dcard-head">
        <div className="dcard-title-wrap">
          <h3 className="dcard-title">{d.name}</h3>
          <div className="dcard-sig">
            <RolePill role={d.role} />
            <RouteBadge route={DRIVE_ROUTE[d.route]} size="sm" />
            {d.role === "subscriber" && d.author && (
              <span className="dcard-author mono">{trunc(d.author, 10)}</span>
            )}
            {d.also.length > 0 && (
              <span className="dcard-age">+{d.also.length} writer{d.also.length === 1 ? "" : "s"}</span>
            )}
          </div>
        </div>
        <button className="icon-btn" title="Remove drive (files stay on disk)">
          <Icon name="close" size={15} />
        </button>
      </div>

      <div className="dcard-meta">
        <div className="dm-item"><span className="dm-val mono">{d.file_count}</span><span className="dm-lbl">files</span></div>
        <div className="dm-item"><span className="dm-val mono">{fmtBytes(total)}</span><span className="dm-lbl">size</span></div>
        <div className="dm-item"><span className="dm-val mono" style={{ fontSize: 12 }}>{d.dir}</span><span className="dm-lbl">folder</span></div>
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

function NewDriveModal({ onClose }) {
  const [role, setRole] = React.useState("publisher"); // publisher | subscriber
  const [dir, setDir] = React.useState("");
  const [name, setName] = React.useState("");
  const [author, setAuthor] = React.useState("");
  const [also, setAlso] = React.useState("");
  const [route, setRoute] = React.useState("i2p");

  const canCreate =
    name.trim() &&
    (role === "publisher"
      ? dir.trim()
      : author.trim().startsWith("npub1") || /^[0-9a-fA-F]{64}$/.test(author.trim()));

  return (
    <div className="modal-scrim" onClick={onClose}>
      <div className="modal add-modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-head">
          <h2 className="modal-title">New drive</h2>
          <button className="icon-btn" onClick={onClose}><Icon name="close" size={16} /></button>
        </div>

        <div className="modal-body">
          <div className="add-tabs">
            {[["publisher", "Publish a folder"], ["subscriber", "Subscribe"]].map(([id, l]) => (
              <button key={id} className={"add-tab" + (role === id ? " active" : "")} onClick={() => setRole(id)}>{l}</button>
            ))}
          </div>

          {role === "publisher" ? (
            <React.Fragment>
              <div className="field">
                <div className="field-label">Folder <span className="fl-hint">watched &amp; seeded</span></div>
                <input className="text-input mono add-input" autoFocus value={dir} onChange={(e) => setDir(e.target.value)}
                  placeholder="~/Music/mixtapes" />
                <span className="field-hint">carl hashes every file in this folder and keeps seeding it. Edits are re-published as a new signed index.</span>
              </div>
              <div className="field">
                <div className="field-label">Drive name</div>
                <input className="text-input add-input" value={name} onChange={(e) => setName(e.target.value)}
                  placeholder="mixtapes" />
              </div>
            </React.Fragment>
          ) : (
            <React.Fragment>
              <div className="field">
                <div className="field-label">Author <span className="fl-hint">npub1… or 64-char hex</span></div>
                <input className="text-input mono add-input" autoFocus value={author} onChange={(e) => setAuthor(e.target.value)}
                  placeholder="npub1…" />
                <span className="field-hint">The key that signs this drive's index on your relays. carl mirrors everything it publishes and converges on edits.</span>
              </div>
              <div className="field">
                <div className="field-label">Drive name</div>
                <input className="text-input add-input" value={name} onChange={(e) => setName(e.target.value)}
                  placeholder="fieldnotes" />
              </div>
              <div className="field">
                <div className="field-label">Extra writers <span className="fl-hint">optional · comma-separated</span></div>
                <input className="text-input mono add-input" value={also} onChange={(e) => setAlso(e.target.value)}
                  placeholder="npub1…, npub1…" />
                <span className="field-hint">Additional keys allowed to write to this drive (multi-writer merge; the author wins conflicts).</span>
              </div>
              <div className="field">
                <div className="field-label">Mirror into <span className="fl-hint">optional</span></div>
                <input className="text-input mono add-input" value={dir} onChange={(e) => setDir(e.target.value)}
                  placeholder="default: ~/carl/drive-&lt;pubkey&gt;-&lt;name&gt;" />
              </div>
            </React.Fragment>
          )}

          <div className="field">
            <label className="field-label">Route</label>
            <div className="route-select route-select-lg">
              {[["direct", "Direct"], ["i2p", "I2P"]].map(([id, l]) => (
                <button key={id} className={"rsl-btn" + (route === id ? " active " + (id === "i2p" ? "rt-proxy" : "rt-direct") : "")} onClick={() => setRoute(id)}>
                  {id === "i2p" ? <Icon name="shield" size={12} /> : <Icon name="globe" size={12} />}
                  {l}
                </button>
              ))}
            </div>
            <span className="field-hint">{DRIVE_ROUTE_DESC[route]}</span>
          </div>
        </div>

        <div className="modal-foot">
          <div className="modal-foot-route"><RouteBadge route={DRIVE_ROUTE[route]} size="sm" /><SourceChip kind="nostr" /></div>
          <div className="modal-foot-actions">
            <button className="btn" onClick={onClose}>Cancel</button>
            <button className={"btn btn-primary" + (canCreate ? "" : " disabled")} disabled={!canCreate} onClick={onClose}>
              <Icon name="plus" size={14} stroke={2.2} /> {role === "publisher" ? "Publish drive" : "Subscribe"}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

function DriveScreen() {
  const [showNew, setShowNew] = React.useState(false);
  const totalBytes = DRIVES.reduce((a, d) => a + d.files.reduce((x, f) => x + f.size, 0), 0);
  return (
    <div className="screen">
      <div className="topbar">
        <div className="topbar-l">
          <h1 className="screen-title">Drive</h1>
          <div className="rate-readout">
            <span className="dim" style={{ fontSize: 12 }}>
              {DRIVES.length} drive{DRIVES.length === 1 ? "" : "s"} · <span className="mono">{fmtBytes(totalBytes)}</span> synced
            </span>
          </div>
        </div>
        <div className="topbar-r">
          <button className="btn btn-primary" onClick={() => setShowNew(true)}><Icon name="plus" size={15} stroke={2} /> New drive</button>
        </div>
      </div>

      <div className="content">
        {DRIVES.length === 0 ? (
          <div className="empty">
            <div className="empty-glyph"><Icon name="folder" size={26} /></div>
            <div className="empty-title">No drives yet</div>
            <div className="empty-sub">
              Publish a folder or subscribe to someone's npub — carl keeps both
              sides in sync over Nostr, Google-Drive-style, with no server in
              the middle.
            </div>
            <button className="btn btn-primary" style={{ marginTop: 10 }} onClick={() => setShowNew(true)}>
              <Icon name="plus" size={15} stroke={2} /> New drive
            </button>
          </div>
        ) : (
          <div className="dcard-list">
            {DRIVES.map((d) => <DriveCard key={d.id} d={d} />)}
          </div>
        )}
      </div>

      {showNew && <NewDriveModal onClose={() => setShowNew(false)} />}
    </div>
  );
}

Object.assign(window, { DriveScreen, DRIVES });
