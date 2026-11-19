import { t, locale } from "./i18n.ts";
import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api } from "./api";
import { useStoredState, isShortText } from "./preferences";
import {
  sortJobs,
  isJobSort,
  isJobApp,
  type JobSort,
  type JobApp,
  matchesJob,
  isJobFilter,
  jobErrorMessages,
  type JobFilter,
} from "./job-utils.ts";
type Target = {
  app: "radarr" | "sonarr";
  media_id: number;
  episode_ids?: number[];
};
type Job = {
  id: number;
  title: string;
  stage: string;
  external_handoff?: boolean;
  error_code: string | null;
  updated_at_ms: number;
  target: Target;
};
type Candidate = {
  id: string;
  title: string;
  bytes: number;
  seeds: number;
  quality: string;
  format_score: number;
  reason: string;
  native_approved: boolean;
};
type Report = {
  title: string;
  profile_name: string;
  initial_profile_name?: string | null;
  native_profile_name?: string | null;
  compact_candidate_id: string | null;
  upgrade_candidate_id: string | null;
  compact_selections?: { candidate_id: string }[];
  upgrade_selections?: { candidate_id: string }[];
  candidates: Candidate[];
  scope: {
    verified: boolean;
    selected_episode_ids: number[];
    absent_queue_episode_ids: number[];
    warnings: string[];
  } | null;
};
const stages: Record<string, string> = {
  queued: "Queued for analysis",
  analyzing: "Searching releases",
  ready: "Ready for review",
  claiming: "Acquiring exclusive control",
  compact: "Downloading first copy",
  upgrading: "Downloading upgrade",
  completed: "Completed",
  review: "Needs attention",
  cancelled: "Cancelled",
};
export function Jobs() {
  const cache = useQueryClient();
  const [selected, setSelected] = useStoredState<number | null>(
    "selected-job",
    null,
    (value): value is number | null =>
      value === null ||
      (typeof value === "number" && Number.isSafeInteger(value) && value > 0),
    "session",
  );
  const [query, setQuery] = useStoredState(
    "job-search",
    "",
    isShortText,
    "session",
  );
  const [order, setOrder] = useStoredState<JobSort>(
    "job-sort",
    "updated",
    isJobSort,
  );
  const [application, setApplication] = useStoredState<JobApp>(
    "job-application",
    "all",
    isJobApp,
  );
  const [filter, setFilter] = useStoredState<JobFilter>(
    "job-filter",
    "all",
    isJobFilter,
  );
  const [media, setMedia] = useState("");
  const [episode, setEpisode] = useState("");
  const jobs = useQuery({
    queryKey: ["jobs"],
    queryFn: () => api<{ items: Job[]; execution_enabled: boolean }>("/jobs"),
    refetchInterval: 5000,
  });
  const library = useQuery({
    queryKey: ["library"],
    queryFn: () =>
      api<{ items: { app: Target["app"]; id: number; title: string }[] }>(
        "/library",
      ),
  });
  const chosen = library.data?.items.find((x) => `${x.app}:${x.id}` === media);
  const episodes = useQuery({
    queryKey: ["episodes", media],
    enabled: chosen?.app === "sonarr",
    queryFn: () =>
      api<{
        items: { id: number; title: string; season: number; episode: number }[];
      }>(`/library/sonarr/${chosen!.id}/episodes`),
  });
  const detail = useQuery({
    queryKey: ["job", selected],
    enabled: selected !== null,
    queryFn: () =>
      api<{
        job: Job;
        report: Report | null;
        execution_allowed: boolean;
        events: {
          id: number;
          kind: string;
          detail: string;
          created_at: string;
        }[];
      }>(`/jobs/${selected}`),
    refetchInterval: 5000,
  });
  const action = useMutation({
    mutationFn: ({ id, action }: { id: number; action: string }) =>
      api(`/jobs/${id}/${action}`, {}),
    onSuccess: () => {
      void cache.invalidateQueries({ queryKey: ["jobs"] });
      void cache.invalidateQueries({ queryKey: ["job"] });
    },
  });
  const create = useMutation({
    mutationFn: () =>
      api<{ id: number }>("/jobs", {
        target: {
          app: chosen!.app,
          media_id: chosen!.id,
          episode_ids: chosen!.app === "sonarr" ? [Number(episode)] : [],
        },
      }),
    onSuccess: (x) => {
      setSelected(x.id);
      void cache.invalidateQueries({ queryKey: ["jobs"] });
    },
  });
  const visibleJobs = sortJobs(
    jobs.data?.items.filter(
      (job) =>
        matchesJob(job, query, filter) &&
        (application === "all" || job.target.app === application),
    ) ?? [],
    order,
    locale(),
  );
  const staleDetails = Boolean(detail.error);
  const refreshing =
    jobs.isFetching || (selected !== null && detail.isFetching);
  function refresh() {
    void jobs.refetch();
    void library.refetch();
    if (selected !== null) void detail.refetch();
  }
  const data = detail.data;
  const report = data?.report;
  const selectedCandidates =
    report?.candidates.filter(
      (c) =>
        c.id === report.compact_candidate_id ||
        c.id === report.upgrade_candidate_id ||
        report.compact_selections?.some(
          (choice) => choice.candidate_id === c.id,
        ) ||
        report.upgrade_selections?.some(
          (choice) => choice.candidate_id === c.id,
        ),
    ) ?? [];
  return (
    <section className="jobs-page">
      <div className="section-heading">
        <div>
          <h1>{t("Execution plans")}</h1>
          <p>{t("A watchable copy first. Better quality later.")}</p>
        </div>
      </div>
      <div className="card job-create">
        <h2>{t("Analyze a title")}</h2>
        <p>
          {t(
            "Searches query Arr and respect its profile. Creating an analysis does not start downloads.",
          )}
        </p>
        <label>
          {t("Title")}
          <select
            value={media}
            onChange={(e) => {
              setMedia(e.target.value);
              setEpisode("");
            }}
          >
            <option value="">{t("Select from your library")}</option>
            {library.data?.items.map((x) => (
              <option key={`${x.app}:${x.id}`} value={`${x.app}:${x.id}`}>
                {x.app === "radarr" ? t("Movie") : t("Series")} · {x.title}
              </option>
            ))}
          </select>
        </label>
        {chosen?.app === "sonarr" && (
          <label>
            {t("Episode")}
            <select
              value={episode}
              onChange={(e) => setEpisode(e.target.value)}
            >
              <option value="">{t("Select an episode")}</option>
              {episodes.data?.items.map((x) => (
                <option key={x.id} value={x.id}>
                  S{x.season}E{x.episode} · {x.title}
                </option>
              ))}
            </select>
          </label>
        )}
        <button
          className="secondary"
          disabled={
            !chosen || (chosen.app === "sonarr" && !episode) || create.isPending
          }
          onClick={() => create.mutate()}
        >
          {create.isPending ? t("Creating…") : t("Analyze releases")}
        </button>
      </div>
      {(jobs.error ||
        library.error ||
        episodes.error ||
        detail.error ||
        action.error ||
        create.error) && (
        <p className="error" role="alert">
          {
            (
              action.error ??
              create.error ??
              detail.error ??
              jobs.error ??
              library.error ??
              episodes.error
            )?.message
          }
        </p>
      )}
      <div className="card">
        <h2>{t("Saved history")}</h2>
        <div className="job-actions">
          <button className="secondary" disabled={refreshing} onClick={refresh}>
            {refreshing ? t("Refreshing…") : t("Refresh plans")}
          </button>
          {jobs.dataUpdatedAt > 0 && (
            <span className="muted">
              {t("Last successful refresh:")}{" "}
              <time dateTime={new Date(jobs.dataUpdatedAt).toISOString()}>
                {new Date(jobs.dataUpdatedAt).toLocaleTimeString(locale())}
              </time>
            </span>
          )}
        </div>
        <div className="filter-controls">
          <label>
            {t("Search plans")}
            <input
              type="search"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder={t("Title or application")}
            />
          </label>
          <label>
            {t("Status")}
            <select
              value={filter}
              onChange={(event) => {
                if (isJobFilter(event.target.value))
                  setFilter(event.target.value);
              }}
            >
              <option value="all">{t("All plans")}</option>
              <option value="active">{t("Active plans")}</option>
              <option value="attention">{t("Needs attention")}</option>
              <option value="finished">{t("Finished plans")}</option>
            </select>
          </label>
          <label>
            {t("Application")}
            <select
              value={application}
              onChange={(event) => {
                if (isJobApp(event.target.value))
                  setApplication(event.target.value);
              }}
            >
              <option value="all">{t("All applications")}</option>
              <option value="radarr">Radarr</option>
              <option value="sonarr">Sonarr</option>
            </select>
          </label>
          <label>
            {t("Sort plans")}
            <select
              value={order}
              onChange={(event) => {
                if (isJobSort(event.target.value)) setOrder(event.target.value);
              }}
            >
              <option value="updated">{t("Recently updated")}</option>
              <option value="oldest">{t("Oldest update first")}</option>
              <option value="title">{t("Title A–Z")}</option>
            </select>
          </label>
          <span className="result-count" role="status">
            {t("{{shown}} of {{total}} plans", {
              shown: visibleJobs.length,
              total: jobs.data?.items.length ?? 0,
            })}
          </span>
        </div>
        {jobs.isPending ? (
          <p>{t("Loading plans…")}</p>
        ) : jobs.error && !jobs.data ? (
          <p>
            {t("Could not load plan history. Use Refresh plans to try again.")}
          </p>
        ) : !jobs.data?.items.length ? (
          <p>{t("No plans yet.")}</p>
        ) : !visibleJobs.length ? (
          <p>
            {t("No plans match these filters.")}{" "}
            <button
              className="secondary"
              onClick={() => {
                setQuery("");
                setFilter("all");
                setApplication("all");
              }}
            >
              {t("Clear filters")}
            </button>
          </p>
        ) : (
          <div className="table-scroll">
            <table>
              <thead>
                <tr>
                  <th>{t("Title")}</th>
                  <th>{t("Application")}</th>
                  <th>{t("Stage")}</th>
                  <th>{t("Last updated")}</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                {visibleJobs.map((j) => (
                  <tr key={j.id}>
                    <td>{j.title}</td>
                    <td>{j.target.app}</td>
                    <td>
                      {t(
                        j.external_handoff
                          ? "Handed off to another app"
                          : (stages[j.stage] ?? j.stage),
                      )}
                      {j.error_code && (
                        <div className="job-error-code">{j.error_code}</div>
                      )}
                    </td>
                    <td>
                      <time dateTime={new Date(j.updated_at_ms).toISOString()}>
                        {new Date(j.updated_at_ms).toLocaleString(locale())}
                      </time>
                    </td>
                    <td>
                      <button
                        className="secondary"
                        onClick={() => setSelected(j.id)}
                        aria-pressed={selected === j.id}
                      >
                        {t("Details")}
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
      {selected !== null && detail.isPending && (
        <p role="status">{t("Loading plan details…")}</p>
      )}
      {data && (
        <div className="card job-detail">
          <h2>{data.job.title}</h2>
          <p>
            {t(
              data.job.external_handoff
                ? "Handed off to another app"
                : (stages[data.job.stage] ?? data.job.stage),
            )}{" "}
            · {report?.profile_name}
          </p>
          {data.job.error_code && (
            <p className="error" role="alert">
              {t(
                jobErrorMessages[data.job.error_code] ??
                  "Review is required before execution can continue. Check the event history for details.",
              )}
              <br />
              <code>{data.job.error_code}</code>
            </p>
          )}
          {staleDetails && (
            <p className="error" role="alert">
              {t(
                "These plan details could not be refreshed. Actions are disabled until a successful refresh.",
              )}
            </p>
          )}
          <div className="job-actions">
            <button
              className="secondary"
              disabled={
                staleDetails ||
                !data.execution_allowed ||
                data.job.stage !== "ready" ||
                action.isPending
              }
              onClick={() =>
                action.mutate({ id: data.job.id, action: "start" })
              }
            >
              {t("Start plan")}
            </button>
            <button
              className="secondary"
              disabled={
                staleDetails ||
                !["ready", "review", "cancelled", "completed"].includes(
                  data.job.stage,
                ) ||
                action.isPending
              }
              onClick={() =>
                action.mutate({ id: data.job.id, action: "analyze" })
              }
            >
              {t("Reanalyze with current defaults")}
            </button>
            <button
              className="secondary"
              disabled={
                staleDetails ||
                ["completed", "cancelled"].includes(data.job.stage) ||
                action.isPending
              }
              onClick={() =>
                action.mutate({ id: data.job.id, action: "cancel" })
              }
            >
              {t("Cancel and release control")}
            </button>
          </div>
          {!data.execution_allowed && (
            <p>
              {t(
                "Execution is disabled for this title. Analysis is still available.",
              )}
            </p>
          )}
          {report?.scope && (
            <p>
              {t("Pack {{status}}: {{selected}}; {{missing}}", {
                status: t(report.scope.verified ? "verified" : "unverified"),
                selected: t("selectedEpisodes", {
                  count: report.scope.selected_episode_ids.length,
                }),
                missing: t("missingQueueItems", {
                  count: report.scope.absent_queue_episode_ids.length,
                }),
              })}{" "}
              {report.scope.warnings.map((w) => t(w)).join(" ")}
            </p>
          )}
          {report && (
            <p>
              <strong>{t("Initial profile:")}</strong>{" "}
              {report.initial_profile_name ??
                t("Title profile + compact limits")}
              <br />
              <strong>{t("Final profile:")}</strong> {report.profile_name}
              <br />
              <small>
                {t("Arr safeguards:")}{" "}
                {report.native_profile_name ?? report.profile_name}
                {t(". Profiles recorded when this plan was analyzed.")}
              </small>
            </p>
          )}
          <h3>{t("Selected releases")}</h3>
          {selectedCandidates.length === 0 ? (
            <p>{t("No eligible release confirmed.")}</p>
          ) : (
            selectedCandidates.map((c) => (
              <div className="candidate-choice" key={c.id}>
                <strong>
                  {c.id === report?.compact_candidate_id ||
                  report?.compact_selections?.some(
                    (choice) => choice.candidate_id === c.id,
                  )
                    ? t("First copy")
                    : t("Upgrade")}
                </strong>
                <p>{c.title}</p>
                <p>
                  {c.quality} ·{" "}
                  {(c.bytes / 1024 ** 3).toLocaleString(locale(), {
                    minimumFractionDigits: 2,
                    maximumFractionDigits: 2,
                  })}{" "}
                  GiB · {c.seeds} {t("seeds · format score")} {c.format_score}
                </p>
                <small>{t(c.reason)}</small>
              </div>
            ))
          )}
          <details>
            <summary>
              {t("All releases (")}
              {report?.candidates.length ?? 0})
            </summary>
            {report?.candidates.map((c) => (
              <p key={c.id}>
                <strong>
                  {c.native_approved ? "✓" : "—"} {c.title}
                </strong>
                <br />
                {c.quality} ·{" "}
                {(c.bytes / 1024 ** 3).toLocaleString(locale(), {
                  minimumFractionDigits: 2,
                  maximumFractionDigits: 2,
                })}{" "}
                GiB · {c.seeds} seeds · {t(c.reason)}
              </p>
            ))}
          </details>
          <h3>{t("Events")}</h3>
          <ol className="job-events">
            {data.events.map((e) => (
              <li key={e.id}>
                <time>{new Date(e.created_at).toLocaleString(locale())}</time>
                <p>{t(e.detail)}</p>
              </li>
            ))}
          </ol>
        </div>
      )}
    </section>
  );
}
