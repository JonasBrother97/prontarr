# CI security coverage

Security checks run for pushes to main, version tags and pull requests as part of the test-and-publish workflow. Source checks can also be dispatched manually. Each scanner has its own named job and independent result. Source scanners, frontend unit tests, Python tests, Zig unit tests, and the runtime build can start in parallel, subject to runner availability. Publication requires every mandatory application and security gate to pass.

| Tool | Scope and failure policy |
| --- | --- |
| ESLint | TypeScript/React source and frontend tests; lint errors fail |
| npm audit | All locked frontend dependencies, including development packages; high/critical fail |
| Bandit | Python integration helpers; medium+ severity and confidence fail |
| Semgrep | Committed local rules for dynamic JS, raw React HTML, Python shell execution and disabled TLS; findings fail |
| OSV-Scanner | Frontend package-lock dependencies; reported vulnerabilities fail |
| Gitleaks | Entire checked-out Git history; findings fail, secrets redacted |
| TruffleHog | Entire Git history; findings fail, credential verification disabled; raw output is neither logged nor uploaded |
| Syft | SPDX JSON bill of materials for the built runtime image |
| Grype | Scans the Syft runtime SBOM; fixable high/critical findings fail |
| Trivy | Runtime OS/library vulnerabilities; fixable high/critical findings fail |
| SonarQube | Optional TS/Python analysis and quality gate; requires external configuration |

Python helper and frontend unit coverage reports are passed to SonarQube; test files are classified as tests and excluded from production coverage metrics. UI components and the Zig backend are not represented by the frontend helper coverage percentage.

Runtime builds refresh Debian security updates instead of reusing the runtime package layer. Fixable high/critical findings are summarized on the workflow page.

The built runtime image is shared between jobs as a one-day artifact, so the smoke test, Syft and Trivy inspect the same image. Grype waits for the Syft SBOM; SonarQube waits only for the two coverage reports. Runtime reports and the SBOM are retained as workflow artifacts for 14 days. The image gates focus on vulnerabilities with available fixes; this does not mean unfixed issues are safe. npm/OSV policies are intentionally independent from the runtime gates. The only secret exception is the exact synthetic `user:secret` URI at the reserved `example.test` domain in `src/tests.zig`, limited to the URI detector and the test, gate and documentation paths (including historical copies). Gitleaks also permits the exact public SonarQube project identifier in its properties file; analysis tokens are never exempted. There are no blanket vulnerability allowlists or continue-on-error security gates.

Actions are pinned by commit. Scanner dependencies have explicit versions where configured; scanner databases still update independently. Semgrep uses local rules and disables telemetry. Secret scanning never tests credentials against providers.

## Limits

Bandit analyzes Python, not Zig. Standard Semgrep and SonarQube analyzers do not cover this Zig backend. Zig compilation/tests, API boundary tests and controller lifecycle contracts remain required. Native SQLite and statically bundled code may not be fully represented in runtime package inventories. SBOM generation is inventory, not a vulnerability scan.

## SonarQube Cloud

Analysis targets the public project `JonasBrother97_prontarr` in organization `jonasbrother97`, using the free Cloud service. Store `SONAR_TOKEN` as a repository secret. No token is committed.

The job validates the token, runs only on trusted non-PR events in the original repository, and waits for the quality gate. Forks do not need Sonar credentials. Project key and organization are in `sonar-project.properties`. Disable SonarCloud Automatic Analysis when using this CI-based scan.

## Funding

The repository funding button points to the maintainer-confirmed [Buy Me a Coffee page](https://buymeacoffee.com/jonasbrother97).

## Pipeline layout

```text
Source checkout → ESLint / npm audit / Bandit / Semgrep / OSV / Gitleaks / TruffleHog
                → Frontend unit coverage ─┐
                → Python unit coverage ───┴→ SonarQube quality gate
                → Zig unit tests
                → Runtime build + API/controller integration tests
                    ├→ Container smoke test
                    ├→ Trivy
                    └→ Syft → Grype
All required gates → Version-tag publication
```

Unit tests have separate checks from integration tests and scanner jobs. Compiler/toolchain setup time is included in job duration; it is not the unit-test execution time. Docker integration suites use separate build steps to make each suite visible in BuildKit logs. Cache scopes for the Zig unit job and runtime build are independent so parallel cache exports do not overwrite each other.

The Docker build compiles the optimized runtime binary once and runs integration contracts against that same binary. Unit tests do not depend on frontend bundles, and README/documentation changes do not invalidate backend compilation. Only the synthetic API fixture enters the integration stage.

The runtime build runs the API, observation, ownership and three controller shards in independent BuildKit stages after a single compilation. Each uses its own loopback network, and every stage must pass before the runtime binary is copied into the image. Stage durations are visible in the build log.
