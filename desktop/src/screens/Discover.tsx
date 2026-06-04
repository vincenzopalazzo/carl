import { useState } from "react";
import { Icon, OnionIcon } from "../components/icons";
import { RelayDot, CopyField } from "../components/atoms";
import { fmtBytes, trunc } from "../components/format";
import { useCarl } from "../api/store";
import type { DiscoverResult, Relay, Route } from "../api/types";

function relayShortName(r: Relay): string {
  const host = r.url.replace(/^wss?:\/\//, "");
  if (r.net === "tor") return host.slice(0, 6) + "…onion";
  return host;
}

function RelayStrip() {
  const { state } = useCarl();
  const relays = state.relays;
  const connected = relays.filter((r) => r.state === "connected").length;
  return (
    <div className="relay-strip">
      <span className="rs-label">
        Relays
        <span className="rs-count">
          {connected}/{relays.length}
        </span>
      </span>
      <div className="rs-dots">
        {relays.map((r, i) => (
          <span className="rs-item" key={i} title={r.url + " · " + r.state}>
            <RelayDot state={r.state} net={r.net} />
            <span className="rs-host mono">{relayShortName(r)}</span>
          </span>
        ))}
      </div>
    </div>
  );
}

function DiscoverCard({
  d,
  added,
  onDownload,
}: {
  d: DiscoverResult;
  added: boolean;
  onDownload: (d: DiscoverResult) => void;
}) {
  const magnet = `magnet:?xt=urn:btih:${d.hash}`;
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
              <span
                className="sig sig-warn"
                title="Signature could not be verified"
              >
                unverified
              </span>
            )}
            <span className="dcard-author mono">{d.author}</span>
            <span className="dcard-age">{d.age}</span>
          </div>
        </div>
      </div>

      {d.desc && <p className="dcard-desc">{d.desc}</p>}

      <div className="dcard-meta">
        <div className="dm-item">
          <span className="dm-val mono">{fmtBytes(d.size)}</span>
          <span className="dm-lbl">size</span>
        </div>
        <div className="dm-item">
          <span className="dm-val mono">{d.files.toLocaleString()}</span>
          <span className="dm-lbl">files</span>
        </div>
        <div className="dm-item">
          <span className="dm-val mono">{d.trackers}</span>
          <span className="dm-lbl">trackers</span>
        </div>
        <div className="dm-item dm-hash">
          <CopyField value={magnet} label={"btih:" + trunc(d.hash, 7)} />
        </div>
      </div>

      <div className="dcard-foot">
        <div className="dcard-relays">
          <span className="dcr-lbl">found on</span>
          {d.relays.map((r, i) => (
            <span className="dcr-pill mono" key={i}>
              {r.includes("onion") ? (
                <OnionIcon size={10} />
              ) : (
                <span className="dcr-dot" />
              )}
              {r.replace(/^wss?:\/\//, "")}
            </span>
          ))}
        </div>
        <div className="dcard-actions">
          <CopyField value={magnet} label="copy magnet" mono={false} />
          <button
            className={"btn btn-primary btn-sm" + (added ? " btn-added" : "")}
            onClick={() => onDownload(d)}
            disabled={added}
          >
            <Icon name={added ? "check" : "download"} size={14} stroke={2} />
            {added ? "Added" : "Download"}
          </button>
        </div>
      </div>
    </div>
  );
}

export function DiscoverScreen() {
  const { search, addTransfer } = useCarl();
  const [q, setQ] = useState("");
  const [route, setRoute] = useState<Route>("tor");
  const [added, setAdded] = useState<Record<string, boolean>>({});
  const [results, setResults] = useState<DiscoverResult[]>([]);
  const [loading, setLoading] = useState(false);
  const [searched, setSearched] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function runSearch() {
    setLoading(true);
    setError(null);
    setSearched(true);
    try {
      setResults(await search(q.trim()));
    } catch (e) {
      setError(String(e));
      setResults([]);
    } finally {
      setLoading(false);
    }
  }

  async function download(d: DiscoverResult) {
    try {
      await addTransfer(`magnet:?xt=urn:btih:${d.hash}&dn=${encodeURIComponent(d.title)}`, route, true);
      setAdded((s) => ({ ...s, [d.id]: true }));
    } catch (e) {
      setError(String(e));
    }
  }

  return (
    <div className="screen">
      <div className="topbar topbar-discover">
        <div className="topbar-l">
          <h1 className="screen-title">Discover</h1>
        </div>
        <div className="topbar-r">
          <div
            className="route-select"
            title="Route queries & downloads through"
          >
            {(
              [
                ["direct", "Direct"],
                ["proxy", "Proxy"],
                ["tor", "Tor"],
              ] as const
            ).map(([id, l]) => (
              <button
                key={id}
                className={"rsl-btn" + (route === id ? " active rt-" + id : "")}
                onClick={() => setRoute(id)}
              >
                {l}
              </button>
            ))}
          </div>
        </div>
      </div>

      <div className="discover-searchbar">
        <div className="dsearch">
          <Icon
            name="search"
            size={17}
            style={{ color: "var(--fg-faint)" }}
          />
          <input
            value={q}
            onChange={(e) => setQ(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") runSearch();
            }}
            placeholder="Search torrents over Nostr — title or keyword (NIP-35). Enter to search."
            autoFocus
          />
          {q && (
            <button className="dsearch-clear" onClick={() => setQ("")}>
              <Icon name="close" size={13} />
            </button>
          )}
        </div>
        <RelayStrip />
      </div>

      <div className="content">
        <div className="discover-resultbar">
          <span className="dr-count mono">
            {loading ? "searching relays…" : `${results.length} events`}
          </span>
          <span className="dr-sort">
            sorted by <strong>recent</strong>
          </span>
        </div>
        <div className="dcard-list">
          {results.map((d) => (
            <DiscoverCard
              key={d.id}
              d={d}
              added={!!added[d.id]}
              onDownload={download}
            />
          ))}
          {!loading && results.length === 0 && (
            <div className="empty">
              <div className="empty-glyph">
                <Icon name="search" size={26} />
              </div>
              <div className="empty-title">
                {error
                  ? "Search failed"
                  : searched
                    ? "No matching events"
                    : "Search Nostr for torrents"}
              </div>
              <div className="empty-sub">
                {error
                  ? error
                  : searched
                    ? `No NIP-35 torrent events on your relays match “${q}”. Try a broader term or add relays in Settings.`
                    : "Type a query and press Enter. carl subscribes to your relays for signed (NIP-35) torrent events."}
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
