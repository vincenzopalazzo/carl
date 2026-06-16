// addmodal.jsx — Add-transfer modal

function AddModal({ onClose }) {
  const [tab, setTab] = React.useState("magnet"); // magnet | file | url
  const [val, setVal] = React.useState("");
  const [useNostr, setUseNostr] = React.useState(true);
  const [route, setRoute] = React.useState("tor");
  const [dragOver, setDragOver] = React.useState(false);
  const [dropped, setDropped] = React.useState(null);

  const canAdd = (tab === "magnet" && val.trim()) || (tab === "url" && val.trim()) || (tab === "file" && dropped);

  return (
    <div className="modal-scrim" onClick={onClose}>
      <div className="modal add-modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-head">
          <h2 className="modal-title">Add transfer</h2>
          <button className="icon-btn" onClick={onClose}><Icon name="close" size={16} /></button>
        </div>

        <div className="modal-body">
          <div className="add-tabs">
            {[["magnet", "Magnet link"], ["file", ".torrent file"], ["url", "HTTP URL"]].map(([id, l]) => (
              <button key={id} className={"add-tab" + (tab === id ? " active" : "")} onClick={() => setTab(id)}>{l}</button>
            ))}
          </div>

          {tab === "magnet" && (
            <div className="field">
              <input className="text-input mono add-input" autoFocus value={val} onChange={(e) => setVal(e.target.value)}
                placeholder="magnet:?xt=urn:btih:…" />
              <span className="field-hint">Paste a magnet URI. The info-hash is parsed and verified locally.</span>
            </div>
          )}

          {tab === "url" && (
            <div className="field">
              <input className="text-input mono add-input" autoFocus value={val} onChange={(e) => setVal(e.target.value)}
                placeholder="https://example.org/file.torrent" />
              <span className="field-hint">carl fetches the .torrent over your selected route.</span>
            </div>
          )}

          {tab === "file" && (
            <div className={"dropzone add-drop" + (dragOver ? " over" : "")}
              onDragOver={(e) => { e.preventDefault(); setDragOver(true); }}
              onDragLeave={() => setDragOver(false)}
              onDrop={(e) => { e.preventDefault(); setDragOver(false); setDropped("downloaded.torrent"); }}
              onClick={() => setDropped("debian-12.5.0-amd64-netinst.iso.torrent")}>
              {dropped ? (
                <React.Fragment>
                  <span className="dz-icon"><Icon name="file" size={24} /></span>
                  <div className="dz-title mono">{dropped}</div>
                  <div className="dz-sub">Parsed · 3 files · 658 MB</div>
                </React.Fragment>
              ) : (
                <React.Fragment>
                  <span className="dz-icon"><Icon name="file" size={24} /></span>
                  <div className="dz-title">Drop a .torrent file here</div>
                  <div className="dz-sub">or click to browse</div>
                </React.Fragment>
              )}
            </div>
          )}

          <div className="add-options">
            <div className="field">
              <label className="field-label">Route</label>
              <div className="route-select route-select-lg">
                {[["direct", "Direct"], ["proxy", "Proxy"], ["tor", "Tor"]].map(([id, l]) => (
                  <button key={id} className={"rsl-btn" + (route === id ? " active rt-" + id : "")} onClick={() => setRoute(id)}>
                    {id === "tor" ? <OnionIcon size={12} /> : id === "proxy" ? <Icon name="shield" size={12} /> : <Icon name="globe" size={12} />}
                    {l}
                  </button>
                ))}
              </div>
              <span className="field-hint">{route === "direct" ? "Peers see your IP." : route === "proxy" ? "Tunneled via SOCKS5 · trackers & DHT off." : "Anonymous · trackers & DHT off · Nostr only."}</span>
            </div>

            <label className={"toggle-row" + (useNostr ? " on" : "")} onClick={() => setUseNostr(!useNostr)}>
              <span className="tr-switch"><span className="tr-knob" /></span>
              <span className="tr-txt">
                <span className="tr-label">--nostr · find peers via Nostr</span>
                <span className="tr-desc">Query relays for peer-announce events in addition to trackers/DHT.</span>
              </span>
            </label>
          </div>
        </div>

        <div className="modal-foot">
          <div className="modal-foot-route"><RouteBadge route={route} size="sm" />{useNostr && <SourceChip kind="nostr" />}</div>
          <div className="modal-foot-actions">
            <button className="btn" onClick={onClose}>Cancel</button>
            <button className={"btn btn-primary" + (canAdd ? "" : " disabled")} disabled={!canAdd} onClick={onClose}>
              <Icon name="plus" size={14} stroke={2.2} /> Add transfer
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { AddModal });
