{{- define "network-observability.labels" -}}
app.kubernetes.io/part-of: network-observability
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "network-observability.jsonExporterName" -}}
{{- printf "%s-json-exporter" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "network-observability.blackboxExporterName" -}}
{{- printf "%s-blackbox-exporter" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
