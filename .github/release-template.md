# {{RELEASE_TITLE}}

## Release Metadata

| Field | Value |
| --- | --- |
| Chart | `{{CHART_NAME}}` |
| Chart version | `{{CHART_VERSION}}` |
| App version | `{{APP_VERSION}}` |
| Kubernetes compatibility | `{{KUBE_VERSION}}` |
| Release tag | `{{RELEASE_TAG}}` |
| Commit | `{{COMMIT_SHA}}` |
| Release date | `{{RELEASE_DATE}}` |
| Previous release | `{{PREVIOUS_TAG}}` |
| Compare | {{COMPARE_URL}} |
| OCI digest | `{{OCI_DIGEST}}` |
| Package SHA256 | `{{PACKAGE_SHA256}}` |

{{CHART_DESCRIPTION}}

## Changelog

{{CHANGELOG}}

## Contributors

{{CONTRIBUTORS}}

## Assets

| Asset | Purpose |
| --- | --- |
{{ASSET_TABLE_ROWS}}

## Install Or Upgrade

```bash
helm upgrade --install {{CHART_NAME}} {{OCI_REPOSITORY}} \
  --version {{CHART_VERSION}}
```

## Notes

- The OCI artifact is the canonical distribution channel.
- The attached `.tgz` asset is a convenience mirror for manual download and offline inspection.
- The attached `.sigstore.json` bundle is the canonical verification material for the packaged chart blob.
