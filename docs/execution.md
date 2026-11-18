# Controlled execution

Execution is disabled by default. Analysis is separate from execution: creating or reanalyzing a plan performs native GET searches, never grabs a release.

## Configuration

Add these fields to the private connections file (mode 0600), alongside the existing Arr/qBittorrent adapters:

```json
{
  "coordinator": {"url": "http://127.0.0.1:18106", "basic_auth": "username:secret"},
  "vpn_health": {"url": "http://127.0.0.1:18105"},
  "execution": {"enabled": true, "allowed_movie_ids": [48], "allowed_series_ids": []}
}
```

IDs above are examples. Use your own allowlist. Secrets must never be committed or returned to the browser. The VPN endpoint must return `{"healthy": true}`. The coordinator must durably implement authenticated `/ownership/claim` and `/ownership/release`, refusing scopes already owned by the legacy controller or a different Prontarr job. It must use the same lock as legacy event/reconciliation processing. There is deliberately no expiring lease: a crash cannot let a second controller silently take over.

`integrations/prontarr_ownership.py` supplies the durable gate; `patch_legacy.py` targets the known legacy Python controller, checks source layout and refuses an already patched source. It is not a universal installer. Preserve the previous controller before applying a patch. Restore it only after cancelling/releasing Prontarr plans and confirming that no scope remains externally owned.

## Lifecycle and recovery

1. Analyze native profile, language, approved releases, current file identities and optional torrent manifest.
2. Review selected compact and upgrade sources; starting requires a fresh analysis and an explicitly allowed title.
3. Claim exclusive ownership, verify VPN health, persist the intended effect, then request the compact source through Arr.
4. Wait for native file identities proving every selected item is available.
5. Compare the selected upgrade with the newly imported files using native quality groups, formats, minimum improvement and cutoffs. Keep the first copy available while the upgrade downloads.
6. Confirm replacement file identities and target quality/formats, then release ownership. Arr performs the library replacement. Prontarr never deletes a library file or torrent.

Effects marked `sending`, `sent` or `uncertain` are never blindly submitted again after restart. An ambiguous network result is reconciled against the native queue or import. Cancellation releases ownership, preserves downloads and restores only an original torrent previously paused by this controller. A failed job can retain ownership until explicitly cancelled; restarting the process does not transfer control to the old script.

Only one process may operate a database, enforced by an OS file lock. Database, WAL and SHM are private. Jobs/events survive restarts. Client polling pauses automatically in hidden tabs through TanStack Query defaults.

## Current limitations

- Real execution is a narrow pilot. General automatic intake of all requests is not enabled.
- Movies and individually selected series episodes can be planned. Manifest inspection supports packs, but searching/grabbing multiple compact episode releases within one plan is not implemented yet.
- Plans referencing an existing original torrent cannot start until its exact quality/formats and resume path are fully verified. No existing torrent is paused by these plans.
- Seed counts are a heuristic, not measured throughput. There is no automatic compact-source replacement yet; the first import has a six-hour deadline and then requires review.
- Unknown current custom-format scores block same-quality upgrades. Proper/repack equivalence is conservative.
- Native RSS, native/manual searches, Cleanuparr and other tools retain their own behavior; the ownership gate coordinates the legacy fast-first script, not every third-party actor.
- Native imports and filesystem availability determine completion. Successful mocked lifecycle tests are not proof that a real torrent has finished.

## API

`GET/POST /api/jobs`, `GET /api/jobs/:id`, `POST /api/jobs/:id/start`, `/cancel`, `/analyze`; `GET /api/library` and `/api/library/sonarr/:id/episodes`. Reports expose sanitized candidates, not indexer GUIDs, download URLs, API credentials or ownership tokens.

## Initial and final profiles

In **Settings → Download profiles**, choose an initial and final profile separately for Radarr movies and Sonarr series. `GET /api/profiles` discovers actual native profile IDs, names, allowed qualities, minimum format score and upgrade permission; errors are isolated per application. `PUT /api/policy` validates selected IDs against the relevant service before saving.

`radarr_profiles` and `sonarr_profiles` each accept `{"initial_id": 4, "final_id": 1}`. Null means use the profile associated with each title. IDs are local to each Arr instance, not interchangeable.

The initial profile filters allowed qualities and custom-format minimums in addition to compact size, resolution and seed limits. The final profile determines quality ranking, format scores and upgrade cutoffs. Scores are recalculated from matched custom-format IDs using the selected profile's weights; an alternate profile cannot use a score calculated for a different profile when format metadata is missing.

Native approval, original audio and the existing rejection/blocklist protections remain mandatory. Selecting a different profile does not edit the title's native `qualityProfileId` or bypass native rejections. A stricter native title profile may therefore prevent a source that the initial profile would otherwise allow.

Jobs retain their policy snapshot. Saving defaults affects new jobs; **Reanalyze with current defaults** explicitly adopts current settings for a stopped/ready plan. Running plans must be cancelled before reanalysis. Existing simulations and jobs without selection fields remain compatible and use the title's profile.
