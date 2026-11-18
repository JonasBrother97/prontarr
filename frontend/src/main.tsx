import React, { useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  QueryClient,
  QueryClientProvider,
  useQuery,
  useMutation,
  useQueryClient,
} from "@tanstack/react-query";
import {
  ArrowRight,
  Check,
  ChevronRight,
  ChevronDown,
  Menu,
  X,
  Activity,
  Wrench,
  FlaskConical,
  Layers3,
  LayoutDashboard,
  Plus,
  Settings2,
  ShieldCheck,
  Trash2,
  Zap,
} from "lucide-react";
import "./style.css";
import { api } from "./api";
import { Live } from "./Live";
import {
  useStoredState,
  isBoolean,
  pageFromHash,
  routes,
  type Page,
} from "./preferences";

type Stage =
  "missing" | "compact_downloading" | "watchable" | "upgrading" | "complete";
type Policy = {
  max_compact_bytes: number;
  min_seeders: number;
  min_resolution: number;
  max_resolution: number;
};
type Candidate = {
  id: string;
  title: string;
  bytes: number;
  seeders: number;
  resolution: number;
  original_audio: boolean;
  arr_approved: boolean;
  remux: boolean;
};
type Input = {
  title: string;
  policy: Policy;
  snapshot: {
    stage: Stage;
    imported_episodes: number;
    expected_episodes: number;
    upgrade_import_confirmed: boolean;
  };
  candidates: Candidate[];
};
type Decision = {
  action: string;
  next_stage: Stage;
  candidate_id: string | null;
  reason: string;
  may_remove_first_copy: boolean;
};
type Plan = {
  id: number;
  title: string;
  decision: Decision;
  created_at: string;
};
const GiB = 1024 ** 3;
const stageNames: Record<Stage, string> = {
  missing: "Sem cópia",
  compact_downloading: "Primeira cópia",
  watchable: "Disponível",
  upgrading: "Upgrade",
  complete: "Concluído",
};
const actionNames: Record<string, string> = {
  wait: "Aguardar",
  download_compact: "Escolher versão compacta",
  search_upgrade: "Buscar upgrade",
  keep_available: "Preservar versão disponível",
  complete: "Concluir plano",
};
const queryClient = new QueryClient({
  defaultOptions: { queries: { retry: 1, refetchOnWindowFocus: false } },
});

