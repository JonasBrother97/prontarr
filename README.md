# Prontarr

**A watchable copy now. A better one later.**

Prontarr is an experimental two-stage download planner for the Arr ecosystem, built with **Zig + React + TypeScript + SQLite**.

## Current milestone: controlled execution pilot

Prontarr now analyzes native release searches and persists execution plans. Execution is **disabled by default**. An explicit media allowlist, an exclusive ownership coordinator, and a healthy VPN check are required before it can request a compact release and then an upgrade. Native Arr imports and replaces library files; Prontarr has no deletion operation.

This is an experimental pilot, not a general replacement for every existing controller. See [execution and recovery](docs/execution.md) for supported scopes, setup, and limitations.

Implemented:

- English by default, Brazilian Portuguese translation and a persistent language selector.

- Selectable initial/final profiles per Arr, discovered from native APIs and snapshotted per plan.
- Persisted execution plans, source comparison, event journal, cancellation and explicit reanalysis.
- Idempotent release requests across restarts and exclusive ownership per media.
- Native quality groups, custom-format improvements, upgrade cutoffs and file-identity checks.
- Torrent manifest analysis maps selected episode files and reports absent queue entries.

- Status filters, sorting, freshness indicators and optional 30-second observation refresh.
- Persistent menu preferences, deep links with browser navigation, and saved simulation replay.
- Read-only service status, real Arr queues, torrent progress/speed/ETA and explained suggestions.
- Private startup configuration, credential redaction, bounded requests and verified TLS.
- A real Zig HTTP API, serving an embedded React application from one executable.
- A deterministic, independently tested decision engine.
- Compact candidate selection using a seed-count/size availability heuristic.
- Hard constraints for original audio, Arr approval, size, resolution and remux exclusion.
- Scope-aware import checks: every episode in a season pack must be available before upgrading.
- Editable default policy and simulation history persisted in SQLite/WAL.
- Explicit simulation labels and explanations, Portuguese interface, responsive layout.
- Loopback-only listener, Host/Origin checks, request-size cap, no third-party browser requests.

Reported seeds **do not guarantee download speed**. The simulator's audio and approval flags are manual inputs. Live analysis derives language, approval, quality and custom-format scores from the native Arr response.

## Run locally

Requirements: **Zig 0.17.1**, **Node.js 22.18+** (tested on 26.13.0), npm, pkg-config, libcurl development headers/library (tested with 8.23.0), and a C toolchain supported by Zig. SQLite is compiled from the dependency's bundled amalgamation; no database service is needed.

```sh
npm ci --prefix frontend
npm run build --prefix frontend
zig build
./zig-out/bin/prontarr
```

Open **http://127.0.0.1:5882**. The executable embeds the built HTML, JS and CSS; Node is not needed at runtime; the executable dynamically links libcurl.

Default database: `prontarr.sqlite` in the process working directory. To choose another path (parent directory must already exist):

```sh
PRONTARR_DB=/absolute/private/path/prontarr.sqlite ./zig-out/bin/prontarr
```

Use a private directory and `umask 077` when storing personal titles. No credentials belong in this repository. SQLite files, local dependency caches, build output and `.env` are excluded from Git.

For actual service observation, follow [connection setup](docs/connections.md). No connection configuration is committed or enabled by default.

For frontend development, run `npm run dev --prefix frontend` while the backend is running. Vite proxies `/api` to the loopback backend. After frontend changes, rebuild both frontend and executable for the embedded version to change.

## Verify

```sh
make test
```

The integration test starts its own executable on port 5882 with a temporary database, checks validation/security boundaries, saves data, restarts the process and checks persistence. Stop a manual Prontarr instance first. The contract suite uses only isolated local mock upstreams, including a temporary self-signed TLS endpoint. Neither suite connects to your homelab.

## API

POST and PUT endpoints require `Content-Type: application/json`. Settings and simulation plans write local data; observation only performs upstream GET requests. Execution plans can request guarded upstream actions only when execution is explicitly enabled.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/api/health` | Version and configured execution/observation capabilities |
| GET / PUT | `/api/policy` | Read or save profile choices and planning defaults |
| POST | `/api/simulate` | Return a decision, without saving or executing it |
| GET / POST | `/api/plans` | Latest 100 saved simulations / save a simulation |
| GET | `/api/plans/:id` | Retrieve original inputs and decision for simulation replay |
| GET | `/api/connections` | Redacted configured flags; no upstream requests |
| POST | `/api/observe` | Real read-only queue/torrent observation |
| GET | `/api/profiles` | Native quality profiles, with sanitized criteria |
| GET | `/api/library` | Native movies and series for plan selection |
| GET / POST | `/api/jobs` | List persisted execution plans / create analysis |
| GET | `/api/jobs/:id` | Selected releases, plan state and events |
| POST | `/api/jobs/:id/start` | Start an explicitly permitted, fresh plan |
| POST | `/api/jobs/:id/cancel` | Cancel and release control, preserving downloads |
| POST | `/api/jobs/:id/analyze` | Reanalyze using current planning defaults |

See [changelog](docs/CHANGELOG.md), [example request](docs/example-input.json), [architecture](docs/architecture.md), [dependency research](docs/dependencies.md) and [roadmap](docs/roadmap.md).

## Status and distribution

Public source: [JonasBrother97/prontarr](https://github.com/JonasBrother97/prontarr), under MIT. Container releases are published to [jonasbrother97/prontarr](https://hub.docker.com/r/jonasbrother97/prontarr).

This is an **alpha** with a controlled execution pilot. General automatic intake and multi-episode compact acquisition are not enabled. See [execution limits](docs/execution.md). The server has no built-in authentication; native development and the supplied Compose port mapping default to loopback.

## Containers and CI

See [publication setup](docs/publication.md) for the non-root Docker image, local Compose service, automated tests and Docker Hub release workflow.

## Language

English is the default UI language; Brazilian Portuguese is available in the header. See [internationalization](docs/i18n.md).

## License

[MIT](LICENSE). Third-party dependencies retain their own licenses.
