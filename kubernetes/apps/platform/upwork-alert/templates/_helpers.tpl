{{- define "upwork-alert.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "upwork-alert.labels" -}}
app: {{ include "upwork-alert.name" . }}
team: platform
app.kubernetes.io/name: {{ include "upwork-alert.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}
