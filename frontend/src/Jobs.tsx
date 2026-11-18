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
  queued: "Na fila de análise",
  analyzing: "Consultando fontes",
  ready: "Pronto para revisão",
  claiming: "Obtendo controle exclusivo",
  compact: "Baixando primeira cópia",
  upgrading: "Aguardando upgrade",
  completed: "Concluído",
  review: "Requer atenção",
  cancelled: "Cancelado",
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
          <h1>Planos de execução</h1>
          <p>Uma cópia disponível primeiro, qualidade melhor depois.</p>
        </div>
      </div>
      <div className="card job-create">
        <h2>Analisar um título</h2>
        <p>
          A busca consulta o Arr e respeita seu perfil. Criar uma análise não
          inicia downloads.
        </p>
        <label>
          Título
          <select
            value={media}
            onChange={(e) => {
              setMedia(e.target.value);
              setEpisode("");
            }}
          >
            <option value="">Selecione na biblioteca</option>
            {library.data?.items.map((x) => (
              <option key={`${x.app}:${x.id}`} value={`${x.app}:${x.id}`}>
                {x.app === "radarr" ? "Filme" : "Série"} · {x.title}
              </option>
            ))}
          </select>
        </label>
        {chosen?.app === "sonarr" && (
          <label>
            Episódio
            <select
              value={episode}
              onChange={(e) => setEpisode(e.target.value)}
            >
              <option value="">Selecione um episódio</option>
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
          {create.isPending ? "Criando…" : "Analisar fontes"}
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
        <h2>Histórico persistido</h2>
        {jobs.isPending ? (
          <p>Carregando planos…</p>
        ) : !jobs.data?.items.length ? (
          <p>Nenhum plano criado.</p>
        ) : (
          <div className="table-scroll">
            <table>
              <thead>
                <tr>
                  <th>Título</th>
                  <th>Aplicação</th>
                  <th>Etapa</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                {jobs.data.items.map((j) => (
                  <tr key={j.id}>
                    <td>{j.title}</td>
                    <td>{j.target.app}</td>
                    <td>{stages[j.stage] ?? j.stage}</td>
                    <td>
                      <button
                        className="secondary"
                        onClick={() => setSelected(j.id)}
                        aria-pressed={selected === j.id}
                      >
                        Detalhes
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
            {stages[data.job.stage] ?? data.job.stage} · {report?.profile_name}
          </p>
          {data.job.error_code && (
            <p className="error" role="alert">
              {data.job.error_code}. A execução requer revisão antes de
              continuar.
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
              Iniciar plano
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
              Reanalisar com padrões atuais
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
              Cancelar e liberar controle
            </button>
          </div>
          {!data.execution_allowed && (
            <p>
              Execução desativada para este título. A análise continua
              disponível.
            </p>
          )}
          {report?.scope && (
            <p>
              Pacote {report.scope.verified ? "verificado" : "não confirmado"}:{" "}
              {report.scope.selected_episode_ids.length} episódio(s)
              selecionado(s); {report.scope.absent_queue_episode_ids.length}{" "}
              item(ns) da fila ausente(s) do torrent.{" "}
              {report.scope.warnings.join(" ")}
            </p>
          )}
          {report && (
            <p>
              <strong>Perfil inicial:</strong>{" "}
              {report.initial_profile_name ??
                "Perfil do título + limites compactos"}
              <br />
              <strong>Perfil final:</strong> {report.profile_name}
              <br />
              <small>
                Proteções do Arr:{" "}
                {report.native_profile_name ?? report.profile_name}. Perfis
                registrados na análise deste plano.
              </small>
            </p>
          )}
          <h3>Fontes escolhidas</h3>
          {selectedCandidates.length === 0 ? (
            <p>Nenhuma fonte elegível confirmada.</p>
          ) : (
            selectedCandidates.map((c) => (
              <div className="candidate-choice" key={c.id}>
                <strong>
                  {c.id === report?.compact_candidate_id
                    ? "Primeira cópia"
                    : "Upgrade"}
                </strong>
                <p>{c.title}</p>
                <p>
                  {c.quality} · {(c.bytes / 1024 ** 3).toFixed(2)} GiB ·{" "}
                  {c.seeds} seeds · formatos {c.format_score}
                </p>
                <small>{c.reason}</small>
              </div>
            ))
          )}
          <details>
            <summary>
              Todas as fontes ({report?.candidates.length ?? 0})
            </summary>
            {report?.candidates.map((c) => (
              <p key={c.id}>
                <strong>
                  {c.native_approved ? "✓" : "—"} {c.title}
                </strong>
                <br />
                {c.quality} · {(c.bytes / 1024 ** 3).toFixed(2)} GiB · {c.seeds}{" "}
                seeds · {c.reason}
              </p>
            ))}
          </details>
          <h3>Eventos</h3>
          <ol className="job-events">
            {data.events.map((e) => (
              <li key={e.id}>
                <time>{new Date(e.created_at).toLocaleString("pt-BR")}</time>
                <p>{e.detail}</p>
              </li>
            ))}
          </ol>
        </div>
      )}
    </section>
  );
}
