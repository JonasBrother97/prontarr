# Contributing to Prontarr

## Trunk-based development

`main` is the single integration trunk. Keep changes small and integrate frequently.

- Start from an up-to-date `main`. Use a short-lived branch for a focused change and open a pull request targeting `main`.
- Avoid long-lived feature branches. Split larger changes into independently safe increments and keep unfinished behavior disabled by default.
- Keep `main` buildable and releasable. Fix or revert regressions promptly, and run the checks relevant to your change before integrating.
- There are no permanent `develop`, `release/*` or `hotfix/*` branches. Fixes follow the same path into `main` as other changes.
- Prefer squash merging a pull request to keep the trunk history concise. Remove its branch after integration.
- Maintainer changes can go directly to `main` when repository policy permits; the same CI checks still apply.

## Releases

Release from a tested commit already integrated into `main`; create an annotated semantic-version tag such as `v0.4.0-alpha.3`. Tags identify immutable releases, rather than a separate development line.

1. Integrate the change into `main` and wait for its required checks to pass.
2. Update the version and changelog on `main`.
3. Tag that commit and push the tag. Release CI reruns the mandatory checks before publication.
4. Never move an already-published tag. Apply fixes on `main` and publish a new version.

Publication verifies that the tagged commit belongs to the history of `main`. Pull requests and ordinary trunk pushes never publish release images.

## Validation

From the repository root:

```sh
npm ci --ignore-scripts --prefix frontend
npm run build --prefix frontend
npm run lint --prefix frontend
npm test --prefix frontend
zig build
zig build test
```

For adapter or controller changes, also run the relevant API and controller contracts in `tests/`. Use disposable databases and synthetic service fixtures, with live execution disabled. See [CI security coverage](docs/security-ci.md) for the independent security gates.

Use English for source code, documentation and new UI messages, and keep the Brazilian Portuguese catalog in sync. Do not include private connection files, credentials, production databases or personal infrastructure details in commits, logs or issue reports.
