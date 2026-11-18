# Roadmap

## Milestone 1 — local foundation (implemented)

- [x] Zig API and pure decision engine
- [x] Embedded responsive React UI
- [x] Policy editing, simulation, persisted history
- [x] Unit and HTTP/persistence tests
- [x] Pinned dependencies and documented tooling advisory

## Milestone 2 — observe real services (first read-only slice implemented)

- [x] Radarr / Sonarr / qBittorrent adapters, initially read-only
- [x] Secret storage outside returned configuration and logs
- [x] Connection testing, deadlines, response-size bounds and TLS verification
- [x] Queue media/episode IDs, observed file IDs, resolution and returned custom-format scores
- [ ] Verified complete pack membership and relative final-profile/format scoring
- [x] Display conservative suggestions against real current queue/torrent state without acting
- [ ] Reconcile advisory state with the legacy controller state machine
- [x] Contract tests with sanitized fixtures; no private titles/tokens committed

## Reliability and daily-use improvements (0.3.0)

- [x] Deep links and native browser history
- [x] Safe local/session preferences, status filters and sorting
- [x] Snapshot freshness and optional visible-tab refresh
- [x] Replay saved simulation inputs without execution
- [x] Frontend network/storage failure tests

## Milestone 3 — controlled execution

- [ ] Durable per-episode and per-torrent state, idempotent webhook inbox/outbox
- [ ] Select compact copy, defer original, and compensate on failure
- [ ] Confirm import and file identity before starting an upgrade
- [ ] Recover safely after crashes and restarts
- [ ] Respect manually paused downloads, existing progress and private trackers
- [ ] Explicit ownership agreement with Cleanuparr and legacy controller
- [ ] Original-audio and 5.1 requirements derived from profile policy
- [ ] Separate compact limits for films, episodes and season packs

## Milestone 4 — distribution

- [ ] Authentication / Authentik integration and deployment threat model
- [ ] Docker Compose, non-root runtime and health check
- [ ] Release builds and CI, migrations/backup compatibility
- [ ] Language selection, accessibility review and full mobile testing
- [ ] Licensing, contribution guide and public release documentation
- [ ] Choose a permanent name and publish only when requested
