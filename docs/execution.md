# Execution and recovery

Execution is disabled by default. Manual analysis performs native GET searches without grabbing a release. Automatic queue intake explicitly opts into analysis followed by guarded execution.

## Standalone configuration

Add these fields to a private connections file (mode 0600), alongside the Arr and qBittorrent adapters:

```json
{
  "vpn_health": {"url": "http://vpn-guard.example.test:18105"},
  "execution": {
    "enabled": true,
    "standalone": true,
    "automatic": true,
    "allowed_movie_ids": [48],
    "allowed_series_ids": [9],
    "download_removal_grace_seconds": 120
  }
}
```

IDs are examples. Start with a small allowlist. Set `allow_all_movies` and/or `allow_all_series` to true only when you intend to cover all monitored media in the corresponding Arr queue. Automatic mode requires standalone execution and checks queues every 15 seconds. A healthy VPN endpoint returning `{"healthy": true}` is mandatory before intake and upstream actions.

Standalone mode stores exclusive ownership in the same SQLite database as jobs and effects; no external ownership server is needed. Never operate two databases/controllers against the same media scope. Stop the previous controller and migrate a consistent database before switching ownership modes.

For reverse proxy deployment set `PRONTARR_BIND=0.0.0.0` and `PRONTARR_PUBLIC_URL=https://app.example.test`. Only the exact configured HTTPS host and origin are added to the default loopback allowlist. Authentication must be supplied by a proxy; restrict direct access to port 5882. This variable does not implement authentication.

### Legacy coexistence

With `standalone` left false, the earlier external coordinator remains supported via a private `coordinator` connection implementing authenticated `/ownership/claim` and `/ownership/release`. The helpers in `integrations/` target the original Python pilot and are migration tools, not required services for standalone deployment.

## Lifecycle and recovery

1. Analyze native profile, language, approved releases, current file identities and optional torrent manifest.
2. Review selected compact and upgrade sources, or let automatic mode start an allowed monitored queue item with a fresh analysis. Paused torrents, finished torrents and movies already in the library are skipped by intake.
3. Claim ownership and verify VPN health. Adopt a verified compact original without grabbing it again. Otherwise record recovery state, pause a verified larger original below 10% progress and request compact releases through Arr. Existing progress is preserved.
4. Wait for native file identities proving every selected item is available.
5. Resume the original larger torrent after compact imports, or compare the selected new upgrade with the newly imported files using native quality groups, formats, minimum improvement and cutoffs. Keep the first copy available while the upgrade downloads.
6. Confirm replacement file identities and target quality/formats, then release ownership. Arr performs the library replacement. Prontarr never deletes a library file or torrent.

Effects marked `sending`, `sent` or `uncertain` are never blindly submitted again after restart. An ambiguous network result is reconciled against the native queue or import. Cancellation releases ownership, preserves downloads and restores only an original torrent previously paused by this controller. A failed job can retain ownership until explicitly cancelled; restarting the process does not transfer control to the old script.

Only one process may operate a database, enforced by an OS file lock. Database, WAL and SHM are private. Jobs/events survive restarts. Client polling pauses automatically in hidden tabs through TanStack Query defaults.

## Current limitations

- This remains an experimental alpha. Unknown scope, quality, file identities, formats or upstream responses require review rather than guessed actions.
- Movies and selected episodes are supported. Pack manifests must identify selected video files exactly. Compact acquisition uses one single-episode release per missing episode, up to 64 episodes; it never assumes that all queue rows belong to actual files.
- Already imported episodes are excluded from compact acquisition. All selected missing episodes must import before an original pack resumes.
- A larger original at or above 10% progress is not interrupted. Manually paused originals are respected. Existing compact releases can be adopted even beyond that threshold.
- Only native queue-conflict rejection messages may be superseded for the first copy of a verified larger original. Language, blocklist, quality, custom-format and other native rejections remain enforced.
- Seed counts are a heuristic. No automatic compact-source replacement is implemented; a six-hour import deadline requires review. Failed automatic analyses are persisted for review rather than endlessly recreated.
- Native RSS/manual searches and Cleanuparr operate independently. Prontarr never deletes library files or torrent data, and does not lock every third-party actor.
- Native imports determine completion. Successful mocked contracts do not prove that a real download has finished.

## API

`GET/POST /api/jobs`, `GET /api/jobs/:id`, `POST /api/jobs/:id/start`, `/cancel`, `/analyze`; `GET /api/library` and `/api/library/sonarr/:id/episodes`. Reports expose sanitized candidates, not indexer GUIDs, download URLs, API credentials or ownership tokens.

## Initial and final profiles

In **Settings → Download profiles**, choose an initial and final profile separately for Radarr movies and Sonarr series. `GET /api/profiles` discovers actual native profile IDs, names, allowed qualities, minimum format score and upgrade permission; errors are isolated per application. `PUT /api/policy` validates selected IDs against the relevant service before saving.

`radarr_profiles` and `sonarr_profiles` each accept `{"initial_id": 4, "final_id": 1}`. Null means use the profile associated with each title. IDs are local to each Arr instance, not interchangeable.

The initial profile filters allowed qualities and custom-format minimums in addition to compact size, resolution and seed limits. The final profile determines quality ranking, format scores and upgrade cutoffs. Scores are recalculated from matched custom-format IDs using the selected profile's weights; an alternate profile cannot use a score calculated for a different profile when format metadata is missing.

Native approval, original audio and the existing rejection/blocklist protections remain mandatory. Selecting a different profile does not edit the title's native `qualityProfileId`. The sole rejection exception is the verified original queue conflict described above. A stricter native title profile may therefore prevent a source that the initial profile would otherwise allow.

Jobs retain their policy snapshot. Saving defaults affects new jobs; **Reanalyze with current defaults** explicitly adopts current settings for a stopped/ready plan. Running plans must be cancelled before reanalysis. Existing simulations and jobs without selection fields remain compatible and use the title's profile.

## Coexistence with other controllers

Prontarr does not disable Cleanuparr, change Arr quality profiles, or add exclusion tags to torrents. Its standalone ownership table only prevents competing Prontarr plans; it does not lock other apps.

Before submitting a release and while following a running plan, Prontarr rechecks the native Arr queue. If another app introduces a different download for the same movie or selected episode, Prontarr cancels its own plan, releases its internal ownership and restores only an original it previously paused. It leaves the replacement untouched and records its hash so automatic intake does not immediately take it over again. Other episodes are evaluated independently when their scope is known.

An expected torrent that disappears from both the Arr queue and qBittorrent starts a removal grace period. Configure it with the positive integer `execution.download_removal_grace_seconds` (default 120). Prontarr checks Arr import history and the current library before confirming removal. The grace period survives a restart. On confirmed removal, Prontarr releases ownership and leaves the library and remaining torrents untouched. Automatic intake leaves that media scope to Arr until the plan is explicitly reanalyzed.

This is a conservative handoff, not a distributed transaction with other apps: another controller can still change a queue between the check and the Arr request. Ambiguous queue scope requires review, and uncertain requests remain protected against blind retries. Removing a torrent does not authorize Prontarr to recreate it automatically. Native import/replacement and cleanup remain the responsibility of Arr and Cleanuparr.


## Parallel downloads

In Settings, enable **Download an eligible upgrade alongside the first copy** for
new or reanalyzed plans. The default is sequential. Prontarr requests the compact
copy first and then requests a distinct, better candidate when upgrades are
allowed and the release qualifies. A verified original upgrade already in the
queue can keep downloading. Radarr and Sonarr remain responsible for import and
replacement decisions. Both transfers share the download client's bandwidth.
