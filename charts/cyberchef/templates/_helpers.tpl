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
{{- with .Values.commonLabels }}
{{- printf "\n" }}{{ toYaml . }}
{{- end }}
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
Image reference from repository, tag, and optional digest.
*/}}
{{- define "cyberchef.imageReference" -}}
{{- if .digest -}}
{{- printf "%s:%s@%s" .repository .tag .digest }}
{{- else -}}
{{- printf "%s:%s" .repository .tag }}
{{- end }}
{{- end }}

{{/*
CyberChef container image reference.
*/}}
{{- define "cyberchef.image" -}}
{{- include "cyberchef.imageReference" (dict "repository" .Values.image.repository "tag" (default .Chart.AppVersion .Values.image.tag) "digest" .Values.image.digest) }}
{{- end }}

{{/*
Helm test container image reference.
*/}}
{{- define "cyberchef.testImage" -}}
{{- include "cyberchef.imageReference" .Values.test.image }}
{{- end }}

{{/*
Merged resource annotations. Resource-specific annotations override common annotations.
*/}}
{{- define "cyberchef.annotations" -}}
{{- $annotations := dict -}}
{{- with .root.Values.commonAnnotations }}
{{- $annotations = mergeOverwrite $annotations . }}
{{- end }}
{{- with .annotations }}
{{- $annotations = mergeOverwrite $annotations . }}
{{- end }}
{{- if $annotations }}
annotations:
  {{- toYaml $annotations | nindent 2 }}
{{- end }}
{{- end }}

{{/*
ConfigMap data for CyberChef nginx configuration.
*/}}
{{- define "cyberchef.configData" -}}
{{- $config := .Values.config | default (dict) -}}
default.conf: |
  {{- if $config.default_conf }}
  {{- $config.default_conf | trimSuffix "\n" | nindent 2 }}
  {{- else }}
  server {
      listen {{ .Values.containerPort }};
      listen [::]:{{ .Values.containerPort }};
      server_name _;
      root /usr/share/nginx/html;
      index index.html;

      add_header X-Content-Type-Options "nosniff" always;
      add_header X-Frame-Options "SAMEORIGIN" always;
      add_header Referrer-Policy "no-referrer" always;

      location ~ ^/(healthz|livez|readyz)$ {
          access_log off;
          add_header Cache-Control "no-store" always;
          return 200 "ok\n";
      }

      location ~* \.(?:css|js|mjs|png|jpg|jpeg|gif|ico|svg|woff2?)$ {
          try_files $uri =404;
          add_header Cache-Control "public, max-age=86400" always;
      }

      location / {
          try_files $uri $uri/ /index.html;
          add_header Cache-Control "no-cache" always;
      }
  }
  {{- end }}
nginx.conf: |
  {{- if $config.nginx_conf }}
  {{- $config.nginx_conf | trimSuffix "\n" | nindent 2 }}
  {{- else }}
  {{- .Files.Get "files/nginx.conf" | trimSuffix "\n" | nindent 2 }}
  {{- end }}
{{- end }}
