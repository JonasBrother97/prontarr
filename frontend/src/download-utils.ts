export type StatusFilter =
  "all" | "downloading" | "paused" | "completed" | "review";
export type SortOrder = "original" | "name" | "speed" | "size" | "progress";
export const isView = (v: unknown): v is "arr" | "torrents" =>
  v === "arr" || v === "torrents";
export const isStatusFilter = (v: unknown): v is StatusFilter =>
  ["all", "downloading", "paused", "completed", "review"].includes(v as string);
export const isSortOrder = (v: unknown): v is SortOrder =>
  ["original", "name", "speed", "size", "progress"].includes(v as string);
export type SortableTorrent = {
  name: string;
  state: string;
  progress: number;
  bytes: number;
  download_speed: number;
};
export function normalizeSearch(text: string) {
  return text
    .normalize("NFD")
    .replace(/\p{Diacritic}/gu, "")
    .toLowerCase()
    .trim();
}
export function matchesStatus(
  torrent: SortableTorrent | null,
  status: StatusFilter,
  advice?: string,
) {
  if (status === "all") return true;
  if (status === "review")
    return advice === "needs_review" || advice === "consider_compact";
  if (!torrent) return false;
  const paused = /^(stopped|paused)/.test(torrent.state);
  if (status === "paused") return paused;
  if (status === "completed") return torrent.progress >= 1;
  return (
    torrent.progress < 1 &&
    !paused &&
    !["error", "missingFiles", "unknown"].includes(torrent.state)
  );
}
export function orderRows<T>(
  rows: readonly T[],
  order: SortOrder,
  title: (row: T) => string,
  torrent: (row: T) => SortableTorrent | null,
): T[] {
  if (order === "original") return [...rows];
  return [...rows].sort((a, b) => {
    if (order === "name")
      return title(a).localeCompare(title(b), "pt-BR", {
        numeric: true,
        sensitivity: "base",
      });
    const ta = torrent(a),
      tb = torrent(b);
    if (!ta) return tb ? 1 : 0;
    if (!tb) return -1;
    if (order === "speed") return tb.download_speed - ta.download_speed;
    if (order === "size") return tb.bytes - ta.bytes;
    return ta.progress - tb.progress;
  });
}
export function freshness(observedAt: number, now: number) {
  const seconds = Math.max(0, Math.floor((now - observedAt) / 1000));
  if (observedAt - now > 60_000)
    return { stale: true, label: "Confira o relógio do servidor" };
  return {
    stale: seconds >= 60,
    label:
      seconds < 60
        ? "Dados recentes"
        : seconds < 3600
          ? `Dados de ${Math.floor(seconds / 60)} min atrás`
          : `Dados de ${Math.floor(seconds / 3600)} h atrás`,
  };
}
