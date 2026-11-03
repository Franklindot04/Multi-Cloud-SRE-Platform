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

{{- /* The replicas the service starts with: the autoscaler's minimum, or the fixed count. The budget is rendered when it is above one. */ -}}
{{- define "service.minReplicas" -}}
{{- if .Values.autoscaling.enabled -}}{{ .Values.autoscaling.minReplicas }}{{- else -}}{{ default 1 .Values.replicas }}{{- end -}}
{{- end -}}

{{- /* Refuses values that would make the autoscaler and the Deployment fight, or that do not mean what they say. */ -}}
{{- define "service.validateScaling" -}}
{{- if and .Values.autoscaling.enabled (not (kindIs "invalid" .Values.replicas)) -}}
{{- fail "replicas must not be set when autoscaling.enabled is true: the autoscaler owns the replica count, and a value in the Deployment would be reset on every sync" -}}
{{- end -}}
{{- if and .Values.autoscaling.enabled (lt (int .Values.autoscaling.maxReplicas) (int .Values.autoscaling.minReplicas)) -}}
{{- fail "autoscaling.maxReplicas must not be lower than autoscaling.minReplicas" -}}
{{- end -}}
{{- if and .Values.autoscaling.enabled (lt (int .Values.autoscaling.minReplicas) 1) -}}
{{- fail "autoscaling.minReplicas must be at least 1" -}}
{{- end -}}
{{- if not (has .Values.topologySpread.whenUnsatisfiable (list "ScheduleAnyway" "DoNotSchedule")) -}}
{{- fail "topologySpread.whenUnsatisfiable must be ScheduleAnyway or DoNotSchedule" -}}
{{- end -}}
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

{{- /*
The label that tells the pods of one revision from another: the Deployment controller sets pod-template-hash, the Rollout controller
sets rollouts-pod-template-hash. The topology spread uses it so the pods of the stable and the canary revision are spread on their own.
*/ -}}
{{- define "service.podHashLabel" -}}
{{- ternary "rollouts-pod-template-hash" "pod-template-hash" (eq (include "service.rolloutEnabled" .) "true") -}}
{{- end -}}

{{- /* "true" when the workload is rendered as an Argo Rollout and not as a Deployment. */ -}}
{{- define "service.rolloutEnabled" -}}
{{- if .Values.rollout.enabled -}}true{{- else -}}false{{- end -}}
{{- end -}}

{{- /* Refuses rollout values that would render something that cannot work or that does not mean what it says. */ -}}
{{- define "service.validateRollout" -}}
{{- if .Values.rollout.enabled -}}
{{- if not .Values.rollout.steps -}}
{{- fail "rollout.steps must list at least one step: a canary without steps is promoted at once" -}}
{{- end -}}
{{- if lt (int .Values.rollout.progressDeadlineSeconds) 1 -}}
{{- fail "rollout.progressDeadlineSeconds must be set: a rollout without a deadline can hang for ever" -}}
{{- end -}}
{{- if and (not (kindIs "string" .Values.rollout.maxUnavailable)) (gt (float64 .Values.rollout.maxUnavailable) (float64 .Values.podDisruptionBudget.maxUnavailable)) -}}
{{- fail "rollout.maxUnavailable must not be above podDisruptionBudget.maxUnavailable" -}}
{{- end -}}
{{- if .Values.rollout.analysis.enabled -}}
{{- $a := .Values.rollout.analysis -}}
{{- if or (le (float64 $a.successRatio) 0.0) (gt (float64 $a.successRatio) 1.0) (le (float64 $a.fastRatio) 0.0) (gt (float64 $a.fastRatio) 1.0) -}}
{{- fail "rollout.analysis.successRatio and fastRatio must be above 0 and at most 1" -}}
{{- end -}}
{{- if not $a.service -}}
{{- fail "rollout.analysis.service must name the service label of the series, as the SLO rules do (the values file of the service sets it)" -}}
{{- end -}}
{{- if lt (int $a.minRequests) 1 -}}
{{- fail "rollout.analysis.minRequests must be at least 1: with no minimum an idle canary would be measured on nothing" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
