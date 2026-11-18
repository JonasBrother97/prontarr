# CI security coverage

Security checks run for pushes to main, version tags and pull requests as part of the test-and-publish workflow. Source checks can also be dispatched manually. Publication depends on both the application tests and source security checks; runtime image scans run in the test job before publication.

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

Runtime reports and the SBOM are retained as workflow artifacts for 14 days. The image gates focus on vulnerabilities with available fixes; this does not mean unfixed issues are safe. npm/OSV policies are intentionally independent from the runtime gates. The only secret exception is the exact synthetic `user:secret` URI at the reserved `example.test` domain in `src/tests.zig`, limited to the URI detector. There are no blanket vulnerability allowlists or continue-on-error security gates.

Actions are pinned by commit. Scanner dependencies have explicit versions where configured; scanner databases still update independently. Semgrep uses local rules and disables telemetry. Secret scanning never tests credentials against providers.

## Limits

Bandit analyzes Python, not Zig. Standard Semgrep and SonarQube analyzers do not cover this Zig backend. Zig compilation/tests, API boundary tests and controller lifecycle contracts remain required. Native SQLite and statically bundled code may not be fully represented in runtime package inventories. SBOM generation is inventory, not a vulnerability scan.

## SonarQube setup

The job is disabled until repository variable `SONAR_ENABLED=true` is configured. Add:

- Secret `SONAR_TOKEN` with access limited to this project.
- Variables `SONAR_HOST_URL` and `SONAR_PROJECT_KEY`.
- Variable `SONAR_ORGANIZATION` for SonarQube Cloud (leave empty for self-hosted).

The job checks required values and waits for the quality gate. It runs only on trusted non-PR events so analysis credentials are not exposed to pull requests. It is not advertised as active until a real server/project is configured and a run succeeds.

## Funding

The repository funding button points to the maintainer-confirmed [Buy Me a Coffee page](https://buymeacoffee.com/jonasbrother97).
