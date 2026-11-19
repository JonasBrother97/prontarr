import { t, locale } from "./i18n.ts";
import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import {
  Activity,
  Check,
  CircleHelp,
  RefreshCw,
  Search,
  ShieldCheck,
} from "lucide-react";
import { api } from "./api";
import { useStoredState, isShortText, isBoolean } from "./preferences";
import {
  isView,
  isStatusFilter,
  isSortOrder,
  matchesStatus,
  orderRows,
  normalizeSearch,
  freshness,
  type StatusFilter,
  type SortOrder,
} from "./download-utils";

type Torrent = {
  hash: string;
  name: string;
  state: string;
  progress: number;
  bytes: number;
  download_speed: number;
  seeds: number;
  eta_seconds: number | null;
};
type Item = {
  app: string;
  queue_id: number;
  season_number: number | null;
  episode_number: number | null;
  title: string;
  resolution: number;
  custom_format_score: number | null;
  status: string;
  has_file: boolean | null;
  file_id: number | null;
  advice: string;
  reason: string;
  torrent: Torrent | null;
};
type Service = {
  name: string;
  configured: boolean;
  connected: boolean;
  version: string | null;
  error_code: string | null;
  total_records: number;
  truncated: boolean;
};
type Observation = {
  observed_at_ms: number;
  services: Service[];
  items: Item[];
  torrents: Torrent[];
  live_actions_enabled: false;
};
const names: Record<string, string> = {
  radarr: "Radarr",
  sonarr: "Sonarr",
  qbittorrent: "qBittorrent",
};
const advice: Record<string, string> = {
  wait_for_import: "Wait for import",
  consider_compact: "Consider a compact copy",
  keep_upgrade: "Keep the watchable copy",
  respect_pause: "Respect pause",
  needs_review: "Review information",
};
const errors: Record<string, string> = {
  UpstreamUnauthorized: "Unauthorized. Check the API key or session.",
  UpstreamTimeout: "The service timed out.",
  UpstreamUnavailable: "The service did not respond. Check the connection.",
  UpstreamRedirectBlocked:
    "The service redirected the request. Check the direct API URL.",
  InvalidUpstreamCertificate:
    "The service TLS certificate could not be verified.",
  InvalidUpstreamResponse: "The service returned unexpected data.",
  ResponseTooLarge: "The response exceeded the safety limit.",
};
function size(n: number) {
  if (n <= 0) return "0 B";
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  const exponent = Math.min(Math.floor(Math.log(n) / Math.log(1024)), 4);
  return `${(n / 1024 ** exponent).toLocaleString(locale(), { maximumFractionDigits: 1 })} ${units[exponent]}`;
}
function eta(torrent: Torrent) {
  if (torrent.progress >= 1) return t("Downloaded");
  if (torrent.eta_seconds === null) return t("No estimate");
  const minutes = Math.max(1, Math.ceil(torrent.eta_seconds / 60));
  return minutes < 60
    ? `${minutes} min`
    : `${Math.floor(minutes / 60)}h ${minutes % 60}min`;
}
function Progress({ torrent }: { torrent: Torrent | null }) {
  if (!torrent) return <span className="muted">{t("No match")}</span>;
  return (
    <div className="progress-cell">
      <span>
        {(torrent.progress * 100).toFixed(1)}% <small>{eta(torrent)}</small>
      </span>
      <progress
        max={1}
        value={torrent.progress}
        aria-label={t("Progress for {{title}}", { title: torrent.name })}
      />
    </div>
  );
}
export function Live() {
  const [view, setView] = useStoredState(
    "download-view",
    "arr" as "arr" | "torrents",
    isView,
    "session",
  );
  const [filter, setFilter] = useStoredState(
    "download-filter",
    "",
    isShortText,
    "session",
  );
  const [statusFilter, setStatusFilter] = useStoredState(
    "download-status",
    "all" as StatusFilter,
    isStatusFilter,
    "session",
  );
  const [sortOrder, setSortOrder] = useStoredState(
    "download-sort",
    "original" as SortOrder,
    isSortOrder,
    "session",
  );
  const [autoRefresh, setAutoRefresh] = useStoredState(
    "download-auto-refresh",
    true,
    isBoolean,
  );
  const [now, setNow] = useState(Date.now);
  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 15_000);
    return () => window.clearInterval(timer);
  }, []);
  const [page, setPage] = useState(0);
  const configuration = useQuery({
    queryKey: ["connections"],
    queryFn: () =>
      api<{ items: { name: string; configured: boolean }[] }>("/connections"),
  });
  const observation = useQuery({
    queryKey: ["observation"],
    queryFn: () => api<Observation>("/observe", {}),
    enabled: autoRefresh,
    refetchInterval: autoRefresh ? 30_000 : false,
    refetchIntervalInBackground: false,
    gcTime: 30 * 60_000,
    retry: false,
  });
  const data = observation.data;
  const age = data ? freshness(data.observed_at_ms, now) : null;
  const effectiveStatus =
    view === "torrents" && statusFilter === "review" ? "all" : statusFilter;
  const search = normalizeSearch(filter);
  const services =
    data?.services ??
    configuration.data?.items.map((s) => ({
      ...s,
      connected: false,
      version: null,
      error_code: null,
      total_records: 0,
      truncated: false,
    })) ??
    [];
  const rows = orderRows(
    data?.items.filter(
      (item) =>
        normalizeSearch(item.title).includes(search) &&
        matchesStatus(item.torrent, effectiveStatus, item.advice),
    ) ?? [],
    sortOrder,
    (item) => item.title,
    (item) => item.torrent,
  );
  const torrents = orderRows(
    data?.torrents.filter(
      (torrent) =>
        normalizeSearch(torrent.name).includes(search) &&
        matchesStatus(torrent, effectiveStatus),
    ) ?? [],
    sortOrder,
    (torrent) => torrent.name,
    (torrent) => torrent,
  );
  const count = view === "arr" ? rows.length : torrents.length;
  const lastPage = Math.max(0, Math.ceil(count / 20) - 1);
  const currentPage = Math.min(page, lastPage);
  return (
    <>
      <section className="page-heading">
        <div>
          <span className="eyebrow">{t("OBSERVATION · LIVE DATA")}</span>
          <h1>{t("Download queue")}</h1>
          <p>
            {t(
              "View the queue and compare suggestions without changing any torrent.",
            )}
          </p>
        </div>
        <button
          className="primary"
          disabled={observation.isFetching}
          onClick={() => observation.refetch()}
        >
          <RefreshCw
            size={16}
            className={observation.isFetching ? "spin" : ""}
          />
          {observation.isFetching
            ? t("Querying…")
            : data
              ? t("Refresh observation")
              : t("Query services")}
        </button>
      </section>
      <div className="refresh-controls">
        <label className="checkbox">
          <input
            type="checkbox"
            checked={autoRefresh}
            onChange={(event) => setAutoRefresh(event.target.checked)}
          />
          {t("Refresh every 30 seconds")}
        </label>
        <span className="muted">
          {autoRefresh
            ? t("Pauses while the tab is hidden.")
            : t("Manual query; no commands change your downloads.")}
        </span>
      </div>
      {(configuration.error || observation.error) && (
        <p role="alert" className="error">
          {t((observation.error ?? configuration.error)?.message ?? "")}
          {data && t(" The data below comes from the last completed query.")}
        </p>
      )}
      <div className="service-grid">
        {services.map((service) => (
          <article className="card service-card" key={service.name}>
            <div className="service-name">
              <span className="service-icon">
                <Activity size={18} />
              </span>
              <h2>{names[service.name]}</h2>
              <span
                className={`dot ${service.connected && !age?.stale && !observation.isError ? "green" : ""}`}
              />
            </div>
            <p>
              {service.connected
                ? `${age?.stale || observation.isError ? t("At last query") : t("Connected")} · ${service.version}`
                : service.error_code
                  ? (t(errors[service.error_code] ?? service.error_code) ??
                    t("Failed to query the service."))
                  : service.configured
                    ? t("Configured · awaiting query")
                    : t("Connection not configured")}
            </p>
            <small>
              {t("Read only")}
              {service.connected &&
                ` · ${service.total_records} ${service.name === "qbittorrent" ? "torrents" : t("queue records")}`}
              {service.truncated && t(" · partial list")}
            </small>
          </article>
        ))}
      </div>
      {data ? (
        <>
          <div className="observation-summary">
            <span>
              <Check size={14} />
              {t("Last query:")}{" "}
              {new Date(data.observed_at_ms).toLocaleString(locale())}
            </span>
            <span
              className={
                age?.stale || observation.isError
                  ? "freshness stale"
                  : "freshness"
              }
            >
              {observation.isError
                ? t("Query failed · previous data")
                : age?.label}
            </span>
          </div>
          <section className="section">
            <div className="live-toolbar">
              <div className="view-switch">
                <button
                  className={view === "arr" ? "active" : ""}
                  onClick={() => {
                    setView("arr");
                    setPage(0);
                  }}
                >
                  {t("Arr queue")}
                  <span>{data.items.length}</span>
                </button>
                <button
                  className={view === "torrents" ? "active" : ""}
                  onClick={() => {
                    setView("torrents");
                    setPage(0);
                  }}
                >
                  Torrents <span>{data.torrents.length}</span>
                </button>
              </div>
              <label className="search-box">
                <Search size={16} />
                <span className="sr-only">{t("Filter by title")}</span>
                <input
                  placeholder={t("Filter by title…")}
                  maxLength={200}
                  value={filter}
                  onChange={(e) => {
                    setFilter(e.target.value);
                    setPage(0);
                  }}
                />
              </label>
            </div>
            <div className="filter-controls">
              <label>
                {t("Status")}
                <select
                  value={effectiveStatus}
                  onChange={(event) => {
                    setStatusFilter(event.target.value as StatusFilter);
                    setPage(0);
                  }}
                >
                  <option value="all">{t("All")}</option>
                  <option value="downloading">{t("Downloading")}</option>
                  <option value="paused">{t("Paused")}</option>
                  <option value="completed">{t("Completed")}</option>
                  {view === "arr" && (
                    <option value="review">{t("Needs review")}</option>
                  )}
                </select>
              </label>
              <label>
                {t("Sort by")}
                <select
                  value={sortOrder}
                  onChange={(event) => {
                    setSortOrder(event.target.value as SortOrder);
                    setPage(0);
                  }}
                >
                  <option value="original">{t("Queue order")}</option>
                  <option value="name">{t("Title A–Z")}</option>
                  <option value="speed">{t("Highest speed")}</option>
                  <option value="size">{t("Largest size")}</option>
                  <option value="progress">{t("Lowest progress")}</option>
                </select>
              </label>
              {(filter ||
                effectiveStatus !== "all" ||
                sortOrder !== "original") && (
                <button
                  className="text-button"
                  onClick={() => {
                    setFilter("");
                    setStatusFilter("all");
                    setSortOrder("original");
                    setPage(0);
                  }}
                >
                  {t("Clear filters")}
                </button>
              )}
              <span className="result-count">
                {count
                  ? t("{{start}}–{{end}} of {{count}}", {
                      start: currentPage * 20 + 1,
                      end: Math.min((currentPage + 1) * 20, count),
                      count,
                    })
                  : t("0 results")}
              </span>
            </div>
            {data.services.some((service) => service.truncated) && (
              <p className="partial-notice">
                {t(
                  "Partial list: up to 25 records per Arr and 500 torrents. Filters apply to the retrieved items.",
                )}
              </p>
            )}
            <DownloadTable
              items={
                view === "arr"
                  ? rows.slice(currentPage * 20, (currentPage + 1) * 20)
                  : undefined
              }
              torrents={
                view === "torrents"
                  ? torrents.slice(currentPage * 20, (currentPage + 1) * 20)
                  : undefined
              }
            />
            {count === 0 && (
              <div className="empty">
                <LayersIcon />
                <h3>
                  {filter || effectiveStatus !== "all"
                    ? t("No downloads match your filters")
                    : t("No records in this list")}
                </h3>
                <p>
                  {filter || effectiveStatus !== "all"
                    ? t("Change the title or status, or clear the filters.")
                    : t(
                        "Services may have empty queues or be unavailable; check their status above.",
                      )}
                </p>
              </div>
            )}
            {count > 20 && (
              <div className="pagination">
                <button
                  className="secondary"
                  disabled={currentPage === 0}
                  onClick={() => setPage(currentPage - 1)}
                >
                  {t("Previous")}
                </button>
                <span>
                  {currentPage + 1} / {lastPage + 1}
                </span>
                <button
                  className="secondary"
                  disabled={currentPage >= lastPage}
                  onClick={() => setPage(currentPage + 1)}
                >
                  {t("Next")}
                </button>
              </div>
            )}
          </section>
        </>
      ) : (
        <div className="empty live-empty">
          <Activity size={29} />
          <h3>{t("Observe before automating")}</h3>
          <p>
            {t(
              "This query reads configured services. Keys and cookies are never returned to the browser.",
            )}
          </p>
        </div>
      )}
      <div className="bottom-note">
        <ShieldCheck size={18} />
        <p>
          <strong>{t("This query is read only.")}</strong>{" "}
          {t(
            "Observation does not search indexers, pause, remove, resume or replace downloads. The optional 30-second refresh is disabled when you reopen the page.",
          )}
        </p>
      </div>
    </>
  );
}
function LayersIcon() {
  return <Activity size={25} />;
}

