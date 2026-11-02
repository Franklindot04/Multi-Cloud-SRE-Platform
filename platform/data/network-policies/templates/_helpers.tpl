{{- /* The peer that selects pods by namespace and labels. Arguments: namespace, labels (a dict). */ -}}
{{- define "np.peer" -}}
- namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: {{ .namespace }}
  podSelector:
    matchLabels:
      {{- toYaml .labels | nindent 6 }}
{{- end -}}

{{- /* Peers for the sample services named in a list. Arguments: root (the chart context), names. */ -}}
{{- define "np.services" -}}
{{- range $name := .names }}
- namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: {{ $.root.Values.services.namespace }}
  podSelector:
    matchLabels:
      app.kubernetes.io/name: {{ $name }}
      app.kubernetes.io/part-of: sre-sample
{{- end }}
{{- end -}}

{{- define "np.vpcCidr" -}}
{{- required "vpcCidr must be set: Argo CD passes it from the cluster annotation platform.example/vpc-cidr" .Values.vpcCidr -}}
{{- end -}}
