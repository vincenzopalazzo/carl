// components.jsx — shared atoms for carl

// ---------- formatters ----------
function fmtBytes(b) {
  if (b == null) return "—";
  if (b === 0) return "0 B";
  const u = ["B", "KB", "MB", "GB", "TB"];
  const i = Math.floor(Math.log(b) / Math.log(1024));
  const n = b / Math.pow(1024, i);
  return (n >= 100 || i === 0 ? Math.round(n) : n.toFixed(n >= 10 ? 1 : 2)) + " " + u[i];
}
function fmtSpeed(b) {
  if (!b) return "—";
  return fmtBytes(b) + "/s";
}
function trunc(h, n = 8) {
  if (!h) return "";
  return h.slice(0, n) + "\u2026" + h.slice(-n);
}

// ---------- icons (simple stroke glyphs) ----------
const ICONS = {
  transfers: "M12 3v11m0 0 4-4m-4 4-4-4M5 19h14",
  discover: "M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14zM20 20l-3.5-3.5",
  seeding: "M12 21V10m0 0 4 4m-4-4-4 4M5 5h14",
  settings: "M5 7h14M5 12h14M5 17h14",
  chevron: "M9 6l6 6-6 6",
  plus: "M12 5v14M5 12h14",
  copy: "M9 9h9v11H9zM6 15H4V4h11v2",
  check: "M5 12l4 4 10-10",
  close: "M6 6l12 12M18 6L6 18",
  link: "M10 14a4 4 0 0 0 5.66 0l3-3a4 4 0 0 0-5.66-5.66l-1 1M14 10a4 4 0 0 0-5.66 0l-3 3a4 4 0 0 0 5.66 5.66l1-1",
  file: "M14 3v5h5M7 3h8l4 4v14H7z",
  shield: "M12 3l7 3v5c0 4.5-3 7.5-7 9-4-1.5-7-4.5-7-9V6z",
  drag: "M8 6h.01M8 12h.01M8 18h.01M14 6h.01M14 12h.01M14 18h.01",
  search: "M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14zM20 20l-3.5-3.5",
  globe: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM3 12h18M12 3c2.5 2.5 2.5 15 0 18M12 3c-2.5 2.5-2.5 15 0 18",
  download: "M12 3v11m0 0 4-4m-4 4-4-4M5 19h14",
  key: "M15 7a3 3 0 1 1-3 3l-7 7v2h2l1-1h2v-2h2l1-1",
  folder: "M3 7h6l2 2h10v10H3z",
  pulse: "M3 12h4l2-6 4 12 2-6h6",
};
function Icon({ name, size = 16, stroke = 1.7, style }) {
  const d = ICONS[name];
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none"
      stroke="currentColor" strokeWidth={stroke} strokeLinecap="round" strokeLinejoin="round"
      style={{ flex: "0 0 auto", display: "block", ...style }}>
      <path d={d} />
    </svg>
  );
}
// tor onion = concentric rings
function OnionIcon({ size = 14 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor"
      strokeWidth="1.6" style={{ flex: "0 0 auto", display: "block" }}>
      <circle cx="12" cy="12" r="8.5" />
      <circle cx="12" cy="12" r="5" />
      <circle cx="12" cy="12" r="1.6" fill="currentColor" stroke="none" />
    </svg>
  );
}

// ---------- route / privacy badge ----------
const ROUTE_META = {
  direct: { label: "clearnet", cls: "rt-clearnet", icon: "globe" },
  proxy: { label: "proxied", cls: "rt-proxy", icon: "shield" },
  tor: { label: "tor", cls: "rt-tor", icon: "onion" },
};
function RouteBadge({ route, size = "md" }) {
  const m = ROUTE_META[route] || ROUTE_META.direct;
  return (
    <span className={"route-badge " + m.cls + " rb-" + size} title={"Routed: " + m.label}>
      {m.icon === "onion" ? <OnionIcon size={size === "sm" ? 11 : 13} /> : <Icon name={m.icon} size={size === "sm" ? 11 : 13} stroke={1.7} />}
      <span>{m.label}</span>
    </span>
  );
}

// ---------- status pill ----------
const STATUS_META = {
  downloading: { label: "downloading", cls: "st-down" },
  seeding: { label: "seeding", cls: "st-seed" },
  complete: { label: "complete", cls: "st-done" },
  metadata: { label: "metadata", cls: "st-meta" },
  stalled: { label: "stalled", cls: "st-stall" },
};
function StatusPill({ status }) {
  const m = STATUS_META[status] || STATUS_META.downloading;
  return (
    <span className={"status-pill " + m.cls}>
      <span className="sp-dot" />
      {m.label}
    </span>
  );
}

// ---------- piece-progress bar (segmented) ----------
function ProgressBar({ pct, status }) {
  const stalled = status === "stalled";
  const meta = status === "metadata";
  return (
    <div className={"pbar" + (stalled ? " pbar-stall" : "") + (meta ? " pbar-meta" : "")}>
      <div className="pbar-fill" style={{ width: (meta ? 8 : pct) + "%" }} />
    </div>
  );
}

// ---------- piece-grid heatmap ----------
function PieceGrid({ pieces }) {
  return (
    <div className="piece-grid">
      {pieces.map((s, i) => (
        <span key={i} className={"pc pc-" + s} />
      ))}
    </div>
  );
}

// ---------- relay dot ----------
const RELAY_STATE = {
  connected: "rl-on",
  connecting: "rl-pending",
  unreachable: "rl-off",
};
function RelayDot({ state, net }) {
  return <span className={"relay-dot " + (RELAY_STATE[state] || "rl-off") + (net === "tor" ? " rl-tor" : "")} />;
}

// ---------- copyable mono value ----------
function CopyField({ value, label, mono = true, full = false }) {
  const [copied, setCopied] = React.useState(false);
  const copy = () => {
    try { navigator.clipboard.writeText(value); } catch (e) {}
    setCopied(true);
    setTimeout(() => setCopied(false), 1300);
  };
  return (
    <button className={"copy-field" + (full ? " cf-full" : "")} onClick={copy} title="Copy">
      <span className={"cf-val" + (mono ? " mono" : "")}>{label || value}</span>
      <span className="cf-ic">
        <Icon name={copied ? "check" : "copy"} size={13} stroke={1.8} />
      </span>
    </button>
  );
}

// ---------- generic small icon button ----------
function IconBtn({ icon, onClick, title, active }) {
  return (
    <button className={"icon-btn" + (active ? " active" : "")} onClick={onClick} title={title}>
      <Icon name={icon} size={15} />
    </button>
  );
}

// ---------- source chip (tracker / dht / nostr) ----------
const SOURCE_META = {
  tracker: { label: "tracker", cls: "src-tracker" },
  dht: { label: "DHT", cls: "src-dht" },
  nostr: { label: "nostr", cls: "src-nostr" },
};
function SourceChip({ kind }) {
  const m = SOURCE_META[kind] || SOURCE_META.tracker;
  return <span className={"source-chip " + m.cls}>{m.label}</span>;
}

Object.assign(window, {
  fmtBytes, fmtSpeed, trunc, Icon, OnionIcon, RouteBadge, StatusPill,
  ProgressBar, PieceGrid, RelayDot, CopyField, IconBtn, SourceChip,
  ROUTE_META, STATUS_META, SOURCE_META,
});
