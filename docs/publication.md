# Repository and container publication

Target repository: `JonasBrother97/prontarr`. License: MIT. Corporate GitHub accounts and organizations are outside this project.

## CI

The GitHub Actions workflow runs on pull requests, pushes to `main`, version tags and manual dispatch. Independent jobs run frontend and Zig unit tests, source checks, runtime builds and image scans. The Docker integration stage runs API contracts, observation contracts, controller lifecycle and ownership tests. Builds use Zig 0.17.1 with its official SHA-256 checksum and the committed npm lockfile. Actions are pinned to reviewed upstream commit SHAs.

The container currently targets **linux/amd64**. The runtime uses a non-root UID/GID of 10001, stores SQLite under `/data`, and does not contain Node, compilers, API keys or local connections. The Docker context uses an allowlist and excludes Git history, databases, environment files, caches and private runtime configuration.

```sh
docker compose up --build -d
```

Open `http://127.0.0.1:5882`. Compose publishes only to loopback. `PRONTARR_BIND=0.0.0.0` is used inside the container; native development defaults to loopback. Host/Origin validation remains enabled. The application has no built-in login; keep it on a trusted/private interface.

Connections are optional. For real integrations, mount a private configuration file read-only, set `PRONTARR_CONNECTIONS` to its container path, and make it readable by UID 10001 with mode 0600. Use upstream addresses reachable from inside the container; localhost inside a container refers to that container. Never bake credentials into an image or commit them.

## Docker Hub

Before publishing, configure:

- Repository variable `DOCKERHUB_USERNAME` with the destination Docker Hub user.
- Actions secret `DOCKERHUB_TOKEN`, a Docker Hub access token with write permission for the intended namespace. It can be a repository secret or a secret in the `dockerhub` environment.

Follow the [trunk-based contribution flow](../CONTRIBUTING.md): integrate into `main`, let CI pass, then create/push a semantic version tag such as `v0.4.0` on that trunk commit. Publication rejects tags whose commits are not in `main` history. Only successful tests on version-tag pushes from `JonasBrother97` can publish. Main branch pushes and pull requests build/test but never publish. Release images are tagged with the full version and major/minor version; stable versions also get `latest`. The workflow requests provenance and SBOM attestations. Missing publishing credentials fail with a clear configuration error without exposing secrets.

The CI Docker test build passed on GitHub. CI also builds the final runtime image and checks its health endpoint, non-root UID and disabled-by-default execution before release. Local Docker builds need a running Docker daemon.

Versioned prereleases start at `0.4.0-alpha.1`; for this release use `docker pull jonasbrother97/prontarr:0.4.0-alpha.4`. Pre-release tags do not update `latest`.
