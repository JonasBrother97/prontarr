import { useQuery } from "@tanstack/react-query";
import { api } from "./api";
export type ProfilePair = {
  initial_id: number | null;
  final_id: number | null;
};
export type ProfileChoices = {
  radarr_profiles?: ProfilePair;
  sonarr_profiles?: ProfilePair;
};
type Profile = {
  id: number;
  name: string;
  qualities: string[];
  min_format_score: number;
  upgrade_allowed: boolean;
};
type Service = {
  app: "radarr" | "sonarr";
  items: Profile[];
  error_code: string | null;
};
const empty: ProfilePair = { initial_id: null, final_id: null };
export function ProfilesSettings({
  value,
  onChange,
}: {
  value: ProfileChoices;
  onChange: (patch: ProfileChoices) => void;
}) {
  const profiles = useQuery({
    queryKey: ["profiles"],
    queryFn: () => api<{ services: Service[] }>("/profiles"),
    retry: false,
  });
  return (
    <section className="profile-settings">
      <h2>Perfis das duas etapas</h2>
      <p>
        Escolha os perfis do Arr para filtrar a primeira cópia e definir o
        objetivo final. Os limites compactos abaixo também se aplicam à primeira
        cópia.
      </p>
      <p className="muted">
        O perfil associado ao título no Arr continua sendo uma proteção: fontes
        rejeitadas por ele não são liberadas aqui. As escolhas não alteram o
        perfil do título no Radarr ou Sonarr.
      </p>
      <button
        type="button"
        className="secondary"
        onClick={() => void profiles.refetch()}
        disabled={profiles.isFetching}
      >
        {profiles.isFetching
          ? "Consultando perfis…"
          : "Atualizar perfis do Arr"}
      </button>
      {profiles.error && (
        <p className="error" role="alert">
          {profiles.error.message}
        </p>
      )}
      {(["radarr", "sonarr"] as const).map((app) => {
        const key = app === "radarr" ? "radarr_profiles" : "sonarr_profiles";
        const pair = value[key] ?? empty;
        const service = profiles.data?.services.find((s) => s.app === app);
        return (
          <fieldset className="profile-service" key={app}>
            <legend>
              {app === "radarr" ? "Filmes · Radarr" : "Séries · Sonarr"}
            </legend>
            {service?.error_code && (
              <p className="error" role="alert">
                Não foi possível consultar os perfis do {app}. Verifique a
                conexão e atualize a lista.
              </p>
            )}
            <div className="form-grid">
              {(["initial_id", "final_id"] as const).map((field) => {
                const id = pair[field];
                const selected = service?.items.find((p) => p.id === id);
                return (
                  <label key={field}>
                    {field === "initial_id"
                      ? "Perfil inicial · primeira cópia"
                      : "Perfil final · objetivo do upgrade"}
                    <select
                      value={id ?? ""}
                      onChange={(e) =>
                        onChange({
                          [key]: {
                            ...pair,
                            [field]: e.target.value
                              ? Number(e.target.value)
                              : null,
                          },
                        })
                      }
                    >
                      <option value="">
                        {field === "initial_id"
                          ? "Automático · perfil do título + limites compactos"
                          : "Automático · perfil associado ao título"}
                      </option>
                      {id != null && !selected && (
                        <option value={id}>
                          {profiles.isFetching ? "Carregando" : "Indisponível"}{" "}
                          · perfil #{id}
                        </option>
                      )}
                      {service?.items.map((p) => (
                        <option key={p.id} value={p.id}>
                          {p.name}
                        </option>
                      ))}
                    </select>
                    {selected && (
                      <small>
                        {selected.qualities.join(", ") ||
                          "Nenhuma qualidade permitida"}
                        . Pontuação mínima: {selected.min_format_score}.
                        {field === "final_id" && !selected.upgrade_allowed
                          ? " Upgrades desativados neste perfil."
                          : ""}
                      </small>
                    )}
                  </label>
                );
              })}
            </div>
          </fieldset>
        );
      })}
      <p>
        Salvar altera os padrões para novos planos. Planos existentes mantêm
        seus critérios até você usar “Reanalisar com padrões atuais”. Um plano
        em execução precisa ser cancelado antes de reanalisar.
      </p>
    </section>
  );
}
