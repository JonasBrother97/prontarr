import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import {
  Activity,
  ArrowDown,
  Check,
  CircleHelp,
  RefreshCw,
  Search,
  ShieldCheck,
} from "lucide-react";
import { api } from "./api";

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
  wait_for_import: "Aguardar importação",
  consider_compact: "Avaliar cópia compacta",
  keep_upgrade: "Preservar cópia disponível",
  respect_pause: "Respeitar pausa",
  needs_review: "Revisar informações",
};
const errors: Record<string, string> = {
  UpstreamUnauthorized: "Acesso não autorizado. Verifique a chave ou sessão.",
  UpstreamTimeout: "O serviço excedeu o tempo de resposta.",
  UpstreamUnavailable: "O serviço não respondeu. Verifique a conexão.",
  UpstreamRedirectBlocked:
    "O serviço redirecionou a consulta. Confira o endereço direto da API.",
  InvalidUpstreamCertificate:
    "O certificado TLS do serviço não pôde ser validado.",
  InvalidUpstreamResponse: "O serviço retornou dados inesperados.",
  ResponseTooLarge: "A resposta ultrapassou o limite de segurança.",
};
function size(n: number) {
  if (n <= 0) return "0 B";
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  const exponent = Math.min(Math.floor(Math.log(n) / Math.log(1024)), 4);
  return `${(n / 1024 ** exponent).toLocaleString("pt-BR", { maximumFractionDigits: 1 })} ${units[exponent]}`;
}
function eta(t: Torrent) {
  if (t.progress >= 1) return "Baixado";
  if (t.eta_seconds === null) return "Sem previsão";
  const minutes = Math.max(1, Math.ceil(t.eta_seconds / 60));
  return minutes < 60
    ? `${minutes} min`
    : `${Math.floor(minutes / 60)}h ${minutes % 60}min`;
}
function Progress({ torrent }: { torrent: Torrent | null }) {
  if (!torrent) return <span className="muted">Sem correspondência</span>;
  return (
    <div className="progress-cell">
      <span>
        {(torrent.progress * 100).toFixed(1)}% <small>{eta(torrent)}</small>
      </span>
      <progress
        max={1}
        value={torrent.progress}
        aria-label={`Progresso de ${torrent.name}`}
      />
    </div>
  );
}
export function Live() {
  const [view, setView] = useState<"arr" | "torrents">("arr");
  const [filter, setFilter] = useState("");
  const [page, setPage] = useState(0);
  const configuration = useQuery({
    queryKey: ["connections"],
    queryFn: () =>
      api<{ items: { name: string; configured: boolean }[] }>("/connections"),
  });
  const observation = useQuery({
    queryKey: ["observation"],
    queryFn: () => api<Observation>("/observe", {}),
    enabled: false,
    retry: false,
  });
  const data = observation.data;
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
  const rows =
    data?.items.filter((i) =>
      i.title.toLowerCase().includes(filter.toLowerCase()),
    ) ?? [];
  const torrents =
    data?.torrents.filter((t) =>
      t.name.toLowerCase().includes(filter.toLowerCase()),
    ) ?? [];
  const count = view === "arr" ? rows.length : torrents.length;
  const lastPage = Math.max(0, Math.ceil(count / 20) - 1);
  const currentPage = Math.min(page, lastPage);
  return (
    <>
      <section className="page-heading">
        <div>
          <span className="eyebrow">OBSERVAÇÃO · DADOS REAIS</span>
          <h1>
            O que está acontecendo
            <br />
            <span>com seus downloads.</span>
          </h1>
          <p>
            Consulte a fila e compare as sugestões sem alterar nenhum torrent.
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
            ? "Consultando…"
            : data
              ? "Atualizar observação"
              : "Consultar serviços"}
        </button>
      </section>
      {(configuration.error || observation.error) && (
        <p role="alert" className="error">
          {(observation.error ?? configuration.error)?.message}
          {data && " Os dados abaixo são da última consulta concluída."}
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
              <span className={`dot ${service.connected ? "green" : ""}`} />
            </div>
            <p>
              {service.connected
                ? `Conectado · ${service.version}`
                : service.error_code
                  ? (errors[service.error_code] ??
                    "Falha ao consultar o serviço.")
                  : service.configured
                    ? "Configurado · aguardando consulta"
                    : "Conexão não configurada"}
            </p>
            <small>
              Somente leitura
              {service.connected &&
                ` · ${service.total_records} ${service.name === "qbittorrent" ? "torrents" : "registros na fila"}`}
              {service.truncated && " · lista parcial"}
            </small>
          </article>
        ))}
      </div>
      {data ? (
        <>
          <div className="observation-summary">
            <span>
              <Check size={14} />
              Última consulta:{" "}
              {new Date(data.observed_at_ms).toLocaleString("pt-BR")}
            </span>
            <span>Nenhuma ação executada</span>
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
                  Fila dos Arr <span>{data.items.length}</span>
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
                <span className="sr-only">Filtrar por título</span>
                <input
                  placeholder="Filtrar por título…"
                  value={filter}
                  onChange={(e) => {
                    setFilter(e.target.value);
                    setPage(0);
                  }}
                />
              </label>
            </div>
            {view === "arr" ? (
              <div className="live-list">
                {rows
                  .slice(currentPage * 20, (currentPage + 1) * 20)
                  .map((item) => (
                    <article
                      className="card live-item"
                      key={`${item.app}:${item.queue_id}`}
                    >
                      <div className="live-item-top">
                        <div className="live-title">
                          <span className="eyebrow">
                            {names[item.app]} ·{" "}
                            {item.season_number !== null &&
                              item.episode_number !== null &&
                              `S${String(item.season_number).padStart(2, "0")}E${String(item.episode_number).padStart(2, "0")} · `}
                            {item.resolution
                              ? `${item.resolution}p`
                              : "Qualidade não identificada"}
                          </span>
                          <h3>{item.title}</h3>
                          <span className="muted">
                            {item.has_file === null
                              ? "Arquivo não verificado"
                              : item.has_file
                                ? "Versão disponível na biblioteca"
                                : "Ainda sem arquivo importado"}
                            {item.custom_format_score !== null &&
                              ` · Formatos: ${item.custom_format_score >= 0 ? "+" : ""}${item.custom_format_score}`}
                          </span>
                        </div>
                        <span
                          className={`advice-pill ${item.advice === "consider_compact" ? "attention" : ""}`}
                        >
                          {advice[item.advice]}
                        </span>
                      </div>
                      <div className="torrent-metrics">
                        <Progress torrent={item.torrent} />
                        <span>
                          <ArrowDown size={14} />
                          {size(item.torrent?.download_speed ?? 0)}/s
                        </span>
                        <span>{item.torrent?.seeds ?? "—"} seeds</span>
                        <span>
                          {item.torrent ? size(item.torrent.bytes) : "—"}
                        </span>
                      </div>
                      <details>
                        <summary>
                          <CircleHelp size={14} />
                          Por que esta sugestão?
                        </summary>
                        <p>{item.reason}</p>
                        <small>
                          Sugestão baseada na fila observada. Áudio, escopo
                          completo e qualidade final ainda exigem validação.
                        </small>
                      </details>
                    </article>
                  ))}
              </div>
            ) : (
              <div className="live-list">
                {torrents
                  .slice(currentPage * 20, (currentPage + 1) * 20)
                  .map((t) => (
                    <article className="card live-item" key={t.hash}>
                      <div className="live-item-top">
                        <div className="live-title">
                          <h3>{t.name}</h3>
                          <span className="muted">{t.state}</span>
                        </div>
                        <span className="pill">{size(t.bytes)}</span>
                      </div>
                      <div className="torrent-metrics">
                        <Progress torrent={t} />
                        <span>
                          <ArrowDown size={14} />
                          {size(t.download_speed)}/s
                        </span>
                        <span>{t.seeds} seeds</span>
                      </div>
                    </article>
                  ))}
              </div>
            )}
            {count === 0 && (
              <div className="empty">
                <LayersIcon />
                <h3>
                  {filter
                    ? "Nenhum título corresponde ao filtro"
                    : "Nenhum registro nesta lista"}
                </h3>
                <p>
                  {filter
                    ? "Tente outro nome."
                    : "Os serviços podem estar sem downloads na fila ou indisponíveis; confira os estados acima."}
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
                  Anterior
                </button>
                <span>
                  {currentPage + 1} / {lastPage + 1}
                </span>
                <button
                  className="secondary"
                  disabled={currentPage >= lastPage}
                  onClick={() => setPage(currentPage + 1)}
                >
                  Próxima
                </button>
              </div>
            )}
          </section>
        </>
      ) : (
        <div className="empty live-empty">
          <Activity size={29} />
          <h3>Observe antes de automatizar</h3>
          <p>
            A consulta lê os serviços configurados. Chaves e cookies nunca são
            retornados ao navegador.
          </p>
        </div>
      )}
      <div className="bottom-note">
        <ShieldCheck size={18} />
        <p>
          <strong>Seu controlador atual continua no comando.</strong> A
          observação não faz buscas nos indexadores e não pausa, remove, retoma
          ou substitui downloads. Atualize manualmente para obter uma nova
          fotografia da fila.
        </p>
      </div>
    </>
  );
}
function LayersIcon() {
  return <Activity size={25} />;
}
