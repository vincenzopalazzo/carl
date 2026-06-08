import { useEffect, useState } from "react";
import { Icon, OnionIcon } from "../components/icons";
import { CopyField } from "../components/atoms";
import { trunc } from "../components/format";
import { useCarl } from "../api/store";
import type { Route } from "../api/types";
import {
  cliStatus,
  installCli,
  uninstallCli,
  type CliStatus,
} from "../api/cli";

/** Command-line tools, Docker-style: symlink a PATH location to the bundled
 *  `carl` so the CLI tracks the app. System install (/usr/local/bin) needs a
 *  one-time password; user install (~/.local/bin) doesn't. */
function CliToolsSection() {
  const [status, setStatus] = useState<CliStatus | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function reload() {
    try {
      setStatus(await cliStatus());
    } catch (e) {
      setErr(String(e));
    }
  }
  useEffect(() => {
    reload();
  }, []);

  async function run(fn: () => Promise<unknown>) {
    setBusy(true);
    setErr(null);
    try {
      await fn();
      await reload();
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="sset">
      <div className="sset-head">
        <h2 className="sset-title">Command-line tools</h2>
        <p className="sset-sub">
          Install the <span className="mono">carl</span> CLI so it's available in
          your terminal. It's symlinked to this app, so it always matches the
          installed version.
        </p>
      </div>
      <div className="sset-body">
        {!status ? (
          <div className="field-hint">Checking…</div>
        ) : !status.available ? (
          <div className="callout-note">
            <Icon name="shield" size={15} stroke={1.8} />
            <span>
              The bundled CLI is only available in the packaged desktop app
              (this looks like a dev/browser session).
            </span>
          </div>
        ) : status.installed ? (
          <>
            <div className="leak-check lc-safe">
              <span className="lc-dot" />
              <div className="lc-body">
                <div className="lc-title">
                  CLI installed
                  {status.linkedToBundle
                    ? " · linked to this app"
                    : " · not linked to this app"}
                </div>
                <div className="lc-detail mono">{status.path}</div>
              </div>
            </div>
            {!status.linkedToBundle && (
              <div className="callout-note">
                <Icon name="shield" size={15} stroke={1.8} />
                <span>
                  This <span className="mono">carl</span> isn't a symlink to the
                  app — reinstall below to have it track app updates.
                </span>
              </div>
            )}
            <div className="id-actions">
              <button
                className="btn btn-sm"
                disabled={busy}
                onClick={() =>
                  run(() => installCli(status.path?.startsWith("/usr/") ?? true))
                }
              >
                <Icon name="check" size={13} stroke={2.2} />
                {busy ? "Working…" : "Reinstall"}
              </button>
              <button
                className="btn btn-sm"
                disabled={busy}
                onClick={() =>
                  run(() =>
                    uninstallCli(status.path?.startsWith("/usr/") ?? false),
                  )
                }
              >
                Remove
              </button>
            </div>
          </>
        ) : (
          <>
            <div className="field-hint">
              Not installed. Choose where to put the{" "}
              <span className="mono">carl</span> command:
            </div>
            <div className="id-actions">
              <button
                className="btn btn-sm btn-primary"
                disabled={busy}
                onClick={() => run(() => installCli(true))}
              >
                <Icon name="plus" size={13} stroke={2.2} />
                {busy ? "Working…" : "Install (system · /usr/local/bin)"}
              </button>
              <button
                className="btn btn-sm"
                disabled={busy}
                onClick={() => run(() => installCli(false))}
              >
                Install (user · ~/.local/bin)
              </button>
            </div>
            <span className="field-hint">
              System install asks for your password once. User install needs no
              password but only works if <span className="mono">~/.local/bin</span>{" "}
              is on your PATH.
            </span>
          </>
        )}
        {err && (
          <div className="callout-note" style={{ color: "var(--danger)" }}>
            <Icon name="close" size={15} stroke={1.8} />
            <span>{err}</span>
          </div>
        )}
      </div>
    </section>
  );
}

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
  const { state, setRoute, updateSettings } = useCarl();
  const s = state.settings;

  // Editable copies, re-seeded only when the server value actually changes (the
  // deps are strings, so the 1s state push doesn't clobber in-progress edits).
  const relaysJoined = s.relays.join("\n");
  const [dir, setDir] = useState(s.downloadDir);
  const [relaysText, setRelaysText] = useState(relaysJoined);
  const [savingDir, setSavingDir] = useState(false);
  const [savingRelays, setSavingRelays] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => setDir(s.downloadDir), [s.downloadDir]);
  useEffect(() => setRelaysText(relaysJoined), [relaysJoined]);

  const dirDirty = dir.trim() !== s.downloadDir && dir.trim().length > 0;
  const relaysDirty = relaysText !== relaysJoined;

  async function saveDir() {
    setSavingDir(true);
    setErr(null);
    try {
      await updateSettings({ downloadDir: dir.trim() });
    } catch (e) {
      setErr(String(e));
    } finally {
      setSavingDir(false);
    }
  }

  async function saveRelays() {
    setSavingRelays(true);
    setErr(null);
    try {
      const relays = relaysText
        .split("\n")
        .map((r) => r.trim())
        .filter((r) => r.length > 0);
      await updateSettings({ relays });
    } catch (e) {
      setErr(String(e));
    } finally {
      setSavingRelays(false);
    }
  }

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
                value={relaysText}
                rows={Math.max(3, relaysText.split("\n").length)}
                onChange={(e) => setRelaysText(e.target.value)}
                spellCheck={false}
              />
              <div className="id-actions">
                <button
                  className={
                    "btn btn-sm btn-primary" + (relaysDirty ? "" : " disabled")
                  }
                  disabled={!relaysDirty || savingRelays}
                  onClick={saveRelays}
                >
                  <Icon name="check" size={13} stroke={2.2} />
                  {savingRelays ? "Saving…" : "Save relays"}
                </button>
                {relaysDirty && (
                  <button
                    className="btn btn-sm"
                    onClick={() => setRelaysText(relaysJoined)}
                  >
                    Reset
                  </button>
                )}
              </div>
              <span className="field-hint">
                Saved to your carl config — search, peer-announce, and the CLI
                all use this list.
              </span>
            </div>

            <div className="field">
              <label className="field-label">Identity</label>
              <div className="identity-card">
                <div className="id-row">
                  <span className="id-lbl">public key</span>
                  {state.identity.npub ? (
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
                  value={dir}
                  onChange={(e) => setDir(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === "Enter" && dirDirty) saveDir();
                  }}
                  spellCheck={false}
                />
                <button
                  className="link-btn"
                  onClick={saveDir}
                  style={{ opacity: dirDirty ? 1 : 0.4 }}
                >
                  {savingDir ? "saving…" : "save"}
                </button>
              </div>
              <span className="field-hint">
                New transfers download here. Existing transfers keep their
                folder.
              </span>
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
            {err && (
              <div className="callout-note" style={{ color: "var(--danger)" }}>
                <Icon name="close" size={15} stroke={1.8} />
                <span>{err}</span>
              </div>
            )}
          </div>
        </section>

        {/* Command-line tools */}
        <CliToolsSection />
      </div>
    </div>
  );
}
