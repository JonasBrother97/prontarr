import { useTranslation } from "react-i18next";
import { t, locale, setLanguage } from "./i18n.ts";
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
import { ProfilesSettings, type ProfileChoices } from "./Profiles";
import { Jobs } from "./Jobs";
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
type Policy = ProfileChoices & {
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
  missing: "No copy",
  compact_downloading: "First copy",
  watchable: "Available",
  upgrading: "Upgrade",
  complete: "Completed",
};
const actionNames: Record<string, string> = {
  wait: "Wait",
  download_compact: "Choose compact release",
  search_upgrade: "Search for upgrade",
  keep_available: "Keep available copy",
  complete: "Complete plan",
};
const queryClient = new QueryClient({
  defaultOptions: { queries: { retry: 1, refetchOnWindowFocus: false } },
});

function App() {
  useTranslation();
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
      page === "live" || page === "jobs"
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
    queryFn: () =>
      api<{ status: string; live_actions_enabled: boolean }>("/health"),
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
          aria-label={t("Close menu")}
          onClick={() => {
            setMobileMenu(false);
            menuTrigger.current?.focus();
          }}
        />
      )}
      <aside
        className="sidebar"
        id="sidebar"
        aria-label={t("Sidebar")}
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
        <nav className="arr-navigation" aria-label={t("Main navigation")}>
          <button
            className={`nav-main ${page === "dashboard" ? "active" : ""}`}
            aria-current={page === "dashboard" ? "page" : undefined}
            onClick={() => navigate("dashboard")}
          >
            <LayoutDashboard size={20} />
            <span>{t("Overview")}</span>
          </button>
          <div className="nav-group">
            <button
              className={`nav-main nav-group-toggle ${page === "live" ? "group-selected" : ""}`}
              aria-expanded={groups.activity}
              aria-controls="nav-activity"
              onClick={() => toggleGroup("activity")}
            >
              <Activity size={20} />
              <span>{t("Activity")}</span>
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
                  {t("Download queue")}
                </button>
                <button
                  className={page === "jobs" ? "active" : ""}
                  aria-current={page === "jobs" ? "page" : undefined}
                  onClick={() => navigate("jobs")}
                >
                  {t("Execution plans")}
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
              <span>{t("Tools")}</span>
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
                  {t("Simulator")}
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
              <span>{t("Settings")}</span>
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
                  {t("Download profiles")}
                </button>
              </div>
            )}
          </div>
        </nav>
        <div className="sidebar-foot">
          <span className={`dot ${health.isSuccess ? "green" : ""}`} />
          {health.isSuccess
            ? t("System online")
            : health.isError
              ? t("System unavailable")
              : t("Connecting…")}
          <small>
            {t("v{{version}} · Alpha", { version: "0.4.0-alpha.2" })}
          </small>
        </div>
      </aside>
      <main>
        <header className="topbar">
          <div className="toolbar-leading">
            <button
              ref={menuTrigger}
              className="sidebar-toggle"
              aria-label={mobileMenu ? t("Close sidebar") : t("Toggle sidebar")}
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
                    dashboard: t("Overview"),
                    live: "Downloads",
                    jobs: t("Execution plans"),
                    simulator: t("Simulator"),
                    policy: t("Download profiles"),
                  }[page]
                }
              </strong>
            </div>
          </div>
          <div className="toolbar-preferences">
            <label className="language-picker">
              <span className="sr-only">{t("Language")}</span>
              <select
                aria-label={t("Language")}
                value={locale()}
                onChange={(e) =>
                  void setLanguage(e.target.value as "en" | "pt-BR")
                }
              >
                <option value="en">English</option>
                <option value="pt-BR">Português</option>
              </select>
            </label>
            <span className="mode">
              <ShieldCheck size={14} />
              {health.data?.live_actions_enabled
                ? t("Controlled execution")
                : t("Analysis only")}
            </span>
          </div>
        </header>
        <div className="content">
          <div className="notice">
            <FlaskConical size={16} />
            <span>
              {health.data?.live_actions_enabled
                ? t(
                    "Execution is limited to authorized titles. Sonarr and Radarr handle file imports and replacement.",
                  )
                : t(
                    "Live release analysis and simulation. Download execution is disabled.",
                  )}
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
          {page === "jobs" && <Jobs />}
        </div>
        <footer>
          PRONTARR <span>{t("A watchable copy now. A better one later.")}</span>
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
          <span className="eyebrow">{t("TWO-STAGE DOWNLOADS")}</span>
          <h1>{t("Overview")}</h1>
          <p>{t("First a compact copy. Then the quality you want.")}</p>
        </div>
        <button className="primary" onClick={onStart}>
          <Plus size={17} />
          {t("New simulation")}
        </button>
      </section>
      <section className="pipeline" aria-label={t("Strategy stages")}>
        {[
          ["01", t("Find a copy"), t("Balance size and availability.")],
          [
            "02",
            t("Make it watchable"),
            t("Confirm import for the entire scope."),
          ],
          [
            "03",
            t("Improve quality"),
            t("Keep the copy until the upgrade arrives."),
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
          <h2>{t("Simulation plans")}</h2>
          <span className="count">
            {t("savedPlans", { count: plans.data?.items.length ?? 0 })}
          </span>
        </div>
        {plans.isPending ? (
          <p role="status">{t("Loading plans…")}</p>
        ) : plans.isError ? (
          <ErrorNotice error={plans.error} />
        ) : plans.data.items.length === 0 ? (
          <div className="empty">
            <span className="empty-icon">
              <Layers3 size={28} />
            </span>
            <h3>{t("Your first plan starts here")}</h3>
            <p>
              {t(
                "Compare releases and see why the engine chose the next action.",
              )}
            </p>
            <button className="secondary" onClick={onStart}>
              {t("Open simulator")}
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
                  <p>{t(actionNames[p.decision.action])}</p>
                  <small>
                    {new Date(p.created_at).toLocaleString(locale())}
                  </small>
                </div>
                <span className="pill">
                  {t(stageNames[p.decision.next_stage])}
                </span>
                <button
                  className="secondary"
                  disabled={reopen.isPending}
                  aria-label={t("Reopen simulation for {{title}}", {
                    title: p.title,
                  })}
                  onClick={() => reopen.mutate(p.id)}
                >
                  <FlaskConical size={14} />
                  {t("Reopen")}
                </button>
              </article>
            ))}
          </div>
        )}
      </section>
      <div className="bottom-note">
        <ShieldCheck size={18} />
        <p>
          <strong>{t("Your Arr apps manage the library.")}</strong>{" "}
          {t(
            "Prontarr plans the sequence. Radarr and Sonarr handle imports and replacement.",
          )}
        </p>
      </div>
    </>
  );
}
function ErrorNotice({ error }: { error: Error | null }) {
  return error ? (
    <p className="error" role="alert">
      {t(error.message)}
    </p>
  ) : null;
}
function PolicyEditor() {
  const policy = useQuery({
    queryKey: ["policy"],
    queryFn: () => api<Policy>("/policy"),
  });
  if (policy.isPending) return <p>{t("Loading policy…")}</p>;
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
          <span className="eyebrow">{t("FIRST COPY AND UPGRADE")}</span>
          <h1>{t("Download profiles")}</h1>
          <p>
            {t(
              "Default profiles and limits for new plans and simulations. The size limit applies to the entire torrent.",
            )}
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
        <ProfilesSettings value={draft} onChange={update} />
        <h2>{t("First-copy limits")}</h2>
        <div className="form-grid">
          <label>
            {t("Maximum size (GiB)")}
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
            {t("Minimum seeders")}
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
            {t("Minimum resolution")}
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
            {t("Maximum resolution")}
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
            {t(
              "Original audio, Arr approval and remux exclusion are required in this version.",
            )}
          </span>
        </div>
        <ErrorNotice error={save.error} />
        <div className="form-actions">
          <button type="submit" className="primary" disabled={save.isPending}>
            {t("Save policy")}
          </button>
          {save.isSuccess && (
            <span className="success" role="status">
              <Check size={16} />
              {t("Policy saved")}
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
      <p>{t("Loading policy…")}</p>
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
      title: t("Example movie"),
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
          title: t("1080p · compact · original audio"),
          bytes: 2 * GiB,
          seeders: 120,
          resolution: 1080,
          original_audio: true,
          arr_approved: true,
          remux: false,
        },
        {
          id: "example-large",
          title: t("2160p · HDR · original audio"),
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
          <span className="eyebrow">{t("EXPLAINABLE DECISIONS")}</span>
          <h1>{t("Download simulator")}</h1>
          <p>
            {t(
              "Enter candidates and import status. No actions will be executed.",
            )}
          </p>
        </div>
        <button
          className="secondary"
          disabled={simulate.isPending || save.isPending}
          onClick={example}
        >
          {t("Load example")}
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
            <h2>{t("What are we planning?")}</h2>
            <div className="form-grid">
              <label>
                {t("Title")}
                <input
                  required
                  maxLength={300}
                  placeholder={t("Movie or series")}
                  value={input.title}
                  onChange={(e) => update({ ...input, title: e.target.value })}
                />
              </label>
              <label>
                {t("Current stage")}
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
                      {t(v)}
                    </option>
                  ))}
                </select>
              </label>
              <label>
                {t("Items in scope")}
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
                  {t("1 for a movie or episode; total episodes for a pack.")}
                </small>
              </label>
              <label>
                {t("Items with imported files")}
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
              {t("Upgrade import confirmed for all items")}
            </label>
          </div>
          <section className="section">
            <div className="section-heading">
              <h2>{t("Candidate releases")}</h2>
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
                        title: t("New release"),
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
                {t("Add")}
              </button>
            </div>
            <p className="muted">
              {t(
                "Limit: {{size}} GiB · {{seeds}}+ seeds · {{min}}–{{max}}p. Seeder counts are estimates.",
                {
                  size: (input.policy.max_compact_bytes / GiB).toLocaleString(
                    locale(),
                    { minimumFractionDigits: 1, maximumFractionDigits: 1 },
                  ),
                  seeds: input.policy.min_seeders,
                  min: input.policy.min_resolution,
                  max: input.policy.max_resolution,
                },
              )}
            </p>
            {input.candidates.length === 0 && (
              <div className="candidate-empty">
                {t("Add releases or load the example to compare.")}
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
                    <span className="sr-only">
                      {t("Release name")} {i + 1}
                    </span>
                    <input
                      required
                      value={c.title}
                      onChange={(e) => candidate(i, { title: e.target.value })}
                    />
                  </label>
                  <button
                    className="icon-button"
                    type="button"
                    aria-label={t("Remove release {{number}}", {
                      number: i + 1,
                    })}
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
                    {t("Size (GiB)")}
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
                    {t("Resolution")}
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
                    {t("Original audio")}
                  </label>
                  <label className="checkbox">
                    <input
                      type="checkbox"
                      checked={c.arr_approved}
                      onChange={(e) =>
                        candidate(i, { arr_approved: e.target.checked })
                      }
                    />
                    {t("Approved by Arr")}
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
                    {t("Selected in simulation")}
                  </span>
                )}
              </div>
            ))}
          </section>
          <ErrorNotice error={simulate.error} />
          <button
            type="submit"
            className="primary"
            disabled={simulate.isPending}
          >
            <FlaskConical size={17} />
            {simulate.isPending ? t("Evaluating…") : t("Simulate decision")}
          </button>
        </fieldset>
      </form>
      {decision && (
        <section className="decision" aria-live="polite">
          <span className="eyebrow">{t("NEXT ACTION · SIMULATED")}</span>
          <h2>{t(actionNames[decision.action])}</h2>
          <p>{t(decision.reason)}</p>
          <div className="form-actions">
            <button
              className="secondary"
              disabled={save.isPending || save.isSuccess}
              onClick={() => save.mutate()}
            >
              {save.isSuccess ? (
                <>
                  <Check size={16} />
                  {t("Plan saved")}
                </>
              ) : (
                t("Save to history")
              )}
            </button>
            <span className="muted">
              {t("No commands were sent to your apps.")}
            </span>
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
