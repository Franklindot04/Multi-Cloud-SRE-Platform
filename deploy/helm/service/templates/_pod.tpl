{{- /*
The pod template of the service: the labels, the annotations and the pod spec. The Deployment and the Rollout both render it, so the
two modes cannot drift apart. It is included under "template:" with nindent 4.
*/ -}}
{{- define "service.podTemplate" -}}
{{- $name := include "service.name" . -}}
metadata:
  labels:
    {{- include "service.labels" . | nindent 4 }}
  {{- if or .Values.podAnnotations .Values.metrics.scrapeAnnotations }}
  annotations:
    {{- if .Values.metrics.scrapeAnnotations }}
    prometheus.io/scrape: "true"
    prometheus.io/port: {{ .Values.port | quote }}
    prometheus.io/path: /metrics
    {{- end }}
    {{- with .Values.podAnnotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- end }}
spec:
  serviceAccountName: {{ $name }}
  automountServiceAccountToken: false
  {{- with .Values.priorityClassName }}
  priorityClassName: {{ . }}
  {{- end }}
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  securityContext:
    {{- include "service.podSecurityContext" . | nindent 4 }}
  terminationGracePeriodSeconds: {{ include "service.gracePeriod" . }}
  {{- if .Values.topologySpread.enabled }}
  topologySpreadConstraints:
    {{- range $key := list "kubernetes.io/hostname" "topology.kubernetes.io/zone" }}
    - maxSkew: {{ $.Values.topologySpread.maxSkew }}
      topologyKey: {{ $key }}
      whenUnsatisfiable: {{ $.Values.topologySpread.whenUnsatisfiable }}
      labelSelector:
        matchLabels:
          {{- include "service.selectorLabels" $ | nindent 10 }}
      # Pods of the old and the new ReplicaSet of a rollout are spread on their own.
      matchLabelKeys:
        - {{ include "service.podHashLabel" $ }}
    {{- end }}
  {{- end }}
  {{- with .Values.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  containers:
    - name: {{ $name }}
      image: {{ include "service.image" . | quote }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      ports:
        - name: http
          containerPort: {{ .Values.port }}
          protocol: TCP
      env:
        {{- include "service.envList" (dict "env" .Values.env "secretEnv" .Values.secretEnv "secretFiles" .Values.secretFiles "extra" (dict "PORT" (toString .Values.port) "SHUTDOWN_DRAIN_SECONDS" (toString .Values.shutdown.drainSeconds) "SHUTDOWN_TIMEOUT_SECONDS" (toString .Values.shutdown.timeoutSeconds))) | trim | nindent 8 }}
      startupProbe:
        httpGet:
          path: {{ .Values.probes.startup.path }}
          port: http
        periodSeconds: {{ .Values.probes.startup.periodSeconds }}
        failureThreshold: {{ .Values.probes.startup.failureThreshold }}
      readinessProbe:
        httpGet:
          path: {{ .Values.probes.readiness.path }}
          port: http
        periodSeconds: {{ .Values.probes.readiness.periodSeconds }}
        timeoutSeconds: {{ .Values.probes.readiness.timeoutSeconds }}
        failureThreshold: {{ .Values.probes.readiness.failureThreshold }}
      livenessProbe:
        httpGet:
          path: {{ .Values.probes.liveness.path }}
          port: http
        periodSeconds: {{ .Values.probes.liveness.periodSeconds }}
        timeoutSeconds: {{ .Values.probes.liveness.timeoutSeconds }}
        failureThreshold: {{ .Values.probes.liveness.failureThreshold }}
      lifecycle:
        preStop:
          # The images have no shell, so the delay uses the Kubernetes sleep action (1.30 and later).
          sleep:
            seconds: {{ .Values.shutdown.preStopSeconds }}
      resources:
        {{- toYaml .Values.resources | trim | nindent 8 }}
      securityContext:
        {{- include "service.containerSecurityContext" . | trim | nindent 8 }}
      {{- /* Left out when empty: a null list is accepted for a Pod but not by the schema of the Rollout. */}}
      {{- if or .Values.tmpVolume.enabled .Values.secretFiles }}
      volumeMounts:
        {{- if .Values.tmpVolume.enabled }}
        - name: tmp
          mountPath: /tmp
        {{- end }}
        {{- include "service.secretMounts" (dict "secretFiles" .Values.secretFiles) | trim | nindent 8 }}
      {{- end }}
  {{- if or .Values.tmpVolume.enabled .Values.secretFiles }}
  volumes:
    {{- if .Values.tmpVolume.enabled }}
    - name: tmp
      emptyDir:
        sizeLimit: {{ .Values.tmpVolume.sizeLimit }}
    {{- end }}
    {{- include "service.secretVolumes" (dict "secretFiles" .Values.secretFiles) | nindent 4 }}
  {{- end }}
{{- end -}}
