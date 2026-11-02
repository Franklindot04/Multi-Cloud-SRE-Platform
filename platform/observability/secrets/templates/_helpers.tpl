{{- /* "true" when the secrets come from Parameter Store through ExternalSecrets, empty when the in-cluster generator makes them. */ -}}
{{- define "secrets.external" -}}
{{- if eq (toString .Values.externalSecrets.enabled) "true" -}}true{{- end -}}
{{- end -}}

{{- /* The prefix of the parameter names, /<prefix>/<environment>, without a trailing slash. */ -}}
{{- define "secrets.prefix" -}}
{{- trimSuffix "/" (required "externalSecrets.prefix must be set when externalSecrets.enabled is true: Argo CD passes it from the cluster annotation platform.example/secrets-prefix (Terraform output secrets_parameter_prefix)" .Values.externalSecrets.prefix) -}}
{{- end -}}

{{- /* The full parameter name for a path from scripts/secrets/manifest.yaml. */ -}}
{{- define "secrets.parameter" -}}
{{- printf "%s/%s" (include "secrets.prefix" .root) .path -}}
{{- end -}}
