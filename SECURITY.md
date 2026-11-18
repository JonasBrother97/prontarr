# Security policy

Prontarr is experimental software. Use the latest available alpha and keep live execution disabled until its documented requirements have been reviewed.

## Reporting

Do not put credentials or exploitable vulnerability details in a public issue. Use the repository's **Security → Report a vulnerability** option when private vulnerability reporting is enabled. If it is unavailable, open an issue asking for a private reporting channel without describing the exploit.

## Deployment

Keep connection files private, protect the database directory and place remote access behind authentication. The published pilot has no built-in login. Do not commit connection files, tokens, databases or private logs.

## Automated checks

See [CI security coverage](docs/security-ci.md). A successful scan does not prove the absence of vulnerabilities, and standard SAST tools do not analyze Zig.
