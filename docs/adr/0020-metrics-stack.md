# ADR-0020: Metrics stack

- Status: Accepted
- Date: 2026-10-30

## Context

[ADR-0005](0005-observability-stack-choice.md) chose Prometheus (through kube-prometheus-stack), Grafana, Alertmanager and the OpenTelemetry Collector for observability, and left the rest open. The sample services already expose Prometheus metrics, propagate `traceparent` and write trace IDs into their logs, but nothing collects any of it. This change is the first piece of Phase 4: the part that collects and shows metrics. Alert rules, SLOs, logs and traces build on it.

The constraints are the ones of the rest of the platform. A cluster is a couple of small Spot nodes that also run Argo CD, the add-ons, the data layer and the services. Everything is deployed by Argo CD from this repository, behind a cluster label that is off by default. No credential is committed. Access is by port-forward. Nothing may be added that cannot be rendered and checked offline, and what could not be run has to be said.

## Decision

Deployment

- **kube-prometheus-stack with the Prometheus Operator.** The operator turns `ServiceMonitor`, `PodMonitor` and `PrometheusRule` resources into Prometheus configuration, so the services, the data layer and later the SLO rules can each declare what they need next to their own definitions. The chart is vendored the way the CloudNativePG chart is: a wrapper chart under `platform/observability` with the version in `Chart.yaml`, its digest in `Chart.lock`, and the downloaded tarball left out of Git. Chart 92.16.0, operator 0.94.2.
- **Gated by a cluster label.** `platform.example/observability=true`, set by `scripts/bootstrap-argocd.sh --enable-observability` and off by default, like the data layer and the services. Five ApplicationSets (`observability-secrets`, `-stack`, `-collector`, `-monitors`, `-dashboards`, waves 10 to 14) deploy it to the `observability` namespace.
- **A new AppProject, `platform-observability`.** `platform-addons` allows other namespaces and a wider set of cluster-scoped kinds, and `platform-data` and `platform-apps` are scoped to the data and shop namespaces. The new project allows `observability` and `kube-system` (the stack creates the CoreDNS Service there), the namespace, CRDs and read-only roles at cluster scope (no webhook configurations), and a short list of namespaced kinds. `make observability-check` renders every chart and fails if something it renders is outside that list.
- **Server-side apply.** Several of the operator's CRDs are larger than the 256 KiB that client-side apply can store in its annotation, so the Application syncs with `ServerSideApply=true`. The check fails if a CRD above that size is rendered and the Application does not use it.
- **Pod Security `restricted`**, enforced, warn and audit, on the namespace. Every pod the charts render meets it, and the check fails if one stops meeting it. The operator's admission webhooks are off (they need a certificate and a hook Job, and only validate rule files); with them go the operator's TLS listener and a long-lived service account token Secret (the control-plane monitors use the pod's projected token instead).

Storage and sizing

- **No persistent volumes by default.** Prometheus and Grafana use `emptyDir`. Retention is two days, with a 1 GB size cap so a cardinality mistake cannot fill a node's disk. Metrics and anything created in the Grafana UI are lost when a pod is rescheduled, which on Spot nodes will happen; dashboards and the data source come from Git, so nothing that matters is only in the UI. Persistence is an overlay, `values-persistent.yaml`, that is off by default, documented and rendered by the checks.
- **Small requests.** About 0.29 vCPU and 0.95 GiB of memory for the whole stack including the collector, and no priority class: the stack must never preempt the services, so when a node is short of room the stack goes first.
- **No ingress.** Grafana and Prometheus are reached with `kubectl port-forward`.

What is switched off, and why

- **Alertmanager is deferred.** Nothing would receive an alert. It arrives with the SLO and burn-rate work, together with the rules it routes ([ADR-0023](0023-slos-and-alerting.md)). The chart's default rules and the dashboards that depend on them are off for the same reason.
- **node-exporter is disabled.** It needs `hostNetwork`, `hostPID` and `hostPath` volumes, which `restricted` does not allow, and the namespace enforces `restricted`. Node CPU and memory still come from the kubelet and cAdvisor (the cluster dashboard sums the pods of each node), but node-level disk, network and filesystem metrics are missing. If they are wanted, node-exporter goes into its own namespace that is allowed to be privileged, with its own AppProject, and not into this one.

Grafana

- **The admin password is generated in the cluster**, once, by a Sync hook Job that creates the Secret `grafana-admin` if it does not exist, the same mechanism as the data layer's credentials ([ADR-0018](0018-secret-generation-and-ordering.md)). It is random, never committed, never printed, and never rotated by a re-sync. Grafana reads it with `admin.existingSecret`; its pod waits in `CreateContainerConfigError` until the Secret exists.
- **Dashboards are JSON in labelled ConfigMaps** (`grafana_dashboard: "1"`) that the Grafana sidecar loads, from a local chart with one file per dashboard. They use a data source variable and no fixed data source uid. The sidecar watches the `observability` namespace only; its default, every namespace, needs a cluster-wide role to read ConfigMaps.
- **Three dashboards:** the sample services (request rate, error rate and latency by service and route), the data layer (PostgreSQL, and RabbitMQ as the services see it) and cluster capacity (node and pod CPU and memory, restarts, pods that are not ready).
- **Only confirmed metric names.** `scripts/chart-contract-check.py dashboards` extracts every metric name from every query and rejects any that is not found in the service code, the vendored CloudNativePG chart (its reference dashboard and default queries), the vendored stack chart (its rules), or `dashboards/confirmed-upstream.txt`, a short list of names confirmed against upstream documentation, with the source and date. The service panels use the `http_*` series and the data layer series as the code defines them. RabbitMQ broker metrics (queue depth, message rates) are **not in the dashboard**: no file in the repository or in a vendored artefact names them, so they were left out rather than guessed.

Collection

- **The OpenTelemetry Collector** runs as a Deployment of the plain distribution, with the image pinned by digest. It accepts OTLP over gRPC and HTTP, applies `memory_limiter` and `batch`, exposes the metrics it receives and its own metrics for Prometheus (scraped through a `ServiceMonitor`), and accepted traces only to drop them when this was written: the `debug` exporter at `basic` verbosity until a trace backend existed (its traces pipeline now exports to Tempo, see [ADR-0022](0022-tracing-stack.md)). Listeners bind to the pod's address, not to every interface.
- **The services do not send OTLP.** None of them uses an OpenTelemetry SDK or reads an `OTEL_*` setting, so no endpoint setting was added to `deploy/helm` and no application code was changed. The collector is ready for the day they are instrumented.
- **Monitors live in the `observability` namespace** and select their targets in `shop` and `data`: a `ServiceMonitor` per sample service, a `ServiceMonitor` for RabbitMQ (the operator adds the port `prometheus` to the cluster's Service), and a **`PodMonitor`** for PostgreSQL, because CloudNativePG serves metrics on the instance pods and none of its Services exposes that port. Prometheus selects every monitor in every namespace, so they need no release label.

Teardown

- **Operator finalizers.** `scripts/teardown-prep.sh` removes a known finalizer only when its operator is confirmed gone ([ADR-0018](0018-secret-generation-and-ordering.md)). The Prometheus Operator was checked in its source at the pinned version (0.94.2) and in the pinned chart. Its only finalizer is `monitoring.coreos.com/status-cleanup`, put on `Prometheus`, `PrometheusAgent`, `Alertmanager` and `ThanosRuler` objects only, never on `ServiceMonitor`, `PodMonitor`, `Probe` or `PrometheusRule`, and only when the feature gate `StatusForConfigurationResources` is on. The gate is off by default (`pkg/operator/config.go`), the chart passes no feature gate unless `prometheusOperator.featureGates` is set, and these values do not set it. The chart's `*/finalizers` rules in the operator's ClusterRole are the permission the Kubernetes owner-reference check needs, not a finalizer. So in this configuration nothing holds these objects when the operator is removed first, and the script does not remove any Prometheus finalizer.
- **If the gate is ever enabled** and the operator goes first, a `Prometheus` object would stay in `Terminating` and its pods with it. The script then waits for the pods in the `observability` namespace, times out, and prints the finalizer and the explanation. It does not clear it: that would be a decision for the person who turned the gate on.
- **The optional volumes.** The claims of the persistent overlay are created outside Terraform, are not removed by `terraform destroy`, and the Prometheus claim is not removed with the Application (a StatefulSet keeps its claims). `scripts/teardown-prep.sh` now deletes the claims in the `observability` namespace if it exists, after the pods are gone, and waits for them. The label `platform.example/observability` is removed with the other two.

## Consequences

- A cluster labelled for it gets Prometheus, Grafana, kube-state-metrics, a collector, monitors for the services and the data layer, and three dashboards, with no credential in Git and nothing exposed outside the cluster. Without the label nothing changes.
- **Capacity is tight on the default node group.** The platform's requests, including this stack, add up to about 3.0 vCPU and 6.1 GiB of memory against roughly 3.9 vCPU and 13.6 GiB allocatable on the two default nodes (`t3.large` or `m5.large`; allocatable and the add-ons' own requests are estimates, not measured). CPU is the limit, at about 78%. If a Spot node is reclaimed the remaining one cannot hold everything. A third node brings CPU requests to about half of allocatable and gives the high-availability data profile the three nodes it needs; the Terraform defaults were not changed by this work.
- Data is lost when a Prometheus or Grafana pod is rescheduled, by design. Two days of history is also the most an incident review can look back at, until persistence or a long-term store is chosen.
- Without node-exporter, node disk and network figures do not exist, and the node CPU and memory shown are the sum of pod usage (no system processes).
- Without admission webhooks, a malformed `PrometheusRule` is rejected only by CI once rules exist, and not on `kubectl apply`.
- Dashboards cannot show a metric that is not confirmed, which keeps them honest and means a new panel needs a source for each new name.
- The images in the stack chart are pinned by tag through the chart version, not by digest; only the collector image is pinned by digest. The Grafana image is the distroless build.

## What this does not cover

- **Only part of it is recorded on a cluster.** See below, and [the screenshots](../observability-evidence.md).
- **No alerting.** No Alertmanager, no alert or recording rules, no SLOs, no burn-rate alerts, no notification route. [ADR-0023](0023-slos-and-alerting.md) later adds the SLO rules and burn-rate alerts; there is still no Alertmanager.
- **No traces, and logs only through [ADR-0021](0021-logging-stack.md).** Traces were accepted and dropped when this was written; [ADR-0022](0022-tracing-stack.md) adds a trace backend. Logs are collected by the logging stack of [ADR-0021](0021-logging-stack.md).
- **No long-term or cross-cluster storage.** One Prometheus per cluster, two days, and only the EKS cluster exists.
- **No RabbitMQ broker metrics in a dashboard**, no Valkey metrics (the chart has no exporter enabled), and the CloudNativePG and RabbitMQ operators are not scraped.
- **No node-level metrics** (node-exporter), and no control-plane metrics (EKS and GKE do not expose them).
- **No network policies** on the namespace and no authentication in front of Grafana beyond its own login; access is by port-forward through the Kubernetes API. TLS, SSO and RBAC for Grafana belong to the security phase.
- **The services are not instrumented** with OpenTelemetry.
- **The CRD schemas used offline** for the custom resources come from a pinned catalog commit that may lag the operator.

## What has been exercised

Checked on a laptop: every chart with `helm lint --strict`, `helm template` and `kubeconform` (custom resources against the pinned CRD catalog), for both clouds and the persistent values; the operator's CRDs for presence, form and the server-side apply rule; chart pinning against `Chart.lock` and the downloaded tarball; restricted Pod Security, no volumes or Alertmanager or ingress in the default profile, Grafana's secret wiring with no password rendered, the collector's digest pin and the AppProject fit, each shown to fail when its rule is broken; the dashboards (valid JSON, unique uid and title, the data source variable, the sidecar label, confirmed metric names, and that the ConfigMaps hold what the files hold); the bootstrap flag in a dry run; the teardown steps against a fake `kubectl`, including the stuck-pod message and the claim deletions. The Collector configuration was validated with the pinned image, and the image was run locally with the Deployment's hardening flags: it accepted OTLP traces and metrics, dropped the traces, and exposed the metrics on both Prometheus ports.

Observed on a real EKS cluster ([evidence](../observability-evidence.md)): every Application Synced and Healthy, which covers the sync order and the retries around the CRDs; the operator, Prometheus and Grafana running in the restricted namespace, with the data source and the dashboards loaded; every scrape target up (the four services, PostgreSQL, RabbitMQ, the collector, the kubelet, kube-state-metrics, CoreDNS and the API server); and the Cluster capacity, Sample services and Data layer dashboards showing data. The cluster was temporary and has been destroyed: at the end of the second session `scripts/teardown-prep.sh` and then `scripts/teardown-argocd.sh` were run on it, `terraform destroy` removed all 54 resources, and the AWS checks came back empty.

Not covered by those runs:

- the capacity estimate was not compared with the requests of the running pods in any recorded way;
- the error-rate panels were empty because there were no 5xx responses, so they have not shown an error;
- the services are not instrumented, so the collector received no telemetry.

## Alternatives considered

- **Prometheus without the operator** (a plain chart and static scrape configuration). Fewer moving parts and no CRDs, but every scrape target would be edited in one central file, and the SLO rules of the next step fit the operator's `PrometheusRule` better.
- **Persistence on by default.** The data is worth keeping, but a ReadWriteOnce volume ties a pod to one zone on a multi-zone Spot cluster and adds volumes that outlive `terraform destroy`; a reference platform can lose two days of metrics.
- **Alertmanager now.** It would run and route nothing.
- **node-exporter in the same namespace, with the namespace relaxed to `privileged`.** It would give node metrics at the price of the whole namespace losing its protection. A separate, isolated namespace is the better way to add it.
- **A password in a values file, or a Secret committed encrypted.** Either puts the credential in Git, in a form that would need rotating there. In-cluster generation is the interim mechanism until external secrets management exists.
- **ServiceMonitors in the services' own chart.** The chart has an optional one, off by default. Putting the monitors in the observability namespace keeps the services and the data layer unchanged and lets one Application own all the monitors.
- **Clearing the Prometheus Operator's finalizer in the teardown script as a precaution.** It does not exist in this configuration; a step that removes something that is not there is a step that can hide a real problem. The script reports instead.
- **Using the chart's bundled dashboards.** They need the chart's default rules, which are off, and their metric names are not checked here.
