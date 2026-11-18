# Prontarr

**A watchable copy now. A better one later.**

Prontarr is an experimental two-stage download planner for the Arr ecosystem, built with **Zig + React + TypeScript + SQLite**.

## Current milestone: controlled execution pilot

Prontarr now analyzes native release searches and persists execution plans. Execution is **disabled by default**. An explicit media allowlist, an exclusive ownership coordinator, and a healthy VPN check are required before it can request a compact release and then an upgrade. Native Arr imports and replaces library files; Prontarr has no deletion operation.

This is an experimental pilot, not a general replacement for every existing controller. See [execution and recovery](docs/execution.md) for supported scopes, setup, and limitations.

Implemented:

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
npm test --prefix frontend
zig build test
python3 tests/api_smoke.py
python3 tests/observe_contract.py
```

The integration test starts its own executable on port 5882 with a temporary database, checks validation/security boundaries, saves data, restarts the process and checks persistence. Stop a manual Prontarr instance first. The contract suite uses only isolated local mock upstreams, including a temporary self-signed TLS endpoint. Neither suite connects to your homelab.

## API

POST and PUT endpoints require `Content-Type: application/json`. Settings and plans only write local data; observation only performs upstream GET requests.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/api/health` | Version, observation capability and disabled live-action status |
| GET / PUT | `/api/policy` | Read or save simulation defaults |
| POST | `/api/simulate` | Return a decision, without saving or executing it |
| GET / POST | `/api/plans` | Latest 100 saved simulations / save a simulation |
| GET | `/api/plans/:id` | Retrieve original inputs and decision for simulation replay |
| GET | `/api/connections` | Redacted configured flags; no upstream requests |
| POST | `/api/observe` | Real read-only queue/torrent observation |

See [changelog](docs/CHANGELOG.md), [example request](docs/example-input.json), [architecture](docs/architecture.md), [dependency research](docs/dependencies.md) and [roadmap](docs/roadmap.md).

## Status and distribution

Local development repository; no upstream remote, publication or deployment is configured. Working name **Prontarr** is provisional. Public release and licensing are still to be decided. Do not expose this prototype through a reverse proxy or tunnel: authentication has not been implemented, and the server intentionally accepts only loopback hosts.
