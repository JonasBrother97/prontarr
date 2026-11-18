import test, { afterEach } from "node:test";
import assert from "node:assert/strict";
import { api, ApiError } from "../src/api.ts";
import {
  restorePreference,
  savePreference,
  pageFromHash,
} from "../src/preferences.ts";
import {
  matchesStatus,
  orderRows,
  freshness,
  normalizeSearch,
} from "../src/download-utils.ts";
const originalFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = originalFetch;
});

test("corrupt, oversized or blocked browser storage cannot crash the app", () => {
  const valid = (v: unknown): v is boolean => typeof v === "boolean";
  for (const raw of ["{broken", '"true"', "x".repeat(5000)])
    assert.equal(
      restorePreference({ getItem: () => raw }, "menu", valid, false),
      false,
    );
  assert.equal(
    restorePreference(
      {
        getItem: () => {
          throw new Error("blocked");
        },
      },
      "menu",
      valid,
      true,
    ),
    true,
  );
  assert.equal(
    savePreference(
      {
        setItem: () => {
          throw new Error("quota");
        },
      },
      "menu",
      true,
    ),
    false,
  );
  assert.equal(
    restorePreference({ getItem: () => "true" }, "menu", valid, false),
    true,
  );
});
test("deep links restore supported pages and reject unknown routes", () => {
  assert.equal(pageFromHash("#/settings"), "policy");
  assert.equal(pageFromHash("#/simulator"), "simulator");
  assert.equal(pageFromHash("#/overview"), "dashboard");
  assert.equal(pageFromHash("#/untrusted"), "live");
});
const paused = {
  name: "Episode 10",
  state: "stoppedDL",
  progress: 0.2,
  bytes: 100,
  download_speed: 0,
};
const active = {
  name: "Episode 2",
  state: "downloading",
  progress: 0.1,
  bytes: 200,
  download_speed: 100,
};
test("paused and missing torrents are not misclassified as active downloads", () => {
  assert.equal(matchesStatus(paused, "downloading"), false);
  assert.equal(matchesStatus(paused, "paused"), true);
  assert.equal(matchesStatus(null, "downloading"), false);
  assert.equal(matchesStatus(null, "review", "needs_review"), true);
  assert.equal(
    matchesStatus({ ...active, state: "missingFiles" }, "downloading"),
    false,
  );
  assert.equal(matchesStatus({ ...active, progress: 1 }, "completed"), true);
});
test("sorting is numeric, puts missing metadata last and never mutates input", () => {
  const rows = [paused, active];
  assert.equal(
    orderRows(
      rows,
      "name",
      (t) => t.name,
      (t) => t,
    )[0],
    active,
  );
  assert.equal(
    orderRows(
      rows,
      "speed",
      (t) => t.name,
      (t) => t,
    )[0],
    active,
  );
  assert.equal(
    orderRows(
      rows,
      "size",
      (t) => t.name,
      (t) => t,
    )[0],
    active,
  );
  assert.equal(
    orderRows(
      rows,
      "progress",
      (t) => t.name,
      (t) => t,
    )[0],
    active,
  );
  assert.equal(rows[0], paused);
  const mixed = [
    { name: "missing", torrent: null },
    { name: "active", torrent: active },
  ];
  assert.equal(
    orderRows(
      mixed,
      "speed",
      (t) => t.name,
      (t) => t.torrent,
    )[0].name,
    "active",
  );
});
test("search is accent-insensitive and stale data cannot look fresh", () => {
  assert.equal(normalizeSearch("  SÉRIE  "), "serie");
  assert.equal(freshness(100_000, 159_000).stale, false);
  assert.equal(freshness(100_000, 160_000).stale, true);
  assert.match(freshness(100_000, 3_700_000).label, /1 h/);
  assert.equal(freshness(200_000, 100_000).stale, true);
});
test("network and timeout errors receive useful messages", async () => {
  globalThis.fetch = async () => {
    throw new TypeError("Failed to fetch");
  };
  await assert.rejects(
    api("/health"),
    (e) =>
      e instanceof ApiError &&
      e.kind === "network" &&
      /connect/.test(e.message),
  );
  globalThis.fetch = async () => {
    throw new DOMException("timeout", "TimeoutError");
  };
  await assert.rejects(
    api("/health"),
    (e) => e instanceof ApiError && e.kind === "timeout",
  );
});
test("invalid HTML responses are not exposed as JSON parser errors", async () => {
  globalThis.fetch = async () =>
    new Response("<html>gateway failure</html>", { status: 502 });
  await assert.rejects(
    api("/health"),
    (e) => e instanceof ApiError && e.kind === "http" && e.status === 502,
  );
  globalThis.fetch = async () => new Response("invalid", { status: 200 });
  await assert.rejects(
    api("/health"),
    (e) => e instanceof ApiError && e.kind === "invalid_response",
  );
});
test("structured API errors preserve status and requests stay same-origin", async () => {
  let sent: RequestInit | undefined;
  globalThis.fetch = async (url, init) => {
    assert.equal(url, "/api/plans");
    sent = init;
    return Response.json(
      { error_message: "Plano não encontrado." },
      { status: 404 },
    );
  };
  await assert.rejects(
    api("/plans", { title: "Fixture" }),
    (e) =>
      e instanceof ApiError &&
      e.status === 404 &&
      e.message === "Plan not found.",
  );
  assert.equal(sent?.method, "POST");
  assert.equal(sent?.body, '{"title":"Fixture"}');
  globalThis.fetch = async () => Response.json({ status: "ok" });
  assert.deepEqual(await api("/health"), { status: "ok" });
});
