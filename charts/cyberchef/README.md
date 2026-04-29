# cyberchef

![Version: 0.3.1](https://img.shields.io/badge/Version-0.3.1-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: v11.0.0](https://img.shields.io/badge/AppVersion-v11.0.0-informational?style=flat-square)

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
helm install my-cyberchef hv-charts/cyberchef --version 0.3.1
```

Or alternatively you can use oci:

```bash
helm install my-cyberchef oci://ghcr.io/hrabalvojta/helm-charts/cyberchef --version 0.3.1
```

```bash
cosign verify \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  --certificate-identity-regexp='^https://github.com/hrabalvojta/helm-charts/.github/workflows/release.yaml@.+$' \
  ghcr.io/hrabalvojta/helm-charts/cyberchef:0.3.1
```

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` |  |
| autoscaling | object | `{"enabled":false,"maxReplicas":10,"minReplicas":1,"targetCPUUtilizationPercentage":80}` | HorizontalPodAutoscaler configuration. |
| commonAnnotations | object | `{}` | Annotations applied to all rendered Kubernetes resources. |
| commonLabels | object | `{}` | Labels applied to all rendered Kubernetes resources. |
| config | object | `{"default_conf":"","nginx_conf":""}` | Optional overrides for the bundled nginx configuration files. |
| containerPort | int | `8000` | Port exposed by the CyberChef container and nginx listener. |
| defaultPodAntiAffinity | object | `{"enabled":true,"topologyKey":"kubernetes.io/hostname"}` | Default soft pod anti-affinity used when `affinity` is empty. |
| deploymentAnnotations | object | `{}` | Deployment annotations. |
| enableServiceLinks | bool | `false` | Enable Kubernetes service environment variable injection in pods. |
| env | object | `{"TZ":"UTC"}` | Default environment variables for the CyberChef container. |
| extraEnv | list | `[]` | Additional Kubernetes `env` entries appended to the CyberChef container. |
| extraObjects | list | `[]` | Additional Kubernetes manifests rendered by this chart. |
| fullnameOverride | string | `""` | Override the fully qualified app name. |
| httpRoute | object | `{"annotations":{},"enabled":false,"hostnames":["chart-example.local"],"parentRefs":[{"name":"gateway","sectionName":"http"}],"rules":[{"matches":[{"path":{"type":"PathPrefix","value":"/"}}]}]}` | Gateway API HTTPRoute configuration. |
| httpRoute.annotations | object | `{}` | HTTPRoute annotations. |
| httpRoute.enabled | bool | `false` | Enable HTTPRoute. |
| httpRoute.hostnames | list | `["chart-example.local"]` | Hostnames matched by the HTTPRoute. |
| httpRoute.parentRefs | list | `[{"name":"gateway","sectionName":"http"}]` | Gateway parent references. |
| httpRoute.rules | list | `[{"matches":[{"path":{"type":"PathPrefix","value":"/"}}]}]` | HTTPRoute rules. |
| image.digest | string | `""` | Optional immutable image digest. When set, the image renders as repository:tag@digest. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"docker.io/mpepping/cyberchef"` | Container image repository. |
| image.tag | string | `""` | Overrides the image tag whose default is the chart appVersion. |
| imagePullSecrets | list | `[]` | Image pull secrets. |
| ingress | object | `{"annotations":{},"className":"","enabled":false,"hosts":[{"host":"chart-example.local","paths":[{"path":"/","pathType":"ImplementationSpecific"}]}],"tls":[]}` | Ingress configuration. |
| livenessProbe | object | `{"failureThreshold":6,"httpGet":{"path":"/livez","port":"http"},"initialDelaySeconds":30,"periodSeconds":10,"timeoutSeconds":5}` | Liveness probe. |
| nameOverride | string | `""` | Override the chart name. |
| networkPolicy.egress | list | `[]` | Egress rules. Empty means deny all egress. |
| networkPolicy.enabled | bool | `true` |  |
| networkPolicy.ingressFrom | list | `[]` | Optional ingress peer selectors for the generated NetworkPolicy. Empty allows ingress from any source to the HTTP port. |
| nodeSelector | object | `{}` |  |
| podAnnotations | object | `{}` | Pod annotations. |
| podDisruptionBudget.enabled | bool | `false` |  |
| podDisruptionBudget.maxUnavailable | int | `1` |  |
| podLabels | object | `{}` | Pod labels. |
| podSecurityContext.fsGroup | int | `10001` |  |
| podSecurityContext.runAsGroup | int | `10001` |  |
| podSecurityContext.runAsNonRoot | bool | `true` |  |
| podSecurityContext.runAsUser | int | `10001` |  |
| podSecurityContext.seccompProfile.type | string | `"RuntimeDefault"` |  |
| readinessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/readyz","port":"http"},"initialDelaySeconds":5,"periodSeconds":10,"timeoutSeconds":2}` | Readiness probe. |
| replicaCount | int | `1` | Number of Deployment replicas when autoscaling is disabled. |
| resources | object | `{"limits":{"cpu":"200m","ephemeral-storage":"256Mi","memory":"128Mi"},"requests":{"cpu":"10m","ephemeral-storage":"16Mi","memory":"16Mi"}}` | Container resource requests and limits. |
| securityContext.allowPrivilegeEscalation | bool | `false` |  |
| securityContext.capabilities.drop[0] | string | `"ALL"` |  |
| securityContext.privileged | bool | `false` |  |
| securityContext.readOnlyRootFilesystem | bool | `true` |  |
| service.annotations | object | `{}` | Service annotations. |
| service.appProtocol | string | `"http"` | Optional appProtocol value for the service port. |
| service.loadBalancerIP | string | `""` | Optional LoadBalancer IP when supported by the cluster. |
| service.loadBalancerSourceRanges | list | `[]` | Optional LoadBalancer source ranges. |
| service.nodePort | string | `""` | Optional fixed nodePort when `service.type` is `NodePort` or `LoadBalancer`. |
| service.port | int | `8000` | Service port. |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | Service account annotations. |
| serviceAccount.automount | bool | `false` | Automatically mount service account API credentials. |
| serviceAccount.create | bool | `true` | Create a service account. |
| serviceAccount.name | string | `""` | Service account name. Generated when empty and `serviceAccount.create=true`. |
| serviceLabels | object | `{}` | Service labels. |
| strategy | object | `{"type":"RollingUpdate"}` | Deployment update strategy. |
| test | object | `{"image":{"digest":"","pullPolicy":"IfNotPresent","repository":"docker.io/library/busybox","tag":"1.37.0"},"resources":{"limits":{"cpu":"50m","ephemeral-storage":"16Mi","memory":"32Mi"},"requests":{"cpu":"10m","ephemeral-storage":"8Mi","memory":"16Mi"}}}` | Helm test pod configuration. |
| test.image.digest | string | `""` | Optional immutable Helm test image digest. |
| test.image.pullPolicy | string | `"IfNotPresent"` | Helm test image pull policy. |
| test.image.repository | string | `"docker.io/library/busybox"` | Helm test image repository. |
| test.image.tag | string | `"1.37.0"` | Helm test image tag. |
| test.resources | object | `{"limits":{"cpu":"50m","ephemeral-storage":"16Mi","memory":"32Mi"},"requests":{"cpu":"10m","ephemeral-storage":"8Mi","memory":"16Mi"}}` | Helm test pod resource requests and limits. |
| tmpVolume | object | `{"sizeLimit":"64Mi"}` | Settings for the writable nginx temporary directory. |
| tmpVolume.sizeLimit | string | `"64Mi"` | Optional size limit for the `/tmp` emptyDir. |
| tolerations | list | `[]` |  |
| topologySpreadConstraints | list | `[]` | Pod topology spread constraints. |
| volumeMounts | list | `[]` | Additional volume mounts appended to the CyberChef container. |
| volumes | list | `[]` | Additional volumes appended to the Deployment pod. |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
