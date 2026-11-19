import test from "node:test";
import assert from "node:assert/strict";
import {
  matchesJob,
  isJobFilter,
  jobErrorMessages,
  sortJobs,
  isJobSort,
  isJobApp,
} from "../src/job-utils.ts";
import en from "../src/locales/en.json" with { type: "json" };
import pt from "../src/locales/pt-BR.json" with { type: "json" };
const job = (stage: string) => ({
  title: "Amélie",
  stage,
  target: { app: "radarr" },
});
test("plan search ignores accents and combines with lifecycle filters", () => {
  assert.equal(matchesJob(job("upgrading"), " AMELIE ", "active"), true);
  assert.equal(matchesJob(job("upgrading"), "radarr", "active"), true);
  assert.equal(matchesJob(job("upgrading"), "sonarr", "all"), false);
  for (const stage of [
    "queued",
    "analyzing",
    "claiming",
    "compact",
    "upgrading",
  ]) {
    assert.equal(matchesJob(job(stage), "", "active"), true);
    assert.equal(matchesJob(job(stage), "", "finished"), false);
  }
  for (const stage of ["ready", "review"]) {
    assert.equal(matchesJob(job(stage), "", "attention"), true);
    assert.equal(matchesJob(job(stage), "", "active"), false);
  }
  for (const stage of ["completed", "cancelled"]) {
    assert.equal(matchesJob(job(stage), "", "finished"), true);
    assert.equal(matchesJob(job(stage), "", "attention"), false);
  }
  assert.equal(matchesJob(job("future-stage"), "", "all"), true);
  assert.equal(matchesJob(job("future-stage"), "", "active"), false);
});
test("stored filters reject invalid values and all recovery guidance is translated", () => {
  for (const value of [null, {}, 1, "broken"])
    assert.equal(isJobFilter(value), false);
  for (const value of ["all", "active", "attention", "finished"])
    assert.equal(isJobFilter(value), true);
  for (const message of Object.values(jobErrorMessages)) {
    assert.ok((en as Record<string, string>)[message]);
    assert.ok((pt as Record<string, string>)[message]);
  }
});

test("plan ordering is numeric, deterministic and preserves cached query data", () => {
  const rows = Object.freeze([
    { id: 3, title: "Part 10", updated_at_ms: 200 },
    { id: 2, title: "Part 2", updated_at_ms: 100 },
    { id: 1, title: "Álpha", updated_at_ms: 200 },
  ]);
  assert.deepEqual(
    sortJobs(rows, "updated", "en").map((x) => x.id),
    [1, 3, 2],
  );
  assert.deepEqual(
    sortJobs(rows, "oldest", "en").map((x) => x.id),
    [2, 1, 3],
  );
  assert.deepEqual(
    sortJobs(rows, "title", "en").map((x) => x.id),
    [1, 2, 3],
  );
  assert.deepEqual(
    rows.map((x) => x.id),
    [3, 2, 1],
  );
  assert.deepEqual(sortJobs([], "updated", "pt-BR"), []);
});
test("plan application and sorting preferences reject corrupt browser values", () => {
  for (const value of [null, {}, [], 2, "unknown"]) {
    assert.equal(isJobApp(value), false);
    assert.equal(isJobSort(value), false);
  }
  for (const value of ["all", "radarr", "sonarr"])
    assert.equal(isJobApp(value), true);
  for (const value of ["updated", "oldest", "title"])
    assert.equal(isJobSort(value), true);
});
