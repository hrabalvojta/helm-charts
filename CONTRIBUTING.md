# Contributing

## Principles

This repository is intentionally strict. Contributions are expected to preserve determinism, release safety, and chart correctness. Convenience is not an excuse for lowering the repo standard.

## Ground Rules

- Do not merge directly to `main`. Use pull requests.
- Keep changes small, reviewable, and scoped to one concern.
- Treat the shell entrypoint in `scripts/chart-tool.sh` as the source of truth for validation and release behavior.
- Do not add parallel one-off scripts when an existing subcommand can be extended instead.
- Do not weaken workflow permissions, signing behavior, or release checks for convenience.

## Chart Change Requirements

If you change files under `charts/<name>/`, you are expected to do the full chart maintenance work, not a partial edit.

- Bump `version` in `Chart.yaml` for any chart behavior or package change.
- Keep `appVersion` and `values.yaml` `image.tag` aligned when they are Renovate-managed.
- Regenerate chart documentation when values or chart metadata change.
- Preserve inline Renovate annotations unless you are intentionally redesigning dependency tracking.
- Do not ship stale examples, broken templates, or untested scenario changes.

## Required Local Validation

Run the same contract that CI uses before opening a pull request:

```bash
./scripts/chart-tool.sh repo lint
./scripts/chart-tool.sh charts audit charts/cyberchef
./scripts/chart-tool.sh charts test --chart charts/cyberchef
./scripts/chart-tool.sh charts docs-check charts/cyberchef
./scripts/chart-tool.sh version check --base HEAD~1 --head HEAD
RUNNER_TEMP=/tmp/chart-tool-runner \
GITHUB_REPOSITORY=hrabalvojta/helm-charts \
GITHUB_REPOSITORY_OWNER=hrabalvojta \
./scripts/chart-tool.sh release publish --dry-run --charts-json '["charts/cyberchef"]'
```

If your change touches multiple charts, run the relevant chart commands for each one. If your change touches release automation, the dry-run path is mandatory.

## Pull Request Expectations

Every pull request should include:

- A concise summary of what changed
- The operational impact
- Validation evidence
- Any release or compatibility implications

Good pull requests make review easier by stating risk clearly. Bad pull requests make reviewers reverse-engineer intent from a diff.

## Commit Expectations

- Use clear, technically meaningful commit messages.
- Avoid meaningless noise like repeated "test", "fix stuff", or "version bump + workflow test" commits unless that is truly the entire change.
- Squash churn before merge when the intermediate history adds no value.

## Workflow And Release Changes

Changes under `.github/` or `scripts/` are high impact.

- Keep workflow YAML thin and push logic into the shared CLI when possible.
- Keep release behavior idempotent and chart-scoped.
- Do not introduce a second release path that bypasses the existing validation and publishing contract.
- Do not expand token permissions without a documented reason.

## Security Expectations

- Never commit secrets, tokens, kubeconfigs, or generated credentials.
- Prefer least privilege in workflows and tooling.
- Do not remove security defaults from charts without replacing them with an equally strong and well-justified alternative.
- If you discover a security issue, report it privately to the maintainer instead of opening a public issue first.

## Ownership

Code ownership is defined in [`CODEOWNERS`](./CODEOWNERS). If you are proposing a structural change to release automation, chart packaging, or repository policy, expect maintainer review.
