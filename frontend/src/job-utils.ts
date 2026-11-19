import { normalizeSearch } from "./download-utils.ts";
export type JobFilter = "all" | "active" | "attention" | "finished";
export function isJobFilter(value: unknown): value is JobFilter {
  return ["all", "active", "attention", "finished"].includes(value as string);
}
export function matchesJob(
  job: { title: string; stage: string; target: { app: string } },
  query: string,
  filter: JobFilter,
): boolean {
  const search = normalizeSearch(query);
  if (!normalizeSearch(`${job.title} ${job.target.app}`).includes(search))
    return false;
  if (filter === "attention") return ["ready", "review"].includes(job.stage);
  if (filter === "finished")
    return ["completed", "cancelled"].includes(job.stage);
  if (filter === "active")
    return ["queued", "analyzing", "claiming", "compact", "upgrading"].includes(
      job.stage,
    );
  return true;
}
export const jobErrorMessages: Record<string, string> = {
  NoCompactCandidate:
    "No suitable first copy was found. Check the initial profile and size limits, then reanalyze. An existing download is left unchanged.",
  VpnNotHealthy:
    "The download VPN is unhealthy. Active plans wait for recovery; plans needing attention must be reanalyzed.",
  UpstreamUnavailable:
    "An upstream service is temporarily unavailable. Active plans retry automatically; plans needing attention must be reanalyzed.",
  UpstreamTimeout:
    "An upstream service timed out. Check connectivity; uncertain download requests are not sent again automatically.",
  RespectManualPause:
    "The existing download was paused manually. Resume it in your download client before reanalyzing.",
  RespectExistingProgress:
    "The existing download has already made significant progress. It is preserved instead of being replaced with a first copy.",
  OwnershipConflict:
    "Another plan controls this download. Review the active plan before trying again.",
  NotAVerifiedUpgrade:
    "The proposed replacement could not be verified as an upgrade. Review the final profile and custom format scores.",
  CompactImportTimeout:
    "The first copy was not imported within six hours. Check the Arr queue and import errors before continuing.",
};
