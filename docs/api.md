# HTTP API

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

