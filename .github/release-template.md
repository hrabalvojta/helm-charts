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

{{CHART_DESCRIPTION}}

## Changelog

{{CHANGELOG}}

## Contributors

{{CONTRIBUTORS}}

## Assets

| Asset | Purpose |
| --- | --- |
| [`{{HELM_PACKAGE_NAME}}`]({{HELM_PACKAGE_DOWNLOAD_URL}}) | Packaged Helm chart attached to this GitHub Release. |
| `{{OCI_REPOSITORY}}` | OCI chart reference for `helm pull` and `helm upgrade --install`. |
| [`{{PAGES_REPOSITORY_URL}}/index.yaml`]({{PAGES_REPOSITORY_URL}}/index.yaml) | Static Helm repository index served from `gh-pages`. |

## Install Or Upgrade

```bash
helm upgrade --install {{CHART_NAME}} {{OCI_REPOSITORY}} \
  --version {{CHART_VERSION}}
```

## Notes

- The OCI artifact is the canonical distribution channel.
- The attached `.tgz` asset is a convenience mirror for manual download and offline inspection.
