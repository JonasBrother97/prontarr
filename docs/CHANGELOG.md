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

# Changelog

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
