{{- /* The peer that selects pods by namespace and labels. Arguments: namespace, labels (a dict). */ -}}
{{- define "np.peer" -}}
- namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: {{ .namespace }}
  podSelector:
    matchLabels:
      {{- toYaml .labels | nindent 6 }}
{{- end -}}

{{- define "np.vpcCidr" -}}
{{- required "vpcCidr must be set: Argo CD passes it from the cluster annotation platform.example/vpc-cidr" .Values.vpcCidr -}}
{{- end -}}
