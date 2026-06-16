// transfers.jsx — Transfers screen + expanded detail panel

function DetailTabs({ t }) {
  const [tab, setTab] = React.useState("peers");
  const tabs = [
    ["peers", "Peers", t.peers],
    ["pieces", "Pieces", null],
    ["sources", "Sources", null],
    ["files", "Files", FILES.length],
  ];
  return (
    <div className="detail">
      <div className="detail-tabs">
        {tabs.map(([id, label, count]) => (
          <button key={id} className={"dtab" + (tab === id ? " active" : "")} onClick={() => setTab(id)}>
            {label}{count != null && <span className="dtab-count">{count}</span>}
          </button>
        ))}
      </div>
      <div className="detail-body">
        {tab === "peers" && <PeersTab />}
        {tab === "pieces" && <PiecesTab t={t} />}
        {tab === "sources" && <SourcesTab />}
        {tab === "files" && <FilesTab />}
      </div>
    </div>
  );
}

function PeersTab() {
  return (
    <table className="peers-table">
      <thead>
        <tr>
          <th>Address</th>
          <th>Client</th>
          <th className="num">Done</th>
          <th className="num">{"\u2193"} Down</th>
          <th className="num">{"\u2191"} Up</th>
          <th>Flags</th>
        </tr>
      </thead>
      <tbody>
        {PEERS.map((p, i) => (
          <tr key={i} className={p.onion ? "peer-onion" : ""}>
            <td className="mono peer-addr">
              {p.onion && <span className="onion-tag"><OnionIcon size={11} /></span>}
              <span className="peer-addr-txt">{p.onion ? trunc(p.addr, 10) : p.addr}{p.port ? ":" + p.port : ""}</span>
            </td>
            <td className="mono dim">{p.client}</td>
            <td className="num">{p.pct}%</td>
            <td className="num mono">{p.down ? fmtSpeed(p.down) : "—"}</td>
            <td className="num mono">{p.up ? fmtSpeed(p.up) : "—"}</td>
            <td className="mono dim peer-flags">{p.flags}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function PiecesTab({ t }) {
  const have = PIECES.filter((p) => p === 1).length;
  return (
    <div className="pieces-tab">
      <div className="pieces-legend">
        <span><span className="pc pc-1" /> have</span>
        <span><span className="pc pc-2" /> downloading</span>
        <span><span className="pc pc-0" /> missing</span>
        <span className="pl-spacer" />
        <span className="mono dim">{have} / {PIECES.length} pieces · 256 KB each</span>
      </div>
      <PieceGrid pieces={PIECES} />
    </div>
  );
}

function SourcesTab() {
  return (
    <div className="sources-tab">
      {SOURCES.map((s, i) => (
        <div className="source-row" key={i}>
          <SourceChip kind={s.kind} />
          <span className="src-label mono">{s.label}</span>
          <span className="src-detail dim">{s.detail}</span>
          <span className="src-state">
            <span className="src-state-dot" /> {s.interval}
          </span>
        </div>
      ))}
      <div className="sources-note">
        Peers discovered across <strong>3 sources</strong>. With a proxy or Tor route set, UDP trackers and DHT are disabled — Nostr peer-announce keeps working over the tunnel.
      </div>
    </div>
  );
}

function FilesTab() {
  return (
    <table className="files-table">
      <thead>
        <tr><th>File</th><th className="num">Size</th><th className="num">Done</th><th>Priority</th></tr>
      </thead>
      <tbody>
        {FILES.map((f, i) => (
          <tr key={i}>
            <td className="file-name"><Icon name="file" size={14} style={{ color: "var(--fg-faint)" }} /><span className="mono">{f.name}</span></td>
            <td className="num mono">{fmtBytes(f.size)}</td>
            <td className="num">{f.pct}%</td>
            <td><span className={"prio prio-" + f.prio}>{f.prio}</span></td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function TransferRow({ t, expanded, onToggle }) {
  const meta = t.status === "metadata";
  return (
    <div className={"trow-wrap" + (expanded ? " expanded" : "")}>
      <div className="trow" onClick={onToggle}>
        <span className="trow-chev"><Icon name="chevron" size={15} /></span>
        <div className="trow-main">
          <div className="trow-line1">
            <RouteBadge route={t.route} size="sm" />
            <span className="trow-name mono">{t.name}</span>
            <StatusPill status={t.status} />
          </div>
          <div className="trow-prog">
            <ProgressBar pct={t.pct} status={t.status} />
            <span className="trow-pct mono">{meta ? "fetching metadata\u2026" : t.pct + "%"}</span>
          </div>
        </div>
        <div className="trow-stat">
          <span className="ts-val mono">{fmtBytes(t.size)}</span>
          <span className="ts-lbl">size</span>
        </div>
        <div className="trow-stat">
          <span className="ts-val mono dl">{t.down ? fmtSpeed(t.down) : "—"}</span>
          <span className="ts-lbl">{"\u2193"} down</span>
        </div>
        <div className="trow-stat">
          <span className="ts-val mono ul">{t.up ? fmtSpeed(t.up) : "—"}</span>
          <span className="ts-lbl">{"\u2191"} up</span>
        </div>
        <div className="trow-stat">
          <span className="ts-val mono">{t.eta}</span>
          <span className="ts-lbl">eta</span>
        </div>
        <div className="trow-stat">
          <span className="ts-val mono">{t.peers}</span>
          <span className="ts-lbl">peers</span>
        </div>
      </div>
      {expanded && <DetailTabs t={t} />}
    </div>
  );
}

function TransfersScreen({ openAdd }) {
  const [expanded, setExpanded] = React.useState("t1");
  const [filter, setFilter] = React.useState("all");
  const counts = {
    all: TRANSFERS.length,
    downloading: TRANSFERS.filter((t) => t.status === "downloading" || t.status === "metadata").length,
    seeding: TRANSFERS.filter((t) => t.status === "seeding").length,
    complete: TRANSFERS.filter((t) => t.status === "complete").length,
  };
  const rows = TRANSFERS.filter((t) => {
    if (filter === "all") return true;
    if (filter === "downloading") return t.status === "downloading" || t.status === "metadata" || t.status === "stalled";
    if (filter === "seeding") return t.status === "seeding";
    if (filter === "complete") return t.status === "complete";
    return true;
  });
  const totalDown = TRANSFERS.reduce((a, t) => a + t.down, 0);
  const totalUp = TRANSFERS.reduce((a, t) => a + t.up, 0);

  return (
    <div className="screen">
      <div className="topbar">
        <div className="topbar-l">
          <h1 className="screen-title">Transfers</h1>
          <div className="seg">
            {[["all", "All"], ["downloading", "Active"], ["seeding", "Seeding"], ["complete", "Done"]].map(([id, l]) => (
              <button key={id} className={"seg-btn" + (filter === id ? " active" : "")} onClick={() => setFilter(id)}>
                {l}<span className="seg-count">{counts[id]}</span>
              </button>
            ))}
          </div>
        </div>
        <div className="topbar-r">
          <div className="rate-readout">
            <span className="mono dl">{"\u2193"} {fmtSpeed(totalDown)}</span>
            <span className="mono ul">{"\u2191"} {fmtSpeed(totalUp)}</span>
          </div>
          <button className="btn btn-primary" onClick={openAdd}>
            <Icon name="plus" size={15} stroke={2} /> Add
          </button>
        </div>
      </div>

      <div className="content">
        <div className="trow-head">
          <span className="th-chev" />
          <span className="th-name">Name</span>
          <span className="th-stat">Size</span>
          <span className="th-stat">Down</span>
          <span className="th-stat">Up</span>
          <span className="th-stat">ETA</span>
          <span className="th-stat">Peers</span>
        </div>
        <div className="trow-list">
          {rows.map((t) => (
            <TransferRow key={t.id} t={t} expanded={expanded === t.id}
              onToggle={() => setExpanded(expanded === t.id ? null : t.id)} />
          ))}
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { TransfersScreen });
