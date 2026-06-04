// Stroke-glyph icons, ported from the prototype's components.jsx.
import React from "react";

const ICONS: Record<string, string> = {
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
  trash: "M5 7h14M9 7V5h6v2M6 7l1 13h10l1-13",
};

export function Icon({
  name,
  size = 16,
  stroke = 1.7,
  style,
}: {
  name: string;
  size?: number;
  stroke?: number;
  style?: React.CSSProperties;
}) {
  const d = ICONS[name];
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={stroke}
      strokeLinecap="round"
      strokeLinejoin="round"
      style={{ flex: "0 0 auto", display: "block", ...style }}
    >
      <path d={d} />
    </svg>
  );
}

// Tor onion = concentric rings.
export function OnionIcon({ size = 14 }: { size?: number }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      style={{ flex: "0 0 auto", display: "block" }}
    >
      <circle cx="12" cy="12" r="8.5" />
      <circle cx="12" cy="12" r="5" />
      <circle cx="12" cy="12" r="1.6" fill="currentColor" stroke="none" />
    </svg>
  );
}
