import i18next from "i18next";
import { initReactI18next } from "react-i18next";
import en from "./locales/en.json" with { type: "json" };
import pt from "./locales/pt-BR.json" with { type: "json" };
import legacy from "./locales/legacy.json" with { type: "json" };
export type Language = "en" | "pt-BR";
export function savedLanguage(storage?: Pick<Storage, "getItem">): Language {
  try {
    return storage?.getItem("prontarr:language") === "pt-BR" ? "pt-BR" : "en";
  } catch {
    return "en";
  }
}
const storage = (() => {
  try {
    return typeof window !== "undefined" ? window.localStorage : undefined;
  } catch {
    return undefined;
  }
})();
export const i18n = i18next.createInstance();
void i18n.use(initReactI18next).init({
  resources: { en: { translation: en }, "pt-BR": { translation: pt } },
  lng: savedLanguage(storage),
  fallbackLng: "en",
  supportedLngs: ["en", "pt-BR"],
  keySeparator: false,
  nsSeparator: false,
  initAsync: false,
  interpolation: { escapeValue: false },
  react: { useSuspense: false },
});
export function locale(): Language {
  return i18n.resolvedLanguage === "pt-BR" ? "pt-BR" : "en";
}
export function t(message: string, values?: Record<string, unknown>): string {
  const warning = message.match(
    /^(?:Arquivo sem escopo ou prioridade confirmados|File scope or priority is unconfirmed): (.*)$/s,
  );
  if (warning)
    return String(
      i18n.t("File scope or priority is unconfirmed: {{file}}", {
        file: warning[1],
      }),
    );
  const key = (legacy as Record<string, string>)[message] ?? message;
  return String(i18n.t(key, { ...values, defaultValue: key }));
}
export function setLanguage(language: Language) {
  try {
    storage?.setItem("prontarr:language", language);
  } catch {
    /* Preference storage may be blocked. */
  }
  return i18n.changeLanguage(language);
}
function updateDocument() {
  if (typeof document !== "undefined") document.documentElement.lang = locale();
}
i18n.on("languageChanged", updateDocument);
updateDocument();
