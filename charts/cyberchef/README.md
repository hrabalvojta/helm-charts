# cyberchef

![Version: 0.4.0](https://img.shields.io/badge/Version-0.4.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: v11.0.0](https://img.shields.io/badge/AppVersion-v11.0.0-informational?style=flat-square)

The Cyber Swiss Army Knife - a web app for encryption, encoding, compression and data analysis

**Homepage:** <https://github.com/hrabalvojta/helm-charts/tree/main/charts/cyberchef>

## Chart repo description

This repository provides production-ready Helm charts with a strong focus on automation, security, and reliable Kubernetes deployments. It is designed to support consistent delivery through strict CI validation, deterministic release workflows, and automated dependency management. Security is built into both the delivery pipeline and the chart defaults, including signed releases, verifiable artifacts, and hardened Kubernetes settings. The goal is to make production deployments safer, more repeatable, and easier to maintain.

## Image provenance

The default image is `docker.io/mpepping/cyberchef` because it publishes v-prefixed release tags matching the chart `appVersion`. If you prefer the upstream GCHQ image, set `image.repository=ghcr.io/gchq/cyberchef` and set the matching upstream tag explicitly. For immutable deployments, set `image.digest`.

## Pod Security Admission (PSA) Support version 1.35

| Mode    | Level      | Supported | Description                                                                                                        |
| ------- | ---------- | --------- | ------------------------------------------------------------------------------------------------------------------ |
| enforce | restricted | ✅ Yes     | Chart is fully compliant with the **restricted** profile. Pods will run successfully when this policy is enforced. |
| enforce | baseline   | ✅ Yes     | Chart meets **baseline** requirements.                                                                             |
| enforce | privileged | ✅ Yes     | Not required; chart does not rely on privileged features.                                                          |
| warn    | restricted | ✅ Yes     | No warnings expected when using restricted profile.                                                                |
| audit   | restricted | ✅ Yes     | No audit violations expected.                     

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| Vojtech Hrabal | <hrabalvojtech@gmail.com> | <https://github.com/hrabalvojta> |

## Source Code

* <https://github.com/gchq/CyberChef>

## Requirements

Kubernetes: `>=1.23.0-0`

## Installation

Add the HV helm charts repository and install chart with the release name my-cyberchef

```bash
helm repo add hv-charts https://hrabalvojta.github.io/helm-charts
helm install my-cyberchef hv-charts/cyberchef --version 0.4.0
```

Or alternatively you can use oci:

```bash
helm install my-cyberchef oci://ghcr.io/hrabalvojta/helm-charts/cyberchef --version 0.4.0
```

```bash
cosign verify \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  --certificate-identity-regexp='^https://github.com/hrabalvojta/helm-charts/.github/workflows/release.yaml@.+$' \
  ghcr.io/hrabalvojta/helm-charts/cyberchef:0.4.0
```

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` |  |
| autoscaling.enabled | bool | `false` |  |
| autoscaling.maxReplicas | int | `10` |  |
| autoscaling.minReplicas | int | `1` |  |
| autoscaling.targetCPUUtilizationPercentage | int | `80` |  |
| config | object | `{"default_conf":"","nginx_conf":""}` | Optional overrides for the bundled nginx configuration files. |
| containerPort | int | `8000` | Port exposed by the CyberChef container and nginx listener. |
| env | object | `{"TZ":"UTC"}` | Default environment variables for the CyberChef container. |
| extraEnv | list | `[]` | Additional Kubernetes `env` entries appended to the CyberChef container. |
| extraObjects | list | `[]` | Additional Kubernetes manifests rendered by this chart. |
| fullnameOverride | string | `""` |  |
| httpRoute | object | `{"annotations":{},"enabled":false,"hostnames":["chart-example.local"],"parentRefs":[{"name":"gateway","sectionName":"http"}],"rules":[{"matches":[{"path":{"type":"PathPrefix","value":"/"}}]}]}` | Expose the service via gateway-api HTTPRoute Requires Gateway API resources and suitable controller installed within the cluster (see: https://gateway-api.sigs.k8s.io/guides/) |
| image.digest | string | `""` |  |
| image.pullPolicy | string | `"IfNotPresent"` |  |
| image.repository | string | `"docker.io/mpepping/cyberchef"` |  |
| image.tag | string | `""` |  |
| imagePullSecrets | list | `[]` |  |
| ingress.annotations | object | `{}` |  |
| ingress.className | string | `""` |  |
| ingress.enabled | bool | `false` |  |
| ingress.hosts[0].host | string | `"chart-example.local"` |  |
| ingress.hosts[0].paths[0].path | string | `"/"` |  |
| ingress.hosts[0].paths[0].pathType | string | `"ImplementationSpecific"` |  |
| ingress.tls | list | `[]` |  |
| livenessProbe.failureThreshold | int | `6` |  |
| livenessProbe.initialDelaySeconds | int | `30` |  |
| livenessProbe.periodSeconds | int | `10` |  |
| livenessProbe.tcpSocket.port | string | `"http"` |  |
| livenessProbe.timeoutSeconds | int | `5` |  |
| nameOverride | string | `""` |  |
| networkPolicy.egress | list | `[]` |  |
| networkPolicy.enabled | bool | `true` |  |
| nodeSelector | object | `{}` |  |
| podAnnotations | object | `{}` |  |
| podDisruptionBudget.enabled | bool | `false` |  |
| podDisruptionBudget.maxUnavailable | int | `1` |  |
| podLabels | object | `{}` |  |
| podSecurityContext.fsGroup | int | `10001` |  |
| podSecurityContext.runAsGroup | int | `10001` |  |
| podSecurityContext.runAsNonRoot | bool | `true` |  |
| podSecurityContext.runAsUser | int | `10001` |  |
| podSecurityContext.seccompProfile.type | string | `"RuntimeDefault"` |  |
| readinessProbe.failureThreshold | int | `3` |  |
| readinessProbe.httpGet.path | string | `"/healthz"` |  |
| readinessProbe.httpGet.port | string | `"http"` |  |
| readinessProbe.initialDelaySeconds | int | `5` |  |
| readinessProbe.periodSeconds | int | `10` |  |
| readinessProbe.timeoutSeconds | int | `2` |  |
| replicaCount | int | `1` |  |
| resources.limits.ephemeral-storage | string | `"256Mi"` |  |
| resources.limits.memory | string | `"128Mi"` |  |
| resources.requests.cpu | string | `"10m"` |  |
| resources.requests.ephemeral-storage | string | `"16Mi"` |  |
| resources.requests.memory | string | `"16Mi"` |  |
| securityContext.allowPrivilegeEscalation | bool | `false` |  |
| securityContext.capabilities.drop[0] | string | `"ALL"` |  |
| securityContext.privileged | bool | `false` |  |
| securityContext.readOnlyRootFilesystem | bool | `true` |  |
| service.annotations | object | `{}` | Service annotations. |
| service.appProtocol | string | `"http"` | Optional appProtocol value for the service port. |
| service.externalName | string | `""` | Required when `service.type=ExternalName`. |
| service.loadBalancerIP | string | `""` | Optional LoadBalancer IP when supported by the cluster. |
| service.loadBalancerSourceRanges | list | `[]` | Optional LoadBalancer source ranges. |
| service.nodePort | string | `""` | Optional fixed nodePort when `service.type` is `NodePort` or `LoadBalancer`. |
| service.port | int | `8000` |  |
| service.targetPort | string | `"http"` | Service target port. Defaults to the named container port. |
| service.type | string | `"ClusterIP"` |  |
| serviceAccount.annotations | object | `{}` |  |
| serviceAccount.automount | bool | `false` |  |
| serviceAccount.create | bool | `true` |  |
| serviceAccount.name | string | `""` |  |
| strategy | object | `{"type":"RollingUpdate"}` | Deployment update strategy. |
| tmpVolume | object | `{"sizeLimit":"64Mi"}` | Settings for the writable nginx temporary directory. |
| tmpVolume.sizeLimit | string | `"64Mi"` | Optional size limit for the `/tmp` emptyDir. |
| tolerations | list | `[]` |  |
| volumeMounts | list | `[]` |  |
| volumes | list | `[]` |  |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
