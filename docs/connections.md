# Read-only service connections

Prontarr 0.2 can observe Radarr, Sonarr and qBittorrent. It does not own or execute any live download action. No data is sent to indexers, and no native searches are triggered.

## Configure

Copy `docs/connections.example.json` to a private directory **outside the repository**, replace the example URLs and keys, then restrict its permissions:

```sh
chmod 600 /absolute/private/path/connections.json
PRONTARR_CONNECTIONS=/absolute/private/path/connections.json ./zig-out/bin/prontarr
```

The file is loaded at process startup. Restart Prontarr after changing it. Missing configuration leaves all integrations disabled. An invalid or group/world-accessible configuration file is rejected at startup on POSIX systems.

Never commit actual configuration, cookies or API keys. The browser receives only connection names and configured flags; it cannot retrieve keys, cookies or upstream URLs. No settings page for editing secrets has been introduced yet.

### Supported fields

| Field | Usage |
| --- | --- |
| `url` | Direct base URL, optionally with a base path such as `/radarr`; HTTP or HTTPS only |
| `api_key` | Required for Radarr/Sonarr; sent as `X-Api-Key`, not in query parameters |
| `host_header` | Optional HTTP Host override for a development port forward/proxy; not a TLS bypass |
| `cookie` | Optional existing qBittorrent session cookie, e.g. `SID=replace-with-your-session` |

qBittorrent uses an already-authorized trusted connection or an existing SID cookie. This milestone does not implement username/password login or session renewal, and it does not disable native authentication. Expired sessions are reported as unauthorized.

In a local development setup behind network isolation, SSH loopback forwards may be used. Keep SSH private keys, actual forwarding destinations and startup configuration outside the repository. Host overrides can preserve the intended virtual host when using a loopback forward. TLS still validates the host in `url`; no certificate-check bypass exists.

## UI and API

Open **Downloads reais**, then **Consultar serviços**. There is no background polling. Each successful observation has a timestamp; refresh manually. Arr records are joined to qBittorrent by case-insensitive download hashes. Library file presence and episode labels (SxxExx) are verified by querying each movie/episode, not inferred from queue status or a completed torrent.

- `GET /api/connections`: sanitized configuration metadata, no network calls.
- `POST /api/observe` with `{}`: read-only upstream snapshot, normalized queue/torrents and advisory explanations.
- `GET /api/health`: mode `read_only`, capability flag `observation_available`, live actions disabled.

Returned observations are not persisted in SQLite. They remain in the browser's in-memory query cache until the page is reloaded. Local simulation plans continue to be persisted separately.

## Limits and uncertainty

- First **25 queue records per Arr**, up to **500 qBittorrent records**. Truncation is explicit in service metadata and in the UI. Browser pagination only paginates this fetched snapshot.
- **1 second connect timeout**, **3 seconds total per upstream request**, **2 MiB maximum response body**. File enrichment stops after a shared 15-second observation budget; further records are explicitly unverified.
- One observation at a time. A concurrent call returns 409 rather than issuing a duplicate round of queries.
- HTTP redirects are rejected, TLS verification is mandatory, proxy environment variables are ignored by this internal client, and raw upstream error bodies are never returned.
- No arbitrary URL, raw API proxy or upstream mutation endpoint is exposed.
- Unknown file identity or episode scope produces `needs_review`, not an assumed missing file.
- A hash shared by multiple Sonarr records requires review of the complete pack. A truncated Sonarr queue also cannot establish a complete episode scope.
- Existing pauses and downloads beyond 10% progress are preserved in the recommendation.
- Advice to evaluate a compact source does **not** mean that a suitable source was found. No release search, audio verification or final quality-profile comparison has happened yet.
- File existence and custom-format scores are observations, not proof that a queued source is an acceptable upgrade. The existing controller and native Arr applications retain all control.

## Contract tests

`python3 tests/observe_contract.py` runs an isolated local HTTP fixture, records every upstream request and checks that only GETs were made. It exercises hash matching, file identity, pack scope, credential redaction, unauthorized responses, redirects, oversized bodies, request timeout, certificate rejection and configuration file permissions. It never reads actual homelab credentials.

## Upstream specifications

- Radarr v3 API: https://radarr.video/docs/api/
- Sonarr v3 API: https://sonarr.tv/docs/api/
- qBittorrent 5 WebUI API: https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-(qBittorrent-5.0)
- libcurl transfer deadlines: https://curl.se/libcurl/c/CURLOPT_TIMEOUT_MS.html
- libcurl redirect policy: https://curl.se/libcurl/c/CURLOPT_FOLLOWLOCATION.html
- libcurl peer verification: https://curl.se/libcurl/c/CURLOPT_SSL_VERIFYPEER.html
