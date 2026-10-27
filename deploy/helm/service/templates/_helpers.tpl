{{- define "service.name" -}}
{{- default .Release.Name .Values.name -}}
{{- end -}}

{{- define "service.labels" -}}
app.kubernetes.io/name: {{ include "service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: sre-sample
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- /* registry/name:tag@digest. The digest comes from image.digest or from digests.<service>. */ -}}
{{- define "service.image" -}}
{{- $service := include "service.name" . -}}
{{- $name := default $service .Values.image.name -}}
{{- $digest := default (get .Values.digests $service) .Values.image.digest -}}
{{- $ref := ternary (printf "%s/%s" .Values.image.registry $name) $name (ne .Values.image.registry "") -}}
{{- if .Values.image.tag }}{{ $ref = printf "%s:%s" $ref .Values.image.tag }}{{ end -}}
{{- if $digest }}{{ $ref = printf "%s@%s" $ref $digest }}{{ end -}}
{{- $ref -}}
{{- end -}}

{{- define "service.gracePeriod" -}}
{{- add .Values.shutdown.preStopSeconds .Values.shutdown.drainSeconds .Values.shutdown.timeoutSeconds .Values.shutdown.bufferSeconds -}}
{{- end -}}

{{- /* Pod-level security context, restricted Pod Security level. */ -}}
{{- define "service.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: {{ .Values.runAsUser }}
runAsGroup: {{ .Values.runAsUser }}
fsGroup: {{ .Values.runAsUser }}
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{- define "service.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
runAsNonRoot: true
capabilities:
  drop:
    - ALL
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{- /*
Environment of a container. Arguments (dict): env, secretEnv, secretFiles, extra (a dict of more plain variables).
Secret files become NAME=/var/run/secrets/<secret>/<key>.
*/ -}}
{{- define "service.envList" -}}
{{- $env := merge (dict) (default (dict) .extra) (default (dict) .env) -}}
{{- range $name := keys $env | sortAlpha }}
- name: {{ $name }}
  value: {{ get $env $name | toString | quote }}
{{- end }}
{{- range $name := keys (default (dict) .secretEnv) | sortAlpha }}
{{- $ref := get $.secretEnv $name }}
- name: {{ $name }}
  valueFrom:
    secretKeyRef:
      name: {{ $ref.secret }}
      key: {{ $ref.key }}
{{- end }}
{{- range $name := keys (default (dict) .secretFiles) | sortAlpha }}
{{- $ref := get $.secretFiles $name }}
- name: {{ $name }}
  value: {{ printf "/var/run/secrets/%s/%s" $ref.secret $ref.key | quote }}
{{- end }}
{{- end -}}

{{- /* Secret names used by secretFiles, sorted and unique. Argument: secretFiles. */ -}}
{{- define "service.secretNames" -}}
{{- $names := list -}}
{{- range $_, $ref := (default (dict) .) }}{{ $names = append $names $ref.secret }}{{ end -}}
{{- $names | uniq | sortAlpha | toJson -}}
{{- end -}}

{{- define "service.secretMounts" -}}
{{- range $secret := include "service.secretNames" .secretFiles | fromJsonArray }}
- name: secret-{{ $secret }}
  mountPath: /var/run/secrets/{{ $secret }}
  readOnly: true
{{- end }}
{{- end -}}

{{- define "service.secretVolumes" -}}
{{- $files := default (dict) .secretFiles -}}
{{- range $secret := include "service.secretNames" $files | fromJsonArray }}
{{- $keys := list }}
{{- range $_, $ref := $files }}{{ if eq $ref.secret $secret }}{{ $keys = append $keys $ref.key }}{{ end }}{{ end }}
- name: secret-{{ $secret }}
  secret:
    secretName: {{ $secret }}
    defaultMode: 0440
    items:
      {{- range $key := $keys | uniq | sortAlpha }}
      - key: {{ $key }}
        path: {{ $key }}
      {{- end }}
{{- end }}
{{- end -}}
