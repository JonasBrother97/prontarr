# Dependency decisions

Research date: **2026-11-18**. Versions were checked against upstream repositories and the npm registry, then pinned and built locally. “Newest” is not treated as a substitute for compatibility or security review.

| Component | Selected version | Reason |
| --- | --- | --- |
| Zig | 0.17.1 | Current stable; also installed locally |
| http.zig / httpz | commit `1bb71ff128a044b1645df91046473c38abbf965c` | Focused native Zig HTTP/1.1 server; upstream targets Zig 0.17 |
| zqlite.zig | commit `865223b734a5113f731ab1eb1d7d81c8ac252913` | Small SQLite wrapper, bundled SQLite 3.53.0; compiled and exercised on 0.17.1 despite README mentioning 0.16 |
| libcurl | 8.23.0 (system, tested) | Bounded upstream GETs, connect/transfer deadlines and TLS verification |
| React / React DOM | 19.3.1 | Component UI; no SSR needed |
| TypeScript | 7.0.2 | Strict frontend type checking |
| Vite | 8.3.8 | Static frontend build, embedded into Zig executable |
| Vite React plugin | 6.3.0 | Official React integration |
| TanStack Query | 5.108.0 | Request status, mutations, cache invalidation |
| Lucide React | 1.75.0 | Local SVG icons, no runtime CDN |
| Prettier | 3.10.1 | Consistent frontend source formatting |

`build.zig.zon` pins Zig dependency commits **and content hashes**; `frontend/package-lock.json` pins the complete frontend tree. Run `npm ci`, not an unreviewed dependency upgrade, to reproduce this selection.

## Sources

- Zig stable releases: https://ziglang.org/download/
- HTTP server compatibility and API: https://github.com/karlseguin/http.zig
- SQLite wrapper and bundled SQLite version: https://github.com/karlseguin/zqlite.zig
- libcurl: https://curl.se/libcurl/
- React: https://react.dev/blog
- Vite releases: https://vite.dev/releases
- TypeScript: https://www.typescriptlang.org/
- TanStack Query: https://tanstack.com/query/latest/docs/framework/react/overview
- Lucide: https://lucide.dev/guide/packages/lucide-react
- Exact published versions: https://registry.npmjs.org/

## Known tooling advisory

On the research date, `npm audit` reports **GHSA-fc5q-39xc-vjpf**, a high-severity regular-expression denial-of-service advisory affecting `picomatch <=4.0.7`, with dependent reports on fdir, tinyglobby, Vite and the React plugin (five affected dependency entries, not five independent root vulnerabilities). The registry's latest picomatch is 4.0.7, so there is no published patched version to pin yet.

https://github.com/advisories/GHSA-fc5q-39xc-vjpf

This dependency belongs to the local build/development toolchain, not the frontend runtime bundle. Do not expose the development server or build untrusted projects. `npm audit --omit=dev` is separately checked. No automatic `--force` downgrade or audit suppression was applied. Recheck before distributing development environments or enabling CI on untrusted pull requests.
