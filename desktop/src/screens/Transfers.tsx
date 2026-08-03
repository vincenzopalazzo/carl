import { useState } from "react";
import { Icon } from "../components/icons";
import {
  RouteBadge,
  StatusPill,
  ProgressBar,
  PieceGrid,
  CopyField,
  SourceChip,
} from "../components/atoms";
import { fmtBytes, fmtSpeed } from "../components/format";
import { useCarl } from "../api/store";
import type { SourceKind, Status, Transfer } from "../api/types";

type Filter = "all" | "downloading" | "seeding" | "complete";

// Statuses that count as an in-progress ("Active") download — everything that
// isn't seeding or complete, including the metadata/connecting/no-peers phases.
const ACTIVE_STATUSES: Status[] = [
  "downloading",
  "metadata",
  "stalled",
  "connecting",
  "no_peers",
];
const isActive = (s: Status) => ACTIVE_STATUSES.includes(s);

// The daemon serves transfer-level state; per-piece detail isn't exposed yet
// (see docs/daemon-api.md). Derive a have/missing heatmap from the percentage
// so the Pieces tab reflects real progress without fabricating peer data.
function derivePieces(pct: number, n = 240): number[] {
  const have = Math.floor((pct / 100) * n);
  return Array.from({ length: n }, (_, i) => {
    if (i < have) return 1;
    if (i < have + 5 && pct < 100) return i % 2 === 0 ? 2 : 0;
    return 0;
  });
}

const SOURCE_LABELS: Record<SourceKind, string> = {
  tracker: "BitTorrent trackers",
  dht: "Distributed Hash Table",
  nostr: "Nostr peer-announce (NIP-35)",
};

