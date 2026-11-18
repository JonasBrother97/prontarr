import test, { afterEach } from "node:test";
import assert from "node:assert/strict";
import { i18n, t, locale, savedLanguage, setLanguage } from "../src/i18n.ts";
import en from "../src/locales/en.json" with { type: "json" };
import pt from "../src/locales/pt-BR.json" with { type: "json" };
afterEach(async () => {
  await setLanguage("en");
});
test("English is the default; corrupt or blocked storage safely falls back", () => {
  assert.equal(locale(), "en");
  for (const value of [null, "fr", "{broken", "pt", "en"]) {
    assert.equal(savedLanguage({ getItem: () => value }), "en");
  }
  assert.equal(savedLanguage({ getItem: () => "pt-BR" }), "pt-BR");
  assert.equal(
    savedLanguage({
      getItem: () => {
        throw Error("blocked");
      },
    }),
    "en",
  );
});
test("language changes localize live and legacy messages without changing metadata", async () => {
  assert.equal(t("Download profiles"), "Download profiles");
  assert.equal(t("selectedEpisodes", { count: 1 }), "1 selected episode");
  assert.equal(t("selectedEpisodes", { count: 2 }), "2 selected episodes");
  assert.equal(
    t("Primeira cópia em andamento; biblioteca preservada."),
    "First copy is downloading; library preserved.",
  );
  await setLanguage("pt-BR");
  assert.equal(locale(), "pt-BR");
  assert.equal(t("selectedEpisodes", { count: 1 }), "1 episódio selecionado");
  assert.equal(t("selectedEpisodes", { count: 2 }), "2 episódios selecionados");
  assert.equal(t("Download profiles"), "Perfis de download");
  assert.equal(
    t("First copy is downloading; library preserved."),
    "Primeira cópia em andamento; biblioteca preservada.",
  );
  assert.equal(
    t("Coisinhas - 4K HDR Original com fallback"),
    "Coisinhas - 4K HDR Original com fallback",
  );
  assert.equal(
    t("Arquivo sem escopo ou prioridade confirmados: Episode.mkv"),
    "Arquivo sem escopo ou prioridade confirmados: Episode.mkv",
  );
  await setLanguage("en");
  assert.equal(
    t("Arquivo sem escopo ou prioridade confirmados: Episode.mkv"),
    "File scope or priority is unconfirmed: Episode.mkv",
  );
  assert.equal(
    t("Progress for {{title}}", { title: "<My movie>" }),
    "Progress for <My movie>",
  );
});
test("both catalogs cover the same keys and preserve interpolation variables", () => {
  assert.deepEqual(Object.keys(en).sort(), Object.keys(pt).sort());
  const variables = (s: string) =>
    [...s.matchAll(/\{\{(\w+)\}\}/g)].map((m) => m[1]).sort();
  for (const [key, value] of Object.entries(en)) {
    assert.ok(value.trim(), key);
    assert.ok((pt as Record<string, string>)[key].trim(), key);
    assert.deepEqual(
      variables(value),
      variables((pt as Record<string, string>)[key]),
      key,
    );
  }
  assert.equal(i18n.hasResourceBundle("en", "translation"), true);
});
