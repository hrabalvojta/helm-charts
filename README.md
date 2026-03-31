# helm-charts

Opinionated Helm charts with strict CI, deterministic release automation, and Renovate-managed dependency updates.

## What This Repo Does

- Validates changed charts on pull requests with repository linting, chart metadata audits, strict Helm rendering, docs verification, and a release dry-run.
- Publishes packaged charts to GHCR as OCI artifacts.
- Rebuilds and publishes a `gh-pages` Helm repository index after release.
- Creates a structured GitHub Release per chart version and attaches the packaged `.tgz` plus integrity sidecars such as `.sha256` and `.sigstore.json`.
- Keeps chart image versions and workflow dependencies current through Renovate.

## Local Commands

Run the same entrypoint locally that GitHub Actions uses:

```bash
./scripts/chart-tool.sh repo lint
./scripts/chart-tool.sh discover all --format json
./scripts/chart-tool.sh charts audit charts/cyberchef
./scripts/chart-tool.sh charts test --chart charts/cyberchef
./scripts/chart-tool.sh charts docs-check charts/cyberchef
./scripts/chart-tool.sh version check --base HEAD~1 --head HEAD
RUNNER_TEMP=/tmp/chart-tool-runner \
GITHUB_REPOSITORY=hrabalvojta/helm-charts \
GITHUB_REPOSITORY_OWNER=hrabalvojta \
./scripts/chart-tool.sh release publish --dry-run --charts-json '["charts/cyberchef"]'
```

## Workflow Model

- [`ci.yaml`](./.github/workflows/ci.yaml) is the pull request gate. It is the stable check to require in branch protection.
- [`release.yaml`](./.github/workflows/release.yaml) packages, signs, publishes, rebuilds `gh-pages`, and creates GitHub Releases with attached chart assets on `main`.
  Manual dispatch now requires explicit scope selection: named charts, or `all` with an explicit confirmation flag.
- [`chart-tool.sh`](./scripts/chart-tool.sh) is the only shell entrypoint the workflows call.

## Renovate Model

- GitHub Actions updates are grouped.
- Container image updates are grouped.
- Non-major dependency updates can automerge once CI is green.
- Chart image versions are updated from explicit inline `renovate` annotations in both [`Chart.yaml`](./charts/cyberchef/Chart.yaml) and [`values.yaml`](./charts/cyberchef/values.yaml) so `appVersion` and the default image tag do not drift apart.

## Governance

- Contribution rules live in [`CONTRIBUTING.md`](./CONTRIBUTING.md).
- Ownership rules live in [`CODEOWNERS`](./CODEOWNERS).
- Conduct expectations live in [`CODE_OF_CONDUCT.md`](./CODE_OF_CONDUCT.md).
