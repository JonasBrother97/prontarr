# Architecture

```text
React UI ── JSON/HTTP ── Zig/httpz API ── SQLite
                            │
                       pure engine
                            │
                     explained decision
```

Simulations persist their inputs and recommendations in SQLite. Live plans use a separate controller and run only when execution is configured and the target is allowed.

`src/engine.zig` contains the pure simulation logic. `src/main.zig` owns routing and request validation. `src/transport.zig` uses libcurl with deadlines, TLS verification, response limits and an allowlist of write operations. `src/observe.zig` gathers read-only snapshots, `src/planner.zig` evaluates native profiles and releases, and `src/controller.zig` persists live plan state and reconciles effects. A small SQLite pool manages concurrent access.

## Simulation states

- `missing`: choose an eligible compact source, or wait without canceling anything.
- `compact_downloading`: wait until all scoped files are imported.
- `watchable`: request an upgrade only if every scoped file is available.
- `upgrading`: preserve the existing copy until import confirmation covers the entire scope.
- `complete`: no further action.

There is deliberately no delete action. The Arr application remains responsible for library replacement. Future torrent-data cleanup requires an independent ownership/private-tracker/episode-scope safety check and is not implied by `complete`.

The availability score is `log2(seeders + 1) / max(sizeGiB, 0.4)^0.45`. It is a deterministic heuristic, not an ETA or measured speed. Candidates must pass hard constraints before scoring. Equal scores currently preserve input order.

## Live control

Live plans progress through analysis, claiming, first-copy download and upgrade. Plans can complete, require review or be cancelled. Optional parallel execution can request an eligible upgrade before the first copy is imported. Native Arr applications manage import and library replacement.

The controller checks its configured execution scope, VPN health and native queue state. It records actions before issuing requests, reconciles ambiguous results and yields when it detects an external replacement. Standalone ownership coordinates plans within Prontarr. Existing legacy-coordinator integrations are documented in the [execution guide](execution.md).

For authentication and direct-network access requirements, see the [deployment guide](publication.md) and [security policy](../SECURITY.md).
