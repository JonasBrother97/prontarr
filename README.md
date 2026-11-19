<div align="center">

# Prontarr

**A watchable copy now. A better one later.**

A two-stage download companion for **Radarr, Sonarr and qBittorrent**.

[![Build](https://github.com/JonasBrother97/prontarr/actions/workflows/ci.yml/badge.svg)](https://github.com/JonasBrother97/prontarr/actions/workflows/ci.yml)
[![Docker Hub](https://img.shields.io/docker/v/jonasbrother97/prontarr?label=Docker%20Hub)](https://hub.docker.com/r/jonasbrother97/prontarr)
[![Buy Me a Coffee](https://img.shields.io/badge/Support-Buy%20Me%20a%20Coffee-ffdd00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/jonasbrother97)
[![Quality Gate](https://sonarcloud.io/api/project_badges/measure?project=JonasBrother97_prontarr&metric=alert_status)](https://sonarcloud.io/project/overview?id=JonasBrother97_prontarr)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[Getting started](#getting-started) · [Features](#features) · [Documentation](#documentation) · [Report a bug](https://github.com/JonasBrother97/prontarr/issues)

</div>

> **Alpha — guarded standalone execution.** Live actions are disabled by default.
> Read the [execution requirements and recovery guide](docs/execution.md) before enabling them.

## Why Prontarr?

A high-quality release can take hours to finish while a smaller copy would be ready sooner. Prontarr plans a compact first download and a later quality upgrade, so you can watch sooner without abandoning your preferred final quality.

**Radarr and Sonarr remain responsible for importing, naming and replacing library files.** Prontarr coordinates release selection and records the workflow; it does not delete media files.

```text
Requested movie or episode
          │
          ▼
  Analyze native Arr releases
          │
          ▼
  Compact copy → Arr import → Quality upgrade → Arr replacement
```

Reported seeds are an availability hint, not a speed guarantee. Releases must satisfy supported native approval, language, quality and custom-format constraints.

## Features

| Area | What you get |
| --- | --- |
| Two-stage planning | Separate initial and final quality profiles, discovered from each Arr API |
| Persistent jobs | Searchable SQLite plan history, status filters, recovery guidance, cancellation and explicit reanalysis |
| Recovery | Recorded upstream effects, restart protection and exclusive media ownership |
| Import verification | Native file identities and scope-aware episode checks before advancing |
| Live visibility | Arr queues, torrent progress, speed, ETA and explained decisions |
| Policy controls | Compact size, resolution and seed thresholds; original-audio checks |
| Interface | Familiar Arr-style navigation, responsive layout, English and Brazilian Portuguese |
| Deployment | Embedded React UI in a Zig executable; non-root Docker image |

## Getting started

### Docker

The published image currently targets **Linux amd64**. Use an explicit release tag:

```sh
docker volume create prontarr-data
docker run -d --name prontarr \
  --restart unless-stopped \
  -p 127.0.0.1:5882:5882 \
  -v prontarr-data:/data \
  jonasbrother97/prontarr:0.4.0-alpha.2
```

Open [http://127.0.0.1:5882](http://127.0.0.1:5882). This starts the UI and simulator with live execution disabled. Configure private service connections using the [connection guide](docs/connections.md), then follow the [execution guide](docs/execution.md) for the guarded pilot.

For Compose, release tags and persistent configuration, see [container deployment](docs/publication.md).

### Build from source

Requirements: Zig **0.17.1**, Node.js **22.18+**, npm, pkg-config, libcurl development headers and a C toolchain. Node 26 is used in CI. SQLite is bundled; no database server is required.

```sh
npm ci --prefix frontend
npm run build --prefix frontend
zig build
./zig-out/bin/prontarr
```

The built executable embeds the UI; Node is only required for development/builds. Set `PRONTARR_DB` to an absolute path to choose a database location. Use a private directory and `umask 077`.

For UI development, run `npm run dev --prefix frontend` alongside the backend. Rebuild the frontend and executable to update the embedded UI.

## Current boundaries

- Standalone mode supports automatic monitored queue intake, existing torrent adoption/resume and selected-episode compact acquisition. Execution requires explicit configuration.
- A healthy VPN check and durable exclusive ownership are required. Standalone mode keeps ownership in SQLite; the legacy external coordinator is optional.
- The server has no built-in authentication. Default local bindings and Host/Origin checks limit access; remote deployment needs a correctly configured authentication proxy.
- Prontarr is a companion to existing Arr applications, not an indexer, download client or media server.
- Simulation inputs are synthetic; live analysis obtains release metadata from native APIs.

## Documentation

| Guide | Contents |
| --- | --- |
| [Connections](docs/connections.md) | Private configuration and upstream access |
| [Execution and recovery](docs/execution.md) | Supported scopes, ownership and action safeguards |
| [Docker and publishing](docs/publication.md) | Container deployment and release pipeline |
| [HTTP API](docs/api.md) | Routes, requests and capabilities |
| [Architecture](docs/architecture.md) | Backend, storage and decision engine |
| [Security](SECURITY.md) | Reporting issues and understanding scan coverage |
| [Internationalization](docs/i18n.md) | Languages and translations |
| [Changelog](docs/CHANGELOG.md) · [Roadmap](docs/roadmap.md) | Progress and planned work |

## Development and contributions

```sh
npm run lint --prefix frontend
make test
```

Tests use temporary databases and mock upstream services. They do not contact a real media library. The API suites bind port 5882; stop another local instance before running them.

Bug reports should include the version, expected behavior and redacted reproduction details. Feature requests and pull requests are welcome. Never attach API keys, connection files, private library databases or raw download logs containing credentials.

CI checks code, dependencies, Git history and the runtime image. See [the security guide](docs/security-ci.md) for individual tools, severity gates and optional SonarQube setup. Passing scans does not establish complete coverage of Zig or bundled native code.

## Support the project

If Prontarr helps your library, you can [buy me a coffee](https://buymeacoffee.com/jonasbrother97). Bug reports, translations and contributions are equally welcome.

## License and acknowledgements

[MIT](LICENSE). Dependencies retain their own licenses; see [third-party notices](THIRD_PARTY_NOTICES).

Built to work alongside [Radarr](https://github.com/Radarr/Radarr), [Sonarr](https://github.com/Sonarr/Sonarr) and [qBittorrent](https://github.com/qbittorrent/qBittorrent). Prontarr is an independent project and is not affiliated with their teams.
