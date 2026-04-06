{{/*
Expand the name of the chart.
*/}}
{{- define "cyberchef.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "cyberchef.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "cyberchef.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "cyberchef.labels" -}}
helm.sh/chart: {{ include "cyberchef.chart" . }}
{{ include "cyberchef.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "cyberchef.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cyberchef.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "cyberchef.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "cyberchef.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Namespace labels, including optional PSA labels.
*/}}
{{- define "cyberchef.namespaceLabels" -}}
{{- with .Values.namespace.labels }}
{{ toYaml . }}
{{- end }}
{{- if .Values.namespace.psa.enabled }}
pod-security.kubernetes.io/enforce: {{ .Values.namespace.psa.enforce | quote }}
pod-security.kubernetes.io/enforce-version: {{ .Values.namespace.psa.version | quote }}
pod-security.kubernetes.io/warn: {{ .Values.namespace.psa.warn | quote }}
pod-security.kubernetes.io/warn-version: {{ .Values.namespace.psa.version | quote }}
pod-security.kubernetes.io/audit: {{ .Values.namespace.psa.audit | quote }}
pod-security.kubernetes.io/audit-version: {{ .Values.namespace.psa.version | quote }}
{{- end }}
{{- end }}
