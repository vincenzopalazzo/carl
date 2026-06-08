// Privacy-system atoms — ported from the prototype's components.jsx.
import { useState } from "react";
import { Icon, OnionIcon } from "./icons";
import type { Route, SourceKind, Status } from "../api/types";

const ROUTE_META: Record<Route, { label: string; cls: string; icon: string }> = {
  direct: { label: "clearnet", cls: "rt-clearnet", icon: "globe" },
  proxy: { label: "proxied", cls: "rt-proxy", icon: "shield" },
  tor: { label: "tor", cls: "rt-tor", icon: "onion" },
};

export function RouteBadge({
  route,
  size = "md",
}: {
  route: Route;
  size?: "sm" | "md";
}) {
  const m = ROUTE_META[route] ?? ROUTE_META.direct;
  return (
    <span
      className={"route-badge " + m.cls + " rb-" + size}
      title={"Routed: " + m.label}
    >
      {m.icon === "onion" ? (
        <OnionIcon size={size === "sm" ? 11 : 13} />
      ) : (
        <Icon name={m.icon} size={size === "sm" ? 11 : 13} stroke={1.7} />
      )}
      <span>{m.label}</span>
    </span>
  );
}

const STATUS_META: Record<Status, { label: string; cls: string }> = {
  downloading: { label: "downloading", cls: "st-down" },
  seeding: { label: "seeding", cls: "st-seed" },
  complete: { label: "complete", cls: "st-done" },
  metadata: { label: "metadata", cls: "st-meta" },
  stalled: { label: "stalled", cls: "st-stall" },
  connecting: { label: "connecting", cls: "st-meta" },
  no_peers: { label: "no peers", cls: "st-stall" },
};

export function StatusPill({ status }: { status: Status }) {
  const m = STATUS_META[status] ?? STATUS_META.downloading;
  return (
    <span className={"status-pill " + m.cls}>
      <span className="sp-dot" />
      {m.label}
    </span>
  );
}

export function ProgressBar({ pct, status }: { pct: number; status: Status }) {
  const stalled = status === "stalled" || status === "no_peers";
  // No real piece progress yet: show the indeterminate "meta" bar.
  const meta =
    status === "metadata" ||
    status === "connecting" ||
    status === "no_peers";
  return (
    <div
      className={
        "pbar" + (stalled ? " pbar-stall" : "") + (meta ? " pbar-meta" : "")
      }
    >
      <div className="pbar-fill" style={{ width: (meta ? 8 : pct) + "%" }} />
    </div>
  );
}

// piece heatmap state: 0 missing, 1 have, 2 downloading
export function PieceGrid({ pieces }: { pieces: number[] }) {
  return (
    <div className="piece-grid">
      {pieces.map((s, i) => (
        <span key={i} className={"pc pc-" + s} />
      ))}
    </div>
  );
}

const RELAY_STATE: Record<string, string> = {
  connected: "rl-on",
  connecting: "rl-pending",
  unreachable: "rl-off",
  configured: "rl-pending",
};

export function RelayDot({ state, net }: { state: string; net?: string }) {
  return (
    <span
      className={
        "relay-dot " +
        (RELAY_STATE[state] ?? "rl-off") +
        (net === "tor" ? " rl-tor" : "")
      }
    />
  );
}

export function CopyField({
  value,
  label,
  mono = true,
  full = false,
}: {
  value: string;
  label?: string;
  mono?: boolean;
  full?: boolean;
}) {
  const [copied, setCopied] = useState(false);
  const copy = () => {
    try {
      navigator.clipboard.writeText(value);
    } catch {
      /* clipboard unavailable */
    }
    setCopied(true);
    setTimeout(() => setCopied(false), 1300);
  };
  return (
    <button
      className={"copy-field" + (full ? " cf-full" : "")}
      onClick={copy}
      title="Copy"
    >
      <span className={"cf-val" + (mono ? " mono" : "")}>{label ?? value}</span>
      <span className="cf-ic">
        <Icon name={copied ? "check" : "copy"} size={13} stroke={1.8} />
      </span>
    </button>
  );
}

const SOURCE_META: Record<SourceKind, { label: string; cls: string }> = {
  tracker: { label: "tracker", cls: "src-tracker" },
  dht: { label: "DHT", cls: "src-dht" },
  nostr: { label: "nostr", cls: "src-nostr" },
};

export function SourceChip({ kind }: { kind: SourceKind }) {
  const m = SOURCE_META[kind] ?? SOURCE_META.tracker;
  return <span className={"source-chip " + m.cls}>{m.label}</span>;
}
