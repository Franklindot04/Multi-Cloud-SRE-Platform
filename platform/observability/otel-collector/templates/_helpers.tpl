{{- define "collector.name" -}}
otel-collector
{{- end -}}

{{- define "collector.labels" -}}
app.kubernetes.io/name: {{ include "collector.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: collector
app.kubernetes.io/part-of: observability
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "collector.selectorLabels" -}}
app.kubernetes.io/name: {{ include "collector.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- /* repository:tag@digest */ -}}
{{- define "collector.image" -}}
{{- printf "%s:%s@%s" .Values.image.repository .Values.image.tag .Values.image.digest -}}
{{- end -}}
