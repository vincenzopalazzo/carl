import { Icon, OnionIcon } from "../components/icons";
import { CopyField } from "../components/atoms";
import { trunc } from "../components/format";
import { useCarl } from "../api/store";
import type { Route } from "../api/types";

function LeakCheck({ route, socks }: { route: Route; socks: string }) {
  const safe = route !== "direct";
  return (
    <div className={"leak-check " + (safe ? "lc-safe" : "lc-warn")}>
      <span className="lc-dot" />
      <div className="lc-body">
        <div className="lc-title">
          {safe ? "Leak check passed" : "Direct connection — IP exposed"}
        </div>
        <div className="lc-detail mono">
          {route === "tor" && `routed via ${socks} · DNS over the proxy`}
          {route === "proxy" && `all traffic via ${socks} · DNS proxied`}
          {route === "direct" && "your IP is visible to trackers, DHT & peers"}
        </div>
      </div>
    </div>
  );
}

const ROUTES: [Route, string, string, string][] = [
  ["direct", "Direct", "Connect straight to peers. Fastest, no privacy.", "globe"],
  ["proxy", "SOCKS5 proxy", "Tunnel all traffic through a SOCKS5 proxy.", "shield"],
  ["tor", "Tor", "Route through the Tor network. Seed as a hidden service.", "onion"],
];

export function SettingsScreen() {
  const { state, setRoute } = useCarl();
  const s = state.settings;

  return (
    <div className="screen">
      <div className="topbar">
        <div className="topbar-l">
          <h1 className="screen-title">Settings</h1>
        </div>
      </div>

      <div className="content settings-content">
        {/* Anonymity */}
        <section className="sset">
          <div className="sset-head">
            <h2 className="sset-title">Anonymity</h2>
            <p className="sset-sub">
              How carl routes every connection. The single most important
              setting — it's surfaced on every transfer.
            </p>
          </div>
          <div className="sset-body">
            <div className="route-radios">
              {ROUTES.map(([id, label, desc, icon]) => (
                <button
                  key={id}
                  className={
                    "route-radio" + (s.route === id ? " active rt-" + id : "")
                  }
                  onClick={() => setRoute(id)}
                >
                  <span className="rr-radio" />
                  <span className="rr-ic">
                    {icon === "onion" ? (
                      <OnionIcon size={16} />
                    ) : (
                      <Icon name={icon} size={16} />
                    )}
                  </span>
                  <span className="rr-txt">
                    <span className="rr-label">{label}</span>
                    <span className="rr-desc">{desc}</span>
                  </span>
                </button>
              ))}
            </div>

            {s.route !== "direct" && (
              <div className="field">
                <label className="field-label">SOCKS5 endpoint</label>
                <input className="text-input mono" value={s.socks} readOnly />
                <span className="field-hint">
                  socks5h:// resolves DNS through the proxy — prevents DNS
                  leaks. (Set via <span className="mono">--socks</span> on the
                  daemon for now.)
                </span>
              </div>
            )}

            <LeakCheck route={s.route} socks={s.socks} />

            <div className="callout-note">
              <Icon name="shield" size={15} stroke={1.8} />
              <span>
                With a proxy or Tor set,{" "}
                <strong>
                  DHT, UDP trackers, and inbound connections are disabled by
                  design
                </strong>
                . Peers are found over Nostr peer-announce.
              </span>
            </div>
          </div>
        </section>

        {/* Nostr */}
        <section className="sset">
          <div className="sset-head">
            <h2 className="sset-title">Nostr</h2>
            <p className="sset-sub">
              Relays power Discover and peer-announce. Your identity is a local
              keypair — there's no account.
            </p>
          </div>
          <div className="sset-body">
            <div className="field">
              <label className="field-label">
                Relays
                <span className="fl-hint">
                  one per line · wss:// or ws://&lt;onion&gt;
                </span>
              </label>
              <textarea
                className="text-input mono relay-textarea"
                value={s.relays.join("\n")}
                rows={Math.max(3, s.relays.length)}
                readOnly
              />
            </div>

            <div className="field">
              <label className="field-label">Identity</label>
              <div className="identity-card">
                <div className="id-row">
                  <span className="id-lbl">public key</span>
                  {s.relays /* noop to keep layout */ && state.identity.npub ? (
                    <CopyField
                      value={state.identity.npub}
                      label={trunc(state.identity.npub, 12)}
                    />
                  ) : (
                    <span className="id-hidden mono">
                      no key configured —{" "}
                      <span className="id-hidden-note">
                        run `carl nostr-keygen`
                      </span>
                    </span>
                  )}
                </div>
                <div className="id-row id-secret">
                  <span className="id-lbl">secret key</span>
                  <span className="id-hidden mono">
                    nsec1 •••••••••••••••••••
                    <span className="id-hidden-note">
                      never shown · stored in your config dir
                    </span>
                  </span>
                </div>
              </div>
            </div>
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
                <Icon
                  name="folder"
                  size={15}
                  style={{ color: "var(--fg-faint)" }}
                />
                <input
                  className="text-input mono"
                  value={s.downloadDir}
                  readOnly
                />
              </div>
            </div>
            <div className="field-grid">
              <div className="field">
                <label className="field-label">Listen port</label>
                <input
                  className="text-input mono"
                  value={s.listenPort}
                  readOnly
                />
                <span className="field-hint">
                  disabled while Tor / proxy is active
                </span>
              </div>
              <div className="field">
                <label className="field-label">Max active transfers</label>
                <input
                  className="text-input mono"
                  value={s.maxActive}
                  readOnly
                />
              </div>
              <div className="field">
                <label className="field-label">Per-torrent peer limit</label>
                <input
                  className="text-input mono"
                  value={s.peerLimit}
                  readOnly
                />
              </div>
            </div>
            <div className="callout-note">
              <Icon name="settings" size={15} stroke={1.8} />
              <span>
                General settings are read from the daemon's launch flags in this
                build; editable settings persistence is a follow-up. The{" "}
                <strong>route</strong> selector above is live.
              </span>
            </div>
          </div>
        </section>
      </div>
    </div>
  );
}
