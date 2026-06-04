// Byte / speed / hash formatters — ported from the prototype's components.jsx.

export function fmtBytes(b: number | null | undefined): string {
  if (b == null) return "—";
  if (b === 0) return "0 B";
  const u = ["B", "KB", "MB", "GB", "TB"];
  const i = Math.floor(Math.log(b) / Math.log(1024));
  const n = b / Math.pow(1024, i);
  return (
    (n >= 100 || i === 0 ? Math.round(n) : n.toFixed(n >= 10 ? 1 : 2)) +
    " " +
    u[i]
  );
}

export function fmtSpeed(b: number | null | undefined): string {
  if (!b) return "—";
  return fmtBytes(b) + "/s";
}

export function trunc(h: string | null | undefined, n = 8): string {
  if (!h) return "";
  if (h.length <= n * 2 + 1) return h;
  return h.slice(0, n) + "…" + h.slice(-n);
}
