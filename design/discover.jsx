// discover.jsx — Discover (Nostr NIP-35 search)

function relayShortName(r) {
  const host = r.url.replace(/^wss?:\/\//, "");
  if (r.net === "tor") return host.slice(0, 6) + "\u2026onion";
  return host;
}
function RelayStrip() {
  const connected = RELAYS.filter((r) => r.state === "connected").length;
  return (
    <div className="relay-strip">
      <span className="rs-label">Relays<span className="rs-count">{connected}/{RELAYS.length}</span></span>
      <div className="rs-dots">
        {RELAYS.map((r, i) => (
          <span className="rs-item" key={i} title={r.url + " \u00b7 " + r.state}>
            <RelayDot state={r.state} net={r.net} />
            <span className="rs-host mono">{relayShortName(r)}</span>
          </span>
        ))}
      </div>
    </div>
  );
}

function DiscoverCard({ d, onDownload, added }) {
  return (
    <div className="dcard">
      <div className="dcard-head">
        <div className="dcard-title-wrap">
          <h3 className="dcard-title">{d.title}</h3>
          <div className="dcard-sig">
            {d.verified ? (
              <span className="sig sig-ok" title="Schnorr signature verified">
                <Icon name="check" size={12} stroke={2.2} /> signed
              </span>
            ) : (
              <span className="sig sig-warn" title="Signature could not be verified">unverified</span>
            )}
            <span className="dcard-author mono">{d.author}</span>
            <span className="dcard-age">{d.age}</span>
          </div>
        </div>
      </div>

      <p className="dcard-desc">{d.desc}</p>

      <div className="dcard-meta">
        <div className="dm-item"><span className="dm-val mono">{fmtBytes(d.size)}</span><span className="dm-lbl">size</span></div>
        <div className="dm-item"><span className="dm-val mono">{d.files.toLocaleString()}</span><span className="dm-lbl">files</span></div>
        <div className="dm-item"><span className="dm-val mono">{d.trackers}</span><span className="dm-lbl">trackers</span></div>
        <div className="dm-item dm-hash">
          <CopyField value={"magnet:?xt=urn:btih:" + d.hash} label={"btih:" + trunc(d.hash, 7)} />
        </div>
      </div>

      <div className="dcard-foot">
        <div className="dcard-relays">
          <span className="dcr-lbl">found on</span>
          {d.relays.map((r, i) => (
            <span className="dcr-pill mono" key={i}>
              {r.includes("onion") ? <OnionIcon size={10} /> : <span className="dcr-dot" />}
              {r.replace(/^wss?:\/\//, "").replace("ws://", "")}
            </span>
          ))}
        </div>
        <div className="dcard-actions">
          <CopyField value={"magnet:?xt=urn:btih:" + d.hash} label="copy magnet" mono={false} />
          <button className={"btn btn-primary btn-sm" + (added ? " btn-added" : "")} onClick={() => onDownload(d)} disabled={added}>
            <Icon name={added ? "check" : "download"} size={14} stroke={2} />
            {added ? "Added" : "Download"}
          </button>
        </div>
      </div>
    </div>
  );
}

function DiscoverScreen() {
  const [q, setQ] = React.useState("");
  const [route, setRoute] = React.useState("tor");
  const [added, setAdded] = React.useState({});
  const results = DISCOVER.filter((d) =>
    !q.trim() || d.title.toLowerCase().includes(q.toLowerCase()) || d.desc.toLowerCase().includes(q.toLowerCase())
  );
  return (
    <div className="screen">
      <div className="topbar topbar-discover">
        <div className="topbar-l">
          <h1 className="screen-title">Discover</h1>
        </div>
        <div className="topbar-r">
          <div className="route-select" title="Route queries & downloads through">
            {[["direct", "Direct"], ["proxy", "Proxy"], ["tor", "Tor"]].map(([id, l]) => (
              <button key={id} className={"rsl-btn" + (route === id ? " active rt-" + id : "")} onClick={() => setRoute(id)}>{l}</button>
            ))}
          </div>
        </div>
      </div>

      <div className="discover-searchbar">
        <div className="dsearch">
          <Icon name="search" size={17} style={{ color: "var(--fg-faint)" }} />
          <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search torrents over Nostr — title, info-hash, or keyword (NIP-35)" autoFocus />
          {q && <button className="dsearch-clear" onClick={() => setQ("")}><Icon name="close" size={13} /></button>}
        </div>
        <RelayStrip />
      </div>

      <div className="content">
        <div className="discover-resultbar">
          <span className="dr-count mono">{results.length} events</span>
          <span className="dr-sort">sorted by <strong>recent</strong></span>
        </div>
        <div className="dcard-list">
          {results.map((d) => (
            <DiscoverCard key={d.id} d={d} added={added[d.id]} onDownload={(x) => setAdded((s) => ({ ...s, [x.id]: true }))} />
          ))}
          {results.length === 0 && (
            <div className="empty">
              <div className="empty-glyph"><Icon name="search" size={26} /></div>
              <div className="empty-title">No matching events</div>
              <div className="empty-sub">No NIP-35 torrent events on your relays match “{q}”. Try a broader term or add more relays in Settings.</div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { DiscoverScreen, RelayStrip });
