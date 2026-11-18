import { t, locale } from "./i18n.ts";
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
      <h2>{t("Two-stage profiles")}</h2>
      <p>
        {t(
          "Choose Arr profiles to filter the first copy and set the final target. The compact limits below also apply to the first copy.",
        )}
      </p>
      <p className="muted">
        {t(
          "The title profile in Arr remains a safeguard: rejected releases are not allowed here. These choices do not change the title profile in Radarr or Sonarr.",
        )}
      </p>
      <button
        type="button"
        className="secondary"
        onClick={() => void profiles.refetch()}
        disabled={profiles.isFetching}
      >
        {profiles.isFetching
          ? t("Loading profiles…")
          : t("Refresh Arr profiles")}
      </button>
      {profiles.error && (
        <p className="error" role="alert">
          {t(profiles.error.message)}
        </p>
      )}
      {(["radarr", "sonarr"] as const).map((app) => {
        const key = app === "radarr" ? "radarr_profiles" : "sonarr_profiles";
        const pair = value[key] ?? empty;
        const service = profiles.data?.services.find((s) => s.app === app);
        return (
          <fieldset className="profile-service" key={app}>
            <legend>
              {app === "radarr" ? t("Movies · Radarr") : t("Series · Sonarr")}
            </legend>
            {service?.error_code && (
              <p className="error" role="alert">
                {t("Could not load profiles from")}
                {app}
                {t(". Check the connection and refresh the list.")}
              </p>
            )}
            <div className="form-grid">
              {(["initial_id", "final_id"] as const).map((field) => {
                const id = pair[field];
                const selected = service?.items.find((p) => p.id === id);
                return (
                  <label key={field}>
                    {field === "initial_id"
                      ? t("Initial profile · first copy")
                      : t("Final profile · upgrade target")}
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
                          ? t("Automatic · title profile + compact limits")
                          : t("Automatic · title profile")}
                      </option>
                      {id != null && !selected && (
                        <option value={id}>
                          {profiles.isFetching
                            ? t("Loading")
                            : t("Unavailable")}{" "}
                          {t("· profile #")}
                          {id}
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
                          t("No allowed qualities")}
                        {t(". Minimum score:")}
                        {selected.min_format_score}.
                        {field === "final_id" && !selected.upgrade_allowed
                          ? t(" Upgrades are disabled in this profile.")
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
        {t(
          "Saving changes defaults for new plans. Existing plans keep their criteria until you use “Reanalyze with current defaults”. Cancel a running plan before reanalyzing it.",
        )}
      </p>
    </section>
  );
}
