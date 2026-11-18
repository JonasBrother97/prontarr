import { t, locale } from "./i18n.ts";
import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api } from "./api";
import { useStoredState } from "./preferences";
type Target = {
  app: "radarr" | "sonarr";
  media_id: number;
  episode_ids?: number[];
};
type Job = {
  id: number;
  title: string;
  stage: string;
  error_code: string | null;
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
  const data = detail.data;
  const report = data?.report;
  const selectedCandidates =
    report?.candidates.filter(
      (c) =>
        c.id === report.compact_candidate_id ||
        c.id === report.upgrade_candidate_id,
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
        {jobs.isPending ? (
          <p>{t("Loading plans…")}</p>
        ) : !jobs.data?.items.length ? (
          <p>{t("No plans yet.")}</p>
        ) : (
          <div className="table-scroll">
            <table>
              <thead>
                <tr>
                  <th>{t("Title")}</th>
                  <th>{t("Application")}</th>
                  <th>{t("Stage")}</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                {jobs.data.items.map((j) => (
                  <tr key={j.id}>
                    <td>{j.title}</td>
                    <td>{j.target.app}</td>
                    <td>{t(stages[j.stage] ?? j.stage)}</td>
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
      {data && (
        <div className="card job-detail">
          <h2>{data.job.title}</h2>
          <p>
            {t(stages[data.job.stage] ?? data.job.stage)} ·{" "}
            {report?.profile_name}
          </p>
          {data.job.error_code && (
            <p className="error" role="alert">
              {data.job.error_code}
              {t(". Review is required before execution can continue.")}
            </p>
          )}
          <div className="job-actions">
            <button
              className="secondary"
              disabled={
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
                !["ready", "review", "cancelled", "completed"].includes(
                  data.job.stage,
                ) || action.isPending
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
                  {c.id === report?.compact_candidate_id
                    ? t("First copy")
                    : "Upgrade"}
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