function DetailTabs({ t }: { t: Transfer }) {
  const { removeTransfer } = useCarl();
  const [tab, setTab] = useState<"peers" | "pieces" | "sources" | "files">(
    "pieces",
  );
  const pieces = derivePieces(t.pct);
  const have = pieces.filter((p) => p === 1).length;

  return (
    <div className="detail">
      <div className="detail-tabs">
        {(
          [
            ["peers", "Peers", t.peers],
            ["pieces", "Pieces", null],
            ["sources", "Sources", t.sources.length],
            ["files", "Files", null],
          ] as const
        ).map(([id, label, count]) => (
          <button
            key={id}
            className={"dtab" + (tab === id ? " active" : "")}
            onClick={() => setTab(id)}
          >
            {label}
            {count != null && <span className="dtab-count">{count}</span>}
          </button>
        ))}
        <span style={{ flex: 1 }} />
        <button
          className="dtab"
          title="Remove transfer"
          onClick={() => removeTransfer(t.id)}
          style={{ color: "var(--danger)" }}
        >
          <Icon name="trash" size={14} /> Remove
        </button>
      </div>
      <div className="detail-body">
        {tab === "pieces" && (
          <div className="pieces-tab">
            <div className="pieces-legend">
              <span>
                <span className="pc pc-1" /> have
              </span>
              <span>
                <span className="pc pc-2" /> downloading
              </span>
              <span>
                <span className="pc pc-0" /> missing
              </span>
              <span className="pl-spacer" />
              <span className="mono dim">
                {have} / {pieces.length} · {t.pct}%
              </span>
            </div>
            <PieceGrid pieces={pieces} />
          </div>
        )}

        {tab === "sources" && (
          <div className="sources-tab">
            {t.sources.map((kind, i) => (
              <div className="source-row" key={i}>
                <SourceChip kind={kind} />
                <span className="src-label mono">{SOURCE_LABELS[kind]}</span>
                <span className="src-detail dim" />
                <span className="src-state">
                  <span className="src-state-dot" /> active
                </span>
              </div>
            ))}
            <div className="sources-note">
              Peers discovered across <strong>{t.sources.length}</strong>{" "}
              source{t.sources.length === 1 ? "" : "s"}. With a proxy or Tor
              route set, UDP trackers and DHT are disabled — Nostr peer-announce
              keeps working over the tunnel.
            </div>
          </div>
        )}

        {tab === "peers" && (
          <div className="sources-note">
            {t.peers} peer{t.peers === 1 ? "" : "s"} connected. Per-peer rows
            (address, client, rates, <span className="mono">.onion</span> flag)
            aren't exposed by the daemon yet — that needs a session-published
            snapshot (tracked in <span className="mono">docs/daemon-api.md</span>
            ).
          </div>
        )}

        {tab === "files" &&
          (t.fileRows.length > 0 ? (
            <table className="files-table">
              <thead>
                <tr>
                  <th>File</th>
                  <th className="num">Size</th>
                  <th className="num">Done</th>
                  <th>Priority</th>
                </tr>
              </thead>
              <tbody>
                {t.fileRows.map((f, i) => (
                  <tr key={i}>
                    <td className="file-name">
                      <Icon
                        name="file"
                        size={14}
                        style={{ color: "var(--fg-faint)" }}
                      />
                      <span className="mono">{f.name}</span>
                    </td>
                    <td className="num mono">{fmtBytes(f.size)}</td>
                    <td className="num">{f.pct}%</td>
                    <td>
                      <span className={"prio prio-" + f.prio}>{f.prio}</span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : (
            <div className="sources-note">
              {t.size != null
                ? `Total size: ${fmtBytes(t.size)}.`
                : "No file info yet."}
            </div>
          ))}

        <div style={{ marginTop: 14 }}>
          <CopyField value={t.magnet || `magnet:?xt=urn:btih:${t.hash}`} full />
        </div>
      </div>
    </div>
  );
}

function TransferRow({
  t,
  expanded,
  onToggle,
}: {
  t: Transfer;
  expanded: boolean;
  onToggle: () => void;
}) {
  // Phase label shown next to the progress bar. The metadata phase reports
  // BEP 9 piece progress when a peer has told us the size; connecting/no-peers
  // explain a stall instead of a misleading "fetching metadata…".
  const progressLabel = (() => {
    switch (t.status) {
      case "metadata":
        return t.metaTotal > 0
          ? `fetching metadata · ${t.metaHave}/${t.metaTotal}`
          : "fetching metadata…";
      case "connecting":
        return "connecting…";
      case "no_peers":
        return "no peers found";
      default:
        return t.pct + "%";
    }
  })();
  return (
    <div className={"trow-wrap" + (expanded ? " expanded" : "")}>
      <div className="trow" onClick={onToggle}>
        <span className="trow-chev">
          <Icon name="chevron" size={15} />
        </span>
        <div className="trow-main">
          <div className="trow-line1">
            <RouteBadge route={t.route} size="sm" />
            <span className="trow-name mono">{t.name}</span>
            <StatusPill status={t.status} />
          </div>
          <div className="trow-prog">
            <ProgressBar pct={t.pct} status={t.status} />
            <span className="trow-pct mono">{progressLabel}</span>
          </div>
        </div>
        <div className="trow-stat">
          <span className="ts-val mono">{fmtBytes(t.size)}</span>
          <span className="ts-lbl">size</span>
        </div>
        <div className="trow-stat">
          <span className="ts-val mono dl">
            {t.down ? fmtSpeed(t.down) : "—"}
          </span>
          <span className="ts-lbl">↓ down</span>
        </div>
        <div className="trow-stat">
          <span className="ts-val mono ul">{t.up ? fmtSpeed(t.up) : "—"}</span>
          <span className="ts-lbl">↑ up</span>
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

export function TransfersScreen({ openAdd }: { openAdd: () => void }) {
  const { state } = useCarl();
  const transfers = state.transfers;
  const [expanded, setExpanded] = useState<string | null>(null);
  const [filter, setFilter] = useState<Filter>("all");

  const counts: Record<Filter, number> = {
    all: transfers.length,
    downloading: transfers.filter((t) => isActive(t.status)).length,
    seeding: transfers.filter((t) => t.status === "seeding").length,
    complete: transfers.filter((t) => t.status === "complete").length,
  };
  const rows = transfers.filter((t) => {
    if (filter === "all") return true;
    if (filter === "downloading") return isActive(t.status);
    if (filter === "seeding") return t.status === "seeding";
    if (filter === "complete") return t.status === "complete";
    return true;
  });
  const totalDown = transfers.reduce((a, t) => a + t.down, 0);
  const totalUp = transfers.reduce((a, t) => a + t.up, 0);

  return (
    <div className="screen">
      <div className="topbar">
        <div className="topbar-l">
          <h1 className="screen-title">Transfers</h1>
          <div className="seg">
            {(
              [
                ["all", "All"],
                ["downloading", "Active"],
                ["seeding", "Seeding"],
                ["complete", "Done"],
              ] as const
            ).map(([id, l]) => (
              <button
                key={id}
                className={"seg-btn" + (filter === id ? " active" : "")}
                onClick={() => setFilter(id)}
              >
                {l}
                <span className="seg-count">{counts[id]}</span>
              </button>
            ))}
          </div>
        </div>
        <div className="topbar-r">
          <div className="rate-readout">
            <span className="mono dl">↓ {fmtSpeed(totalDown)}</span>
            <span className="mono ul">↑ {fmtSpeed(totalUp)}</span>
          </div>
          <button className="btn btn-primary" onClick={openAdd}>
            <Icon name="plus" size={15} stroke={2} /> Add
          </button>
        </div>
      </div>

      <div className="content">
        {rows.length === 0 ? (
          <div className="empty">
            <div className="empty-glyph">
              <Icon name="transfers" size={26} />
            </div>
            <div className="empty-title">No transfers yet</div>
            <div className="empty-sub">
              Paste a magnet link or .torrent with <strong>Add</strong>, or find
              one over Nostr in <strong>Discover</strong>.
            </div>
          </div>
        ) : (
          <>
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
                <TransferRow
                  key={t.id}
                  t={t}
                  expanded={expanded === t.id}
                  onToggle={() =>
                    setExpanded(expanded === t.id ? null : t.id)
                  }
                />
              ))}
            </div>
          </>
        )}
      </div>
    </div>
  );
}
