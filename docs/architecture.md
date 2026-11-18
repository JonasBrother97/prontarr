# Architecture

```text
React UI ── JSON/HTTP ── Zig/httpz API ── SQLite
                            │
                       pure engine
                            │
                     explained decision
```

The current executable cannot issue HTTP requests to external services. There are no live-action routes. A simulation's `Decision` is a recommendation; the application persists the request and the server-computed decision together. It does not execute that recommendation.

`src/engine.zig` owns selection and state transitions without network, database or filesystem access. `src/main.zig` owns routing, request validation, bounded input and local persistence. A small SQLite pool serializes connection use; the shared application does not hold mutable per-request state. Query results are copied into request arenas before database statements are released.

## States

- `missing`: choose an eligible compact source, or wait without canceling anything.
- `compact_downloading`: wait until all scoped files are imported.
- `watchable`: request an upgrade only if every scoped file is available.
- `upgrading`: preserve the existing copy until import confirmation covers the entire scope.
- `complete`: no further action.

There is deliberately no delete action. The Arr application remains responsible for library replacement. Future torrent-data cleanup requires an independent ownership/private-tracker/episode-scope safety check and is not implied by `complete`.

The availability score is `log2(seeders + 1) / max(sizeGiB, 0.4)^0.45`. It is a deterministic heuristic, not an ETA or measured speed. Candidates must pass hard constraints before scoring. Equal scores currently preserve input order.

## Before live control

Introduce typed adapters, read-only reconciliation, verified file identities per episode, a durable outbox, idempotent event handling and explicit compensation for partial failures. Webhooks are hints; current Arr/qBittorrent state must be reconciled before any action. An old or repeated webhook must never authorize deletion.

The existing Python controller is a behavioral reference only; its private config, tokens, hostnames and runtime state must not be copied into this repository. The new controller and old controller must never run as simultaneous owners of the same torrents.
