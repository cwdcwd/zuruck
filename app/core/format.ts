/**
 * Small formatting helpers, ported from scripts/status.sh:64-68 so the UI reads
 * the same as the terminal/HTML dashboards.
 */

/** Human-readable bytes: "0 B", "4.00 KiB", "33.80 GiB". */
export function human(bytes: number): string {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
  let b = bytes;
  let i = 0;
  while (b >= 1024 && i < units.length - 1) {
    b /= 1024;
    i++;
  }
  return i === 0 ? `${Math.round(b)} ${units[i]}` : `${b.toFixed(2)} ${units[i]}`;
}

/** Human-readable age: "12m ago", "3h 4m ago", "2d 6h ago". */
export function fmtAge(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m ago`;
  return `${Math.floor(s / 86400)}d ${Math.floor((s % 86400) / 3600)}h ago`;
}