function App() {
  const [page, setPage] = useState<Page>(() =>
    pageFromHash(window.location.hash),
  );
  const [replayedPlan, setReplayedPlan] = useState<Input | null>(null);
  const [narrow, setNarrow] = useState(
    () => window.matchMedia("(max-width: 760px)").matches,
  );
  const [collapsed, setCollapsed] = useStoredState(
    "sidebar-collapsed",
    false,
    isBoolean,
  );
  const [mobileMenu, setMobileMenu] = useState(false);
  const [groups, setGroups] = useStoredState(
    "sidebar-groups",
    { activity: true, tools: true, settings: true },
    (
      value,
    ): value is { activity: boolean; tools: boolean; settings: boolean } =>
      typeof value === "object" &&
      value !== null &&
      ["activity", "tools", "settings"].every(
        (key) => typeof (value as Record<string, unknown>)[key] === "boolean",
      ),
  );
  const menuTrigger = useRef<HTMLButtonElement>(null);
  function navigate(target: typeof page) {
    setPage(target);
    if (window.location.hash !== routes[target])
      window.location.hash = routes[target];
    if (mobileMenu) {
      setMobileMenu(false);
      menuTrigger.current?.focus();
    }
  }
  useEffect(() => {
    const change = () => {
      setPage(pageFromHash(window.location.hash));
      setMobileMenu(false);
    };
    if (!window.location.hash)
      window.history.replaceState(null, "", routes[page]);
    window.addEventListener("hashchange", change);
    return () => window.removeEventListener("hashchange", change);
  }, []);
  useEffect(() => {
    const group =
      page === "live"
        ? "activity"
        : page === "simulator"
          ? "tools"
          : page === "policy"
            ? "settings"
            : null;
    if (group)
      setGroups((previous) =>
        previous[group] ? previous : { ...previous, [group]: true },
      );
  }, [page, setGroups]);
  function toggleGroup(group: keyof typeof groups) {
    setGroups((previous) => ({ ...previous, [group]: !previous[group] }));
  }
  useEffect(() => {
    const media = window.matchMedia("(max-width: 760px)");
    const change = (event: MediaQueryListEvent) => {
      setNarrow(event.matches);
      if (!event.matches) setMobileMenu(false);
    };
    media.addEventListener("change", change);
    return () => media.removeEventListener("change", change);
  }, []);
  useEffect(() => {
    if (!mobileMenu) return;
    const close = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        setMobileMenu(false);
        menuTrigger.current?.focus();
      }
    };
    window.addEventListener("keydown", close);
    return () => window.removeEventListener("keydown", close);
  }, [mobileMenu]);
  const health = useQuery({
    queryKey: ["health"],
    queryFn: () => api<{ status: string }>("/health"),
    refetchInterval: 30_000,
    retry: false,
  });
  return (
    <div
      className={`shell ${collapsed ? "sidebar-collapsed" : ""} ${mobileMenu ? "mobile-menu-open" : ""}`}
    >
      {mobileMenu && (
        <button
          className="sidebar-backdrop"
          aria-label="Fechar menu"
          onClick={() => {
            setMobileMenu(false);
            menuTrigger.current?.focus();
          }}
        />
      )}
      <aside
        className="sidebar"
        id="sidebar"
        aria-label="Menu lateral"
        inert={narrow ? !mobileMenu : collapsed}
        aria-hidden={narrow ? !mobileMenu : collapsed}
      >
        <a
          className="brand"
          href="#"
          onClick={(e) => {
            e.preventDefault();
            navigate("dashboard");
          }}
        >
          <span className="brand-symbol">
            <Zap size={23} fill="currentColor" />
          </span>
          prontarr<span className="alpha">alpha</span>
        </a>
        <nav className="arr-navigation" aria-label="Navegação principal">
          <button
            className={`nav-main ${page === "dashboard" ? "active" : ""}`}
            aria-current={page === "dashboard" ? "page" : undefined}
            onClick={() => navigate("dashboard")}
          >
            <LayoutDashboard size={20} />
            <span>Visão geral</span>
          </button>
          <div className="nav-group">
            <button
              className={`nav-main nav-group-toggle ${page === "live" ? "group-selected" : ""}`}
              aria-expanded={groups.activity}
              aria-controls="nav-activity"
              onClick={() => toggleGroup("activity")}
            >
              <Activity size={20} />
              <span>Atividade</span>
              <ChevronDown
                size={14}
                className={
                  groups.activity ? "group-chevron expanded" : "group-chevron"
                }
              />
            </button>
            {groups.activity && (
              <div className="nav-submenu" id="nav-activity">
                <button
                  className={page === "live" ? "active" : ""}
                  aria-current={page === "live" ? "page" : undefined}
                  onClick={() => navigate("live")}
                >
                  Fila de downloads
                </button>
              </div>
            )}
          </div>
          <div className="nav-group">
            <button
              className={`nav-main nav-group-toggle ${page === "simulator" ? "group-selected" : ""}`}
              aria-expanded={groups.tools}
              aria-controls="nav-tools"
              onClick={() => toggleGroup("tools")}
            >
              <Wrench size={20} />
              <span>Ferramentas</span>
              <ChevronDown
                size={14}
                className={
                  groups.tools ? "group-chevron expanded" : "group-chevron"
                }
              />
            </button>
            {groups.tools && (
              <div className="nav-submenu" id="nav-tools">
                <button
                  className={page === "simulator" ? "active" : ""}
                  aria-current={page === "simulator" ? "page" : undefined}
                  onClick={() => navigate("simulator")}
                >
                  Simulador
                </button>
              </div>
            )}
          </div>
          <div className="nav-group">
            <button
              className={`nav-main nav-group-toggle ${page === "policy" ? "group-selected" : ""}`}
              aria-expanded={groups.settings}
              aria-controls="nav-settings"
              onClick={() => toggleGroup("settings")}
            >
              <Settings2 size={20} />
              <span>Configurações</span>
              <ChevronDown
                size={14}
                className={
                  groups.settings ? "group-chevron expanded" : "group-chevron"
                }
              />
            </button>
            {groups.settings && (
              <div className="nav-submenu" id="nav-settings">
                <button
                  className={page === "policy" ? "active" : ""}
                  aria-current={page === "policy" ? "page" : undefined}
                  onClick={() => navigate("policy")}
                >
                  Perfil de download
                </button>
              </div>
            )}
          </div>
        </nav>
        <div className="sidebar-foot">
          <span className={`dot ${health.isSuccess ? "green" : ""}`} />
          {health.isSuccess
            ? "Sistema online"
            : health.isError
              ? "Sistema indisponível"
              : "Conectando…"}
          <small>v0.3.0 · Desenvolvimento</small>
        </div>
      </aside>
      <main>
        <header className="topbar">
          <div className="toolbar-leading">
            <button
              ref={menuTrigger}
              className="sidebar-toggle"
              aria-label={
                mobileMenu ? "Fechar menu lateral" : "Alternar menu lateral"
              }
              aria-controls="sidebar"
              aria-expanded={narrow ? mobileMenu : !collapsed}
              onClick={() => {
                if (window.matchMedia("(max-width: 760px)").matches)
                  setMobileMenu(!mobileMenu);
                else setCollapsed(!collapsed);
              }}
            >
              {mobileMenu ? <X size={20} /> : <Menu size={20} />}
            </button>
            <div className="breadcrumb">
              <span>Prontarr</span>
              <ChevronRight size={14} />
              <strong>
                {
                  {
                    dashboard: "Visão geral",
                    live: "Downloads",
                    simulator: "Simulador",
                    policy: "Política de download",
                  }[page]
                }
              </strong>
            </div>
          </div>
          <span className="mode">
            <ShieldCheck size={14} />
            Somente leitura
          </span>
        </header>
        <div className="content">
          <div className="notice">
            <FlaskConical size={16} />
            <span>
              Observação e simulação. Consulte dados reais e avalie decisões;
              nenhum download ou arquivo da biblioteca é alterado.
            </span>
          </div>
          {page === "dashboard" && (
            <Dashboard
              onStart={() => {
                setReplayedPlan(null);
                navigate("simulator");
              }}
              onOpen={(input) => {
                setReplayedPlan(input);
                navigate("simulator");
              }}
            />
          )}
          {page === "simulator" && (
            <Simulator initial={replayedPlan ?? undefined} />
          )}
          {page === "policy" && <PolicyEditor />}
          {page === "live" && <Live />}
        </div>
        <footer>
          PRONTARR <span>Uma cópia para agora. Uma melhor para depois.</span>
        </footer>
      </main>
    </div>
  );
}
function Dashboard({
  onStart,
  onOpen,
}: {
  onStart: () => void;
  onOpen: (input: Input) => void;
}) {
  const reopen = useMutation({
    mutationFn: (id: number) => api<{ input: Input }>(`/plans/${id}`),
    onSuccess: (data) => onOpen(data.input),
  });
  const plans = useQuery({
    queryKey: ["plans"],
    queryFn: () => api<{ items: Plan[] }>("/plans"),
  });
  return (
    <>
      <section className="page-heading">
        <div>
          <span className="eyebrow">DOWNLOAD EM DUAS ETAPAS</span>
          <h1>Visão geral</h1>
          <p>
            Primeiro uma versão compacta. Depois, a qualidade que você quer.
          </p>
        </div>
        <button className="primary" onClick={onStart}>
          <Plus size={17} />
          Nova simulação
        </button>
      </section>
      <section className="pipeline" aria-label="Etapas da estratégia">
        {[
          [
            "01",
            "Encontrar uma cópia",
            "Tamanho e disponibilidade em equilíbrio.",
          ],
          [
            "02",
            "Liberar para assistir",
            "Confirmar a importação de todo o escopo.",
          ],
          [
            "03",
            "Evoluir a qualidade",
            "Preservar a cópia até o upgrade chegar.",
          ],
        ].map(([n, title, detail], i) => (
          <React.Fragment key={n}>
            <div className="pipeline-step">
              <span>{n}</span>
              <div>
                <h3>{title}</h3>
                <p>{detail}</p>
              </div>
            </div>
            {i < 2 && <ChevronRight className="pipeline-arrow" size={18} />}
          </React.Fragment>
        ))}
      </section>
      <ErrorNotice error={reopen.error} />
      <section className="section">
        <div className="section-heading">
          <h2>Planos de simulação</h2>
          <span className="count">{plans.data?.items.length ?? 0} salvos</span>
        </div>
        {plans.isPending ? (
          <p role="status">Carregando planos…</p>
        ) : plans.isError ? (
          <ErrorNotice error={plans.error} />
        ) : plans.data.items.length === 0 ? (
          <div className="empty">
            <span className="empty-icon">
              <Layers3 size={28} />
            </span>
            <h3>O primeiro plano começa aqui</h3>
            <p>
              Compare versões e veja por que o motor escolheu cada próxima ação.
            </p>
            <button className="secondary" onClick={onStart}>
              Abrir simulador
              <ArrowRight size={16} />
            </button>
          </div>
        ) : (
          <div className="plan-list">
            {plans.data.items.map((p) => (
              <article className="plan" key={p.id}>
                <div className="plan-icon">
                  <Layers3 size={20} />
                </div>
                <div>
                  <h3>{p.title}</h3>
                  <p>{actionNames[p.decision.action]}</p>
                  <small>
                    {new Date(p.created_at).toLocaleString("pt-BR")}
                  </small>
                </div>
                <span className="pill">
                  {stageNames[p.decision.next_stage]}
                </span>
                <button
                  className="secondary"
                  disabled={reopen.isPending}
                  aria-label={`Reabrir simulação de ${p.title}`}
                  onClick={() => reopen.mutate(p.id)}
                >
                  <FlaskConical size={14} />
                  Reabrir
                </button>
              </article>
            ))}
          </div>
        )}
      </section>
      <div className="bottom-note">
        <ShieldCheck size={18} />
        <p>
          <strong>A biblioteca fica com os seus Arr.</strong> O Prontarr planeja
          a sequência. Importação e substituição continuam sendo
          responsabilidade do Radarr e Sonarr na futura integração.
        </p>
      </div>
    </>
  );
}
function ErrorNotice({ error }: { error: Error | null }) {
  return error ? (
    <p className="error" role="alert">
      {error.message}
    </p>
  ) : null;
}
function PolicyEditor() {
  const policy = useQuery({
    queryKey: ["policy"],
    queryFn: () => api<Policy>("/policy"),
  });
  if (policy.isPending) return <p>Carregando política…</p>;
  if (policy.isError) return <ErrorNotice error={policy.error} />;
  return <PolicyForm initial={policy.data} />;
}
function PolicyForm({ initial }: { initial: Policy }) {
  const [draft, setDraft] = useState(initial);
  const client = useQueryClient();
  const save = useMutation({
    mutationFn: () => api<Policy>("/policy", draft, "PUT"),
    onSuccess: () => client.invalidateQueries({ queryKey: ["policy"] }),
  });
  function update(patch: Partial<Policy>) {
    setDraft({ ...draft, ...patch });
    save.reset();
  }
  return (
    <>
      <div className="page-heading">
        <div>
          <span className="eyebrow">PRIMEIRA CÓPIA</span>
          <h1>Política de download</h1>
          <p>
            Valores padrão para novas simulações. O limite é para o torrent
            inteiro.
          </p>
        </div>
      </div>
      <form
        className="card form-card"
        onSubmit={(e) => {
          e.preventDefault();
          save.mutate();
        }}
      >
        <div className="form-grid">
          <label>
            Tamanho máximo (GiB)
            <input
              type="number"
              min="0.1"
              step="0.1"
              required
              value={draft.max_compact_bytes / GiB}
              onChange={(e) =>
                update({
                  max_compact_bytes: Math.round(Number(e.target.value) * GiB),
                })
              }
            />
          </label>
          <label>
            Mínimo de seeds
            <input
              type="number"
              min="1"
              step="1"
              required
              value={draft.min_seeders}
              onChange={(e) => update({ min_seeders: Number(e.target.value) })}
            />
          </label>
          <label>
            Resolução mínima
            <select
              value={draft.min_resolution}
              onChange={(e) =>
                update({ min_resolution: Number(e.target.value) })
              }
            >
              <option value={720}>720p</option>
              <option value={1080}>1080p</option>
            </select>
          </label>
          <label>
            Resolução máxima
            <select
              value={draft.max_resolution}
              onChange={(e) =>
                update({ max_resolution: Number(e.target.value) })
              }
            >
              <option value={720}>720p</option>
              <option value={1080}>1080p</option>
            </select>
          </label>
        </div>
        <div className="info-line">
          <ShieldCheck size={18} />
          <span>
            Áudio original, aprovação pelo Arr e exclusão de remux são
            obrigatórios nesta versão.
          </span>
        </div>
        <ErrorNotice error={save.error} />
        <div className="form-actions">
          <button className="primary" disabled={save.isPending}>
            Salvar política
          </button>
          {save.isSuccess && (
            <span className="success" role="status">
              <Check size={16} />
              Política salva
            </span>
          )}
        </div>
      </form>
    </>
  );
}
function Simulator({ initial }: { initial?: Input }) {
  const policy = useQuery({
    queryKey: ["policy"],
    queryFn: () => api<Policy>("/policy"),
  });
  if (!policy.data)
    return policy.isError ? (
      <ErrorNotice error={policy.error} />
    ) : (
      <p>Carregando política…</p>
    );
  return (
    <SimulatorForm
      key={initial ? JSON.stringify(initial) : "new"}
      policy={policy.data}
      initial={initial}
    />
  );
}
function SimulatorForm({
  policy,
  initial,
}: {
  policy: Policy;
  initial?: Input;
}) {
  const [input, setInput] = useState<Input>(
    initial ?? {
      title: "",
      policy,
      snapshot: {
        stage: "missing",
        imported_episodes: 0,
        expected_episodes: 1,
        upgrade_import_confirmed: false,
      },
      candidates: [],
    },
  );
  const [decision, setDecision] = useState<Decision | null>(null);
  const client = useQueryClient();
  const simulate = useMutation({
    mutationFn: () => api<Decision>("/simulate", input),
    onSuccess: setDecision,
  });
  const save = useMutation({
    mutationFn: () => api("/plans", input),
    onSuccess: () => client.invalidateQueries({ queryKey: ["plans"] }),
  });
  function update(next: Input) {
    setInput(next);
    setDecision(null);
    simulate.reset();
    save.reset();
  }
  function candidate(index: number, patch: Partial<Candidate>) {
    update({
      ...input,
      candidates: input.candidates.map((c, i) =>
        i === index ? { ...c, ...patch } : c,
      ),
    });
  }
  function example() {
    update({
      title: "Filme de exemplo",
      policy,
      snapshot: {
        stage: "missing",
        expected_episodes: 1,
        imported_episodes: 0,
        upgrade_import_confirmed: false,
      },
      candidates: [
        {
          id: "example-compact",
          title: "1080p · compacto · áudio original",
          bytes: 2 * GiB,
          seeders: 120,
          resolution: 1080,
          original_audio: true,
          arr_approved: true,
          remux: false,
        },
        {
          id: "example-large",
          title: "2160p · HDR · áudio original",
          bytes: 35 * GiB,
          seeders: 80,
          resolution: 2160,
          original_audio: true,
          arr_approved: true,
          remux: false,
        },
      ],
    });
  }
  return (
    <>
      <div className="page-heading">
        <div>
          <span className="eyebrow">DECISÕES EXPLICÁVEIS</span>
          <h1>Simulador de downloads</h1>
          <p>
            Informe candidatos e o estado de importação. Nenhuma ação será
            executada.
          </p>
        </div>
        <button
          className="secondary"
          disabled={simulate.isPending || save.isPending}
          onClick={example}
        >
          Carregar exemplo
        </button>
      </div>
      <form
        onSubmit={(e) => {
          e.preventDefault();
          simulate.mutate();
        }}
      >
        <fieldset disabled={simulate.isPending || save.isPending}>
          <div className="card form-card">
            <h2>O que estamos planejando?</h2>
            <div className="form-grid">
              <label>
                Título
                <input
                  required
                  maxLength={300}
                  placeholder="Filme ou série"
                  value={input.title}
                  onChange={(e) => update({ ...input, title: e.target.value })}
                />
              </label>
              <label>
                Etapa atual
                <select
                  value={input.snapshot.stage}
                  onChange={(e) =>
                    update({
                      ...input,
                      snapshot: {
                        ...input.snapshot,
                        stage: e.target.value as Stage,
                      },
                    })
                  }
                >
                  {Object.entries(stageNames).map(([k, v]) => (
                    <option key={k} value={k}>
                      {v}
                    </option>
                  ))}
                </select>
              </label>
              <label>
                Itens no escopo
                <input
                  type="number"
                  min="1"
                  max="1000"
                  required
                  value={input.snapshot.expected_episodes}
                  onChange={(e) =>
                    update({
                      ...input,
                      snapshot: {
                        ...input.snapshot,
                        expected_episodes: Number(e.target.value),
                      },
                    })
                  }
                />
                <small>
                  1 para filme ou episódio; total de episódios para pacote.
                </small>
              </label>
              <label>
                Itens com arquivo importado
                <input
                  type="number"
                  min="0"
                  max={input.snapshot.expected_episodes}
                  required
                  value={input.snapshot.imported_episodes}
                  onChange={(e) =>
                    update({
                      ...input,
                      snapshot: {
                        ...input.snapshot,
                        imported_episodes: Number(e.target.value),
                      },
                    })
                  }
                />
              </label>
            </div>
            <label className="checkbox">
              <input
                type="checkbox"
                checked={input.snapshot.upgrade_import_confirmed}
                onChange={(e) =>
                  update({
                    ...input,
                    snapshot: {
                      ...input.snapshot,
                      upgrade_import_confirmed: e.target.checked,
                    },
                  })
                }
              />
              Importação do upgrade confirmada para todos os itens
            </label>
          </div>
          <section className="section">
            <div className="section-heading">
              <h2>Versões candidatas</h2>
              <button
                type="button"
                className="text-button"
                onClick={() =>
                  update({
                    ...input,
                    candidates: [
                      ...input.candidates,
                      {
                        id: crypto.randomUUID(),
                        title: "Nova versão",
                        bytes: 2 * GiB,
                        seeders: 10,
                        resolution: 1080,
                        original_audio: true,
                        arr_approved: true,
                        remux: false,
                      },
                    ],
                  })
                }
              >
                <Plus size={16} />
                Adicionar
              </button>
            </div>
            <p className="muted">
              Limite: {(input.policy.max_compact_bytes / GiB).toFixed(1)} GiB ·{" "}
              {input.policy.min_seeders}+ seeds · {input.policy.min_resolution}–
              {input.policy.max_resolution}p. Valores de seeds são estimativas.
            </p>
            {input.candidates.length === 0 && (
              <div className="candidate-empty">
                Adicione versões ou carregue o exemplo para comparar.
              </div>
            )}
            {input.candidates.map((c, i) => (
              <div
                className={`card candidate ${decision?.candidate_id === c.id ? "selected" : ""}`}
                key={c.id}
              >
                <div className="candidate-heading">
                  <span className="candidate-number">
                    {String(i + 1).padStart(2, "0")}
                  </span>
                  <label className="candidate-title">
                    <span className="sr-only">Nome da versão {i + 1}</span>
                    <input
                      required
                      value={c.title}
                      onChange={(e) => candidate(i, { title: e.target.value })}
                    />
                  </label>
                  <button
                    className="icon-button"
                    type="button"
                    aria-label={`Remover versão ${i + 1}`}
                    onClick={() =>
                      update({
                        ...input,
                        candidates: input.candidates.filter((_, n) => n !== i),
                      })
                    }
                  >
                    <Trash2 size={17} />
                  </button>
                </div>
                <div className="form-grid three">
                  <label>
                    Tamanho (GiB)
                    <input
                      required
                      type="number"
                      min="0.01"
                      step="0.01"
                      value={c.bytes / GiB}
                      onChange={(e) =>
                        candidate(i, {
                          bytes: Math.round(Number(e.target.value) * GiB),
                        })
                      }
                    />
                  </label>
                  <label>
                    Seeds
                    <input
                      required
                      type="number"
                      min="0"
                      step="1"
                      value={c.seeders}
                      onChange={(e) =>
                        candidate(i, { seeders: Number(e.target.value) })
                      }
                    />
                  </label>
                  <label>
                    Resolução
                    <select
                      value={c.resolution}
                      onChange={(e) =>
                        candidate(i, { resolution: Number(e.target.value) })
                      }
                    >
                      {[480, 720, 1080, 2160].map((r) => (
                        <option key={r} value={r}>
                          {r}p
                        </option>
                      ))}
                    </select>
                  </label>
                </div>
                <div className="checks">
                  <label className="checkbox">
                    <input
                      type="checkbox"
                      checked={c.original_audio}
                      onChange={(e) =>
                        candidate(i, { original_audio: e.target.checked })
                      }
                    />
                    Áudio original
                  </label>
                  <label className="checkbox">
                    <input
                      type="checkbox"
                      checked={c.arr_approved}
                      onChange={(e) =>
                        candidate(i, { arr_approved: e.target.checked })
                      }
                    />
                    Aprovado pelo Arr
                  </label>
                  <label className="checkbox">
                    <input
                      type="checkbox"
                      checked={c.remux}
                      onChange={(e) =>
                        candidate(i, { remux: e.target.checked })
                      }
                    />
                    Remux
                  </label>
                </div>
                {decision?.candidate_id === c.id && (
                  <span className="selected-label">
                    <Check size={14} />
                    Escolhida na simulação
                  </span>
                )}
              </div>
            ))}
          </section>
          <ErrorNotice error={simulate.error} />
          <button className="primary" disabled={simulate.isPending}>
            <FlaskConical size={17} />
            {simulate.isPending ? "Avaliando…" : "Simular decisão"}
          </button>
        </fieldset>
      </form>
      {decision && (
        <section className="decision" aria-live="polite">
          <span className="eyebrow">PRÓXIMA AÇÃO · SIMULADA</span>
          <h2>{actionNames[decision.action]}</h2>
          <p>{decision.reason}</p>
          <div className="form-actions">
            <button
              className="secondary"
              disabled={save.isPending || save.isSuccess}
              onClick={() => save.mutate()}
            >
              {save.isSuccess ? (
                <>
                  <Check size={16} />
                  Plano salvo
                </>
              ) : (
                "Salvar no histórico"
              )}
            </button>
            <span className="muted">Nenhum comando enviado aos seus apps.</span>
          </div>
          <ErrorNotice error={save.error} />
        </section>
      )}
    </>
  );
}
createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <QueryClientProvider client={queryClient}>
      <App />
    </QueryClientProvider>
  </React.StrictMode>,
);
