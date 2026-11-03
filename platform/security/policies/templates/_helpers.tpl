{{- /* The validation action of a policy: its own override, or the default. Argument: a dict with root and name. */ -}}
{{- define "policies.action" -}}
{{- $own := (get $.root.Values.policies $.name).action | default "" -}}
{{- $action := ternary $.root.Values.action $own (eq $own "") -}}
{{- if eq $action "Audit" -}}Audit
{{- else if eq $action "Enforce" -}}Deny
{{- else -}}{{ fail (printf "the action of %s must be Audit or Enforce, not %q" $.name $action) }}
{{- end -}}
{{- end -}}

{{- /* The resources a policy on pods matches, and where. Pods only: the subresources (pods/ephemeralcontainers, pods/status) are not matched. */ -}}
{{- define "policies.matchPods" -}}
namespaceSelector:
  matchExpressions:
    - key: kubernetes.io/metadata.name
      operator: In
      values:
        {{- toYaml .Values.scope.namespaces | nindent 8 }}
resourceRules:
  - apiGroups: [""]
    apiVersions: [v1]
    operations: [CREATE, UPDATE]
    resources: [pods]
{{- end -}}

{{- define "policies.matchControllers" -}}
namespaceSelector:
  matchExpressions:
    - key: kubernetes.io/metadata.name
      operator: In
      values:
        {{- toYaml .Values.scope.namespaces | nindent 8 }}
resourceRules:
  - apiGroups: [apps]
    apiVersions: [v1]
    operations: [CREATE, UPDATE]
    resources: [deployments, statefulsets, daemonsets]
  {{- /* Argo Rollouts (platform/delivery): a Rollout has spec.template like a Deployment. The rule is harmless where the CRD is not installed. */}}
  - apiGroups: [argoproj.io]
    apiVersions: [v1alpha1]
    operations: [CREATE, UPDATE]
    resources: [rollouts]
{{- end -}}

{{- define "policies.autogen" -}}
autogen:
  podControllers:
    controllers:
      {{- toYaml .Values.podControllers | nindent 6 }}
{{- end -}}

{{- /* Left out of every policy: workloads that carry the exempt label with the value "true". A matchCondition and not an objectSelector, because
Kyverno does not generate the rules for pod controllers (autogen) when the policy has an objectSelector. */ -}}
{{- define "policies.notExempt" -}}
- name: not-exempt
  expression: "!(has(object.metadata.labels) && '{{ .Values.exemptLabel }}' in object.metadata.labels && object.metadata.labels['{{ .Values.exemptLabel }}'] == 'true')"
{{- end -}}
