# Roadmap

## Available today

- Zig API and React UI in English and Brazilian Portuguese. The simulator saves results independently of live execution.
- Read-only observation of Radarr, Sonarr and qBittorrent. Analysis checks profiles, release eligibility and selected episode scope.
- Controlled standalone execution with durable plan state and a journal for download requests. Prontarr can prepare a first copy and then request a better release, or request both in parallel when enabled.
- Radarr and Sonarr handle imports and library replacement. Prontarr yields to unrelated replacement downloads it detects in the native queue.
- Non-root Docker runtime, health endpoint and release images. CI runs unit tests, integration contracts and security scanners.

## Deployment and limits

Live execution starts disabled. For remote access, put Prontarr behind an authenticated reverse proxy such as Authentik, and restrict direct access to the backend on both IPv4 and IPv6. Authentication is supplied by the proxy. Follow the [container guide](publication.md) and [execution guide](execution.md).

The queue can change between verification and a request to Arr. Pack automation requires verified scope, and availability estimates based on seed counts cannot predict transfer speed. Browser coverage, disappearance detection and upgrades across database versions are tracked as follow-up work.

## Planned work

Use [GitHub Issues](https://github.com/JonasBrother97/prontarr/issues) as the backlog. Each issue owns its own acceptance criteria. Current themes include download recovery, interoperability with other automation, clearer plan diagnostics and browser-based tests.

Contributions integrate through the [trunk-based workflow](../CONTRIBUTING.md). Releases are tagged from commits already integrated into main.
