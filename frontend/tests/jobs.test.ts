import test from "node:test";
import assert from "node:assert/strict";
import { matchesJob, isJobFilter, jobErrorMessages } from "../src/job-utils.ts";
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