function DownloadTable({
  items,
  torrents,
}: {
  items?: Item[];
  torrents?: Torrent[];
}) {
  const rows = items
    ? items.map((item) => ({
        key: `${item.app}:${item.queue_id}`,
        title: item.title,
        origin: [
          names[item.app],
          item.season_number !== null && item.episode_number !== null
            ? `S${String(item.season_number).padStart(2, "0")}E${String(item.episode_number).padStart(2, "0")}`
            : null,
          item.resolution ? `${item.resolution}p` : null,
        ]
          .filter(Boolean)
          .join(" · "),
        note:
          item.has_file === null
            ? t("File not verified")
            : item.has_file
              ? t("Watchable copy available")
              : t("Awaiting import"),
        torrent: item.torrent,
        status: t(advice[item.advice]),
        tone:
          item.advice === "needs_review" || item.advice === "consider_compact"
            ? "warning"
            : "neutral",
        reason: item.reason,
      }))
    : (torrents ?? []).map((torrent) => ({
        key: torrent.hash,
        title: torrent.name,
        origin: "qBittorrent",
        note:
          torrent.progress >= 1
            ? t("Download completed")
            : t("Download in progress"),
        torrent,
        status: /^(stopped|paused)/.test(torrent.state)
          ? t("Paused")
          : torrent.progress >= 1
            ? t("Seeding")
            : torrent.state === "stalledDL"
              ? t("No transfer")
              : t("Downloading"),
        tone: torrent.progress >= 1 ? "success" : "neutral",
        reason: null,
      }));
  if (!rows.length) return null;
  return (
    <div className="download-table-wrap">
      <table
        className="download-table"
        aria-label={items ? t("Arr queue") : t("qBittorrent torrents")}
      >
        <thead>
          <tr>
            <th scope="col">{t("Title")}</th>
            <th scope="col">{t("Progress")}</th>
            <th scope="col">{t("Size")}</th>
            <th scope="col">{t("Speed")}</th>
            <th scope="col">Seeds</th>
            <th scope="col">{t("Status")}</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <tr key={row.key}>
              <td className="download-title">
                <strong title={row.title}>{row.title}</strong>
                <small>
                  {row.origin}
                  <span> · {row.note}</span>
                </small>
              </td>
              <td className="download-progress">
                <span className="mobile-cell-label">{t("Progress")}</span>
                <Progress torrent={row.torrent} />
              </td>
              <td>
                <span className="mobile-cell-label">{t("Size")}</span>
                {row.torrent ? size(row.torrent.bytes) : "—"}
              </td>
              <td>
                <span className="mobile-cell-label">{t("Speed")}</span>
                {row.torrent ? `${size(row.torrent.download_speed)}/s` : "—"}
              </td>
              <td>
                <span className="mobile-cell-label">Seeds</span>
                {row.torrent?.seeds ?? "—"}
              </td>
              <td className="download-status">
                <span className={`status-label ${row.tone}`}>{row.status}</span>
                {row.reason && (
                  <details>
                    <summary>
                      <CircleHelp size={13} />
                      {t("Details")}
                    </summary>
                    <p>{t(row.reason)}</p>
                  </details>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
