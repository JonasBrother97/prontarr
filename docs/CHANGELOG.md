# Changelog

## 0.4.0-alpha.7 — Removed download recovery

- Detect removed downloads after a configurable grace period and release plan ownership while preserving imported files.
- Allow eligible upgrades to start alongside the first copy.
- Enable automatic queue refresh by default and run runtime CI integration suites concurrently.

## 0.4.0-alpha.6 — Cooperative download handoff

- Yield active plans to replacement downloads introduced by other apps.
- Preserve Cleanuparr/native replacements and prevent immediate automatic retake.
- Ignore queue changes for other episodes when their scope is explicit.

## 0.4.0-alpha.5 — Portable amd64 runtime

- Compile release images for baseline x86-64 rather than the CI runner's native CPU features.
- Fix startup with an illegal instruction on CPUs lacking runner-specific instruction sets.
- Includes the plan navigation and refresh safeguards from alpha.4.

## 0.4.0-alpha.4 — Plan navigation and refresh safeguards

- Filter plan history by application and sort by title or update time.
- Preserve search within the browser session and remember history preferences.
- Refresh plan history and selected details manually, with the last successful refresh time visible.
- Keep failed history loads distinct from empty history and disable plan actions when detail refresh fails.

## 0.4.0-alpha.3 — Plan history and recovery guidance

- Search plans by title or application, ignoring accents.
- Filter active plans, plans needing attention, and finished plans.
- Show last update times and diagnostic codes in plan history.
- Explain common recovery conditions in English and Brazilian Portuguese.
- Cover lifecycle filtering and translated recovery guidance with frontend tests.

## 0.4.0-alpha.2 — Standalone execution

- Native monitored queue intake with opt-in automatic execution and SQLite ownership.
- Verified existing compact adoption; larger original pause/resume with preserved progress.
- Per-episode compact acquisition for verified selected pack files; import checks cover all missing episodes.
- Explicit HTTPS proxy Host/Origin configuration, private data and restart-safe effect journal retained.
- Security pipeline: ESLint, npm audit, Bandit, Semgrep, OSV, Gitleaks, TruffleHog, Syft, Grype, Trivy and SonarQube Cloud.
- Improved setup documentation and confirmed project funding link.

## Internationalization and publication setup

- English UI and backend messages by default, with bundled en/pt-BR catalogs and a persistent language picker.
- Localized dates, numeric formatting, accessible labels and historical Portuguese events.
- MIT license, Docker/Compose packaging and pinned CI actions for tests and Docker Hub version releases.

## Profile selection

- Independent initial/final native profile choices for movies and series, with quality summaries.
- Native profile discovery and validation, persisted defaults and explicit reanalysis using current defaults.
- Per-profile custom-format scoring while retaining native approval and original-language protections.
- Saved profiles shown in execution details; existing in-flight plans retain their policy snapshots.

## 0.4.0 — Controlled execution pilot

- Native release analysis, quality hierarchy and custom-format comparisons.
- Actual selected-file episode scope from qBittorrent manifests and Sonarr parsing.
- Durable jobs, effect journal, process lock and explicit ownership coordination.
- Compact download → native import → verified upgrade lifecycle, guarded by VPN health and media allowlists.
- Plans UI with source comparison, events, cancellation and reanalysis.
- Execution defaults off. Resuming an existing original torrent remains blocked pending full verification; multi-episode compact acquisition remains unsupported.


## 0.3.0 — 2026-11-18

### Download observation

- Session-scoped view, title filter, status filter and sort order.
- Accent-insensitive search, explicit result counts and one-click filter reset.
- Status filters for downloads, pauses, completed items and Arr review suggestions.
- Numeric title ordering, size/speed ordering and lowest-progress-first ordering.
- Freshness indicator after one minute; old results no longer display as newly connected.
- Optional 30-second observation refresh, disabled on reload and paused in hidden tabs.
- Explicit warning when native queue/torrent limits produce a partial snapshot.

### Navigation and simulation

- Hash routes for deep links and native browser Back/Forward behavior.
- Sidebar collapse and group preferences saved locally, with safe fallback if storage is blocked or corrupt.
- Saved simulations can be reopened with their original inputs and policy, without executing any action.
- Backend health refreshed independently of upstream observations.

### Reliability and development

- Read-only `GET /api/plans/:id` with validated IDs and distinct 400/404 responses.
- Network, timeout, malformed JSON and non-JSON gateway errors have actionable messages.
- Vite's development API proxy now preserves the backend's Host validation via `changeOrigin`.
- Eight frontend reliability tests and two additional API tests; existing safety/contract coverage retained.

Read-only mode remains enforced. No download control or library mutation was introduced.
