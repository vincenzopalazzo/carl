// settings.jsx — Settings screen

function LeakCheck({ route }) {
  const safe = route !== "direct";
  return (
    <div className={"leak-check " + (safe ? "lc-safe" : "lc-warn")}>
      <span className="lc-dot" />
      <div className="lc-body">
        <div className="lc-title">
          {safe ? "Leak check passed" : "Direct connection — IP exposed"}
        </div>
        <div className="lc-detail mono">
          {route === "tor" && "exit via 127.0.0.1:9050 · circuit OK · DNS over Tor"}
          {route === "proxy" && "all traffic via socks5h://127.0.0.1:9050 · DNS proxied"}
          {route === "direct" && "188.40.62.17 visible to trackers, DHT & peers"}
        </div>
      </div>
      <button className="link-btn">re-test</button>
    </div>
  );
}

function SettingsScreen() {
  const [route, setRoute] = React.useState("tor");
  const [relays, setRelays] = React.useState(
    "wss://relay.damus.io\nwss://nos.lol\nwss://relay.snort.social\nws://nostrr5h7k3xqp4nfz2vw9d6r8slmc1ojt.onion\nwss://relay.nostr.band"
  );
  return (
    <div className="screen">
      <div className="topbar">
        <div className="topbar-l"><h1 className="screen-title">Settings</h1></div>
      </div>

      <div className="content settings-content">
        {/* Anonymity */}
        <section className="sset">
          <div className="sset-head">
            <h2 className="sset-title">Anonymity</h2>
            <p className="sset-sub">How carl routes every connection. This is the single most important setting — it’s surfaced on every transfer.</p>
          </div>
          <div className="sset-body">
            <div className="route-radios">
              {[
                ["direct", "Direct", "Connect straight to peers. Fastest, no privacy.", "globe"],
                ["proxy", "SOCKS5 proxy", "Tunnel all traffic through a SOCKS5 proxy.", "shield"],
                ["tor", "Tor", "Route through the Tor network. Seed as a hidden service.", "onion"],
              ].map(([id, label, desc, icon]) => (
                <button key={id} className={"route-radio" + (route === id ? " active rt-" + id : "")} onClick={() => setRoute(id)}>
                  <span className="rr-radio" />
                  <span className="rr-ic">{icon === "onion" ? <OnionIcon size={16} /> : <Icon name={icon} size={16} />}</span>
                  <span className="rr-txt"><span className="rr-label">{label}</span><span className="rr-desc">{desc}</span></span>
                </button>
              ))}
            </div>

            {route !== "direct" && (
              <div className="field">
                <label className="field-label">SOCKS5 endpoint</label>
                <input className="text-input mono" defaultValue="socks5h://127.0.0.1:9050" />
                <span className="field-hint">socks5h:// resolves DNS through the proxy — prevents DNS leaks.</span>
              </div>
            )}

            <LeakCheck route={route} />

            <div className="callout-note">
              <Icon name="shield" size={15} stroke={1.8} />
              <span>With a proxy or Tor set, <strong>DHT, UDP trackers, and inbound connections are disabled by design</strong>. Peers are found over Nostr peer-announce.</span>
            </div>
          </div>
        </section>

        {/* Nostr */}
        <section className="sset">
          <div className="sset-head">
            <h2 className="sset-title">Nostr</h2>
            <p className="sset-sub">Relays power Discover and peer-announce. Your identity is a local keypair — there’s no account.</p>
          </div>
          <div className="sset-body">
            <div className="field">
              <label className="field-label">Relays <span className="fl-hint">one per line · wss:// or ws://&lt;onion&gt;</span></label>
              <textarea className="text-input mono relay-textarea" value={relays} onChange={(e) => setRelays(e.target.value)} rows={5} />
            </div>

            <div className="field">
              <label className="field-label">Identity</label>
              <div className="identity-card">
                <div className="id-row">
                  <span className="id-lbl">public key</span>
                  <CopyField value="npub1carl9x7k3qp4nfz2vw9d6r8slmc1ojtb5haeuyx0qprtkn9fwd2v3sba" label="npub1carl9x7k3qp4n…fwd2v3sba" />
                </div>
                <div className="id-row id-secret">
                  <span className="id-lbl">secret key</span>
                  <span className="id-hidden mono">nsec1 ••••••••••••••••••••••••••••••• <span className="id-hidden-note">never shown · stored in OS keychain</span></span>
                </div>
                <div className="id-actions">
                  <button className="btn btn-sm">Generate new</button>
                  <button className="btn btn-sm">Import nsec…</button>
                </div>
              </div>
            </div>

            <label className="chk chk-block">
              <input type="checkbox" defaultChecked /> <span>Publish a NIP-35 event when I add or seed a torrent</span>
            </label>
          </div>
        </section>

        {/* General */}
        <section className="sset">
          <div className="sset-head">
            <h2 className="sset-title">General</h2>
            <p className="sset-sub">Paths, ports and concurrency.</p>
          </div>
          <div className="sset-body">
            <div className="field">
              <label className="field-label">Default download folder</label>
              <div className="path-input">
                <Icon name="folder" size={15} style={{ color: "var(--fg-faint)" }} />
                <input className="text-input mono" defaultValue="~/Downloads/carl" />
                <button className="link-btn">choose…</button>
              </div>
            </div>
            <div className="field-grid">
              <div className="field">
                <label className="field-label">Listen port</label>
                <input className="text-input mono" defaultValue="51413" />
                <span className="field-hint">disabled while Tor / proxy is active</span>
              </div>
              <div className="field">
                <label className="field-label">Max active transfers</label>
                <input className="text-input mono" defaultValue="8" />
              </div>
              <div className="field">
                <label className="field-label">Per-torrent peer limit</label>
                <input className="text-input mono" defaultValue="60" />
              </div>
            </div>
          </div>
        </section>
      </div>
    </div>
  );
}

Object.assign(window, { SettingsScreen });
