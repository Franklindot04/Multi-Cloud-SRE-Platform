# Observability

Configuration for metrics, logs, traces, alerting and dashboards, plus SLO recording and burn-rate alert rules generated from [`docs/slo`](../../docs/slo). Stack choice is recorded in [ADR-0005](../../docs/adr/0005-observability-stack-choice.md).

**Today this directory holds the metrics foundation, the logging stack and a trace backend:** the Prometheus Operator, Prometheus, Grafana, kube-state-metrics, an OpenTelemetry Collector, the monitors that point Prometheus at the sample services, the data layer, the logging stack and Tempo, four dashboards, Loki with Alloy, which collects the logs of the `shop` and `data` namespaces, and Tempo, which stores the traces the collector receives. Argo CD deploys it to clusters labelled `platform.example/observability=true` (off by default; `scripts/bootstrap-argocd.sh --enable-observability`). **Nothing is installed by these definitions themselves.** The metrics stack and the logging stack have run on a real cluster (see [What is and is not verified](#what-is-and-is-not-verified)); Tempo has not, and no service sends traces yet. Alert and recording rules and Alertmanager come in later steps. The reasoning is in [ADR-0020](../../docs/adr/0020-metrics-stack.md) (metrics) [ADR-0021](../../docs/adr/0021-logging-stack.md) (logs) and [ADR-0022](../../docs/adr/0022-tracing-stack.md) (traces); how to enable it, reach it and troubleshoot it is in the [observability runbook](../../docs/runbooks/observability.md). The bootstrap script writes every cluster label on each run, so repeat the flags you already use (for example `--enable-data`) when you add this one. How it looked on a real cluster, with screenshots, is in [Observability on a real cluster](../../docs/observability-evidence.md).

## Components and versions

Checked on **2026-10-30** against each project's chart repository and release page.

| Component | Pinned | Source | Licence |
| --- | --- | --- | --- |
| `kube-prometheus-stack` chart | **92.16.0**, Prometheus Operator **v0.94.2** | `https://prometheus-community.github.io/helm-charts` | Apache-2.0 |
| Prometheus | **v3.15.1** (the version the chart selects) | same chart | Apache-2.0 |
| Grafana | **13.3.0**, distroless image (Grafana chart 14.2.0 inside the stack chart) | same chart | AGPL-3.0 |
| kube-state-metrics | **v2.20.0** (chart 8.8.0 inside the stack chart) | same chart | Apache-2.0 |
| OpenTelemetry Collector | **0.164.0** (released 2026-10-26), image pinned by digest | `ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector` | Apache-2.0 |
| `loki` chart | **7.5.0**, Loki **3.6.11** (the image tag the chart sets) | `https://grafana.github.io/helm-charts` | AGPL-3.0 |
| `alloy` chart | **1.15.0**, Alloy **v1.21.3** | same repository | Apache-2.0 |
| `tempo` chart | **1.24.4**, Tempo **2.9.0** (the image tag the chart sets). **The chart is deprecated upstream**; see [ADR-0022](../../docs/adr/0022-tracing-stack.md) | same repository | AGPL-3.0 |

The stack chart is pinned by version in [`kube-prometheus-stack/Chart.yaml`](kube-prometheus-stack/Chart.yaml) and by digest in [`Chart.lock`](kube-prometheus-stack/Chart.lock), like the add-ons and the CloudNativePG chart. As with them, the downloaded tarball (`charts/`) is not committed: Argo CD runs `helm dependency build` against the lock file, and `make observability-check` does the same and renders from the tarball. The chart's sub-charts and its images are pinned by the chart version; only the collector image is pinned by digest here.

To move to a newer chart: `ADDONS_UPDATE=1 ./scripts/addons-check.sh platform/observability` refreshes the lock file; read the chart's upgrade notes first (CRD changes need a server-side apply, which the Application already uses).

## Layout

| Directory | Kind | Purpose |
| --- | --- | --- |
| [`kube-prometheus-stack`](kube-prometheus-stack) | wrapper chart | The Prometheus Operator and its CRDs, Prometheus, Grafana and kube-state-metrics. `values-persistent.yaml` is an optional overlay, off by default |
| [`secrets`](secrets) | local chart | In-cluster generation of the Grafana admin credentials (ordinary RBAC objects and a Sync hook Job), as in the data layer |
| [`otel-collector`](otel-collector) | local chart | The OpenTelemetry Collector as a Deployment, with its Service and a ServiceMonitor |
| [`monitors`](monitors) | local chart | ServiceMonitors for the four sample services, a PodMonitor for PostgreSQL and a ServiceMonitor for RabbitMQ |
| [`dashboards`](dashboards) | local chart | The Grafana dashboards: one JSON file per dashboard in `files/`, one labelled ConfigMap each. `confirmed-upstream.txt` lists the metric names confirmed against upstream documentation |
| [`loki`](loki) | wrapper chart | Loki in single-binary mode on an `emptyDir`, 48 hours of retention. `values-persistent.yaml` is an optional overlay, off by default |
| [`alloy`](alloy) | wrapper chart | Grafana Alloy as a single-replica Deployment that tails pod logs through the Kubernetes API and pushes them to Loki |
| [`tempo`](tempo) | wrapper chart | Tempo in single-binary mode on an `emptyDir`, 24 hours of retention, OTLP receivers only. `values-persistent.yaml` is an optional overlay, off by default |

Argo CD deploys them as eight ApplicationSets (`observability-secrets`, `-stack`, `-tempo`, `-collector`, `-monitors`, `-dashboards`, `-loki`, `-alloy`, waves 10 to 16) in the `platform-observability` AppProject. The monitors chart and the collector's ServiceMonitor skip the dry run while the operator's CRDs are missing, and the Applications retry with backoff, so the order inside a first sync heals itself.

## Sizing and storage

The target is a cluster of a couple of small Spot nodes next to the data layer and the services, so everything is small and nothing is persistent.

| Pod | Requests | Limits |
| --- | --- | --- |
| Prometheus Operator | 25m / 64Mi | 200m / 128Mi |
| Prometheus (and its config reloader) | 160m / 536Mi | 800m / 1Gi + 48Mi |
| Grafana (with its dashboard and data source sidecars) | 70m / 224Mi | 500m / 640Mi |
| kube-state-metrics | 10m / 48Mi | 100m / 128Mi |
| OpenTelemetry Collector | 25m / 96Mi | 250m / 256Mi |
| Loki | 100m / 256Mi | 500m / 512Mi |
| Alloy (and its config reloader) | 55m / 152Mi | 300m / 304Mi |
| Tempo | 50m / 128Mi | 300m / 384Mi |
| **Total** | **about 0.5 vCPU / 1.5 GiB** (495m / 1504Mi) | |

- **Retention is two days** (`retention: 2d`, with a 1 GB size limit so a mistake in label cardinality cannot fill the node's disk).
- **No persistent volumes in the default profile.** Prometheus and Grafana use `emptyDir`: metrics, and anything created in the Grafana UI, are lost when a pod is rescheduled or its node is replaced. That is acceptable for a reference platform on Spot nodes; dashboards and the data source are provisioned from Git, not from the UI.
- **Persistence is documented and off.** To keep the data, add [`values-persistent.yaml`](kube-prometheus-stack/values-persistent.yaml) after `values.yaml` in the `valueFiles` of `platform/argocd/apps/91-observability-stack.yaml`: a 5 GiB claim for Prometheus and a 1 GiB claim for Grafana on the cluster's default StorageClass. Those volumes are created outside Terraform and are not removed by `terraform destroy` (the same warning as the [data layer](../data/README.md#storage-and-volume-lifecycle)), and a ReadWriteOnce volume ties the pod to one zone. `make observability-check` renders this overlay too.
- **No priority class.** The services use `platform-apps`; metrics must never preempt them.
- **No Alertmanager** and no default rules or dashboards yet (nothing would receive an alert, and the chart's dashboards need the default rules).

## Access

There is no ingress and no load balancer. Use a port-forward:

```bash
kubectl --context <EKS_CONTEXT> -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80
kubectl --context <EKS_CONTEXT> -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

Grafana is then at <http://localhost:3000> and Prometheus at <http://localhost:9090>.

**The Grafana admin password is never committed, and the Job that creates it prints only the name of the Secret, never a value.** The `observability-secrets` Application creates the Secret `grafana-admin` (keys `admin-user` and `admin-password`) once, with a random password generated in the cluster, and never changes it afterwards. Grafana reads it with `admin.existingSecret`. Until the Secret exists the Grafana pod waits in `CreateContainerConfigError` and then starts by itself. To sign in, read it yourself:

```bash
kubectl --context <EKS_CONTEXT> -n observability get secret grafana-admin -o jsonpath='{.data.admin-user}' | base64 -d; echo
kubectl --context <EKS_CONTEXT> -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

To rotate it, delete the Secret, sync `observability-secrets` again and restart Grafana. (With `values-persistent.yaml` Grafana keeps the password in its own database after the first start, so change it there too.) This in-cluster generation is the interim mechanism described in [ADR-0014](../../docs/adr/0014-data-layer.md); external secrets management replaces it later with the same Secret name.

## Grafana and the dashboards

The Prometheus data source is a ConfigMap created by the chart and loaded by the Grafana sidecar; the Loki data source (`http://loki.observability.svc.cluster.local:3100`, `maxLines` 1000, with the derived field `trace_id` that links to Tempo) and the Tempo data source (`http://tempo.observability.svc.cluster.local:3200`, with the link back to Loki) are added to the same ConfigMap from the stack's `additionalDataSources`. The dashboards are ConfigMaps in the `observability` namespace labelled `grafana_dashboard: "1"`, which the same sidecar loads. The sidecar watches this namespace only (the chart's default is every namespace, which needs a cluster-wide role to read ConfigMaps). The chart's own dashboards are off, because they need the chart's default rules.

| Dashboard (uid) | Shows | Built from |
| --- | --- | --- |
| Sample services (`sre-services`) | Request rate, 5xx share and latency (p50, p95, p99) by service and by route, requests in flight, responses by status | `http_requests_total`, `http_request_duration_seconds`, `http_requests_in_flight` of the four services |
| Data layer (`sre-data-layer`) | PostgreSQL: connections, size, transactions, cache hit ratio, deadlocks, replication, volume use. RabbitMQ as the services see it: queue depth, consumed and published messages, dead letters, outbox lag. Database pool, query latency and cache results | `cnpg_*` metrics of CloudNativePG, `kubelet_volume_stats_*`, and the data layer series of the services (`db_*`, `cache_*`, `outbox_*`, `messages_*`, `consumer_queue_messages`, `amqp_connected`) |
| Logs (`sre-logs`) | Log lines per second, error lines per second, services and pods that logged, log volume and error lines by service, and the lines themselves, with namespace and service variables and a free-text search | Loki; the labels `namespace`, `pod`, `container`, `app`, `service` and `service_name`, and the `level` structured metadata. The Sample services and Data layer dashboards link to it |
| Cluster capacity (`sre-cluster-capacity`) | Nodes, allocatable and requested CPU and memory, usage by node and namespace, pods per node, top pods, restarts, pods that are not ready | the kubelet (cAdvisor) and kube-state-metrics |

Every dashboard uses a data source variable (`${datasource}`) and no fixed data source uid. **A dashboard may only use metric names that are confirmed:** in the code of the services, in the vendored CloudNativePG chart (its reference dashboard and default queries), in the vendored stack chart (its rules) or in `dashboards/confirmed-upstream.txt`, which records the one name confirmed against upstream documentation and where. `make observability-check` fails on any other name. **RabbitMQ broker metrics (queue depth, message rates inside the broker) are not in the data layer dashboard:** no file in the repository or in a vendored artefact names them, so they were left out. Add them once their names can be confirmed, for example from the RabbitMQ documentation recorded in `confirmed-upstream.txt`. To add a dashboard, put a JSON file named after its uid in `dashboards/files/`; the template makes the ConfigMap.

## What Prometheus scrapes

Prometheus selects every `ServiceMonitor`, `PodMonitor`, `Probe` and `PrometheusRule` in every namespace, not only those with this release's label.

| Target | Monitor | Notes |
| --- | --- | --- |
| Kubelet, cAdvisor, API server, CoreDNS | created by the stack chart | Authenticated with the Prometheus pod's own projected token; no long-lived token Secret |
| kube-state-metrics, Prometheus, the operator, Grafana | created by the stack chart | |
| `gateway`, `orders`, `payments`, `notifier` | `ServiceMonitor` per service in [`monitors`](monitors) | Selects `app.kubernetes.io/name=<service>` and `app.kubernetes.io/part-of=sre-sample` in `shop`, port `http`, path `/metrics`. The job label is the service name. The service chart's own optional ServiceMonitor stays off |
| PostgreSQL (CloudNativePG) | `PodMonitor` in [`monitors`](monitors) | Selects `cnpg.io/cluster=platform-pg` and `cnpg.io/podRole=instance` in `data`, port `metrics`. **A PodMonitor, not a ServiceMonitor:** the instance pods serve metrics on port 9187, but the `-rw`, `-ro` and `-r` Services do not expose it |
| RabbitMQ | `ServiceMonitor` in [`monitors`](monitors) | Selects `app.kubernetes.io/name=platform-mq` and `app.kubernetes.io/component=rabbitmq` in `data`, port `prometheus` (the `rabbitmq_prometheus` plugin, which the operator enables) |
| Loki | `ServiceMonitor` in [`monitors`](monitors) | The Service `loki`, port `http-metrics` (3100). The headless Service carries a label that skips it |
| Alloy | `ServiceMonitor` in [`monitors`](monitors) | The Service `alloy`, port `http-metrics` (12345) |
| Tempo | `ServiceMonitor` in [`monitors`](monitors) | The Service `tempo`, port `tempo-prom-metrics` (3200). The chart's own ServiceMonitor is off: it also lists a port that exists only with the query front end |
| OpenTelemetry Collector | `ServiceMonitor` in [`otel-collector`](otel-collector) | The collector's own metrics (8888) and the metrics it receives over OTLP (8889) |

Not scraped yet: Valkey (the chart has no exporter enabled), the CloudNativePG and RabbitMQ operators, and the nodes themselves (see below). The metric names that RabbitMQ and CloudNativePG expose are only partly confirmed offline (see the dashboards above).

## OpenTelemetry Collector

The plain Collector distribution, as a Deployment with one replica, image pinned by digest. It accepts OTLP over gRPC (4317) and HTTP (4318) at `otel-collector.observability.svc`, runs `memory_limiter` first and then `batch`, sends received metrics to a Prometheus exporter that Prometheus scrapes, and has a **traces pipeline** (`otlp` receiver, `memory_limiter`, `batch`, an `otlp/tempo` exporter) that sends traces to Tempo at `tempo.observability.svc.cluster.local:4317` over gRPC without TLS, because the traffic stays inside the cluster. The exporter has a small queue (100 batches) and retries for 60 seconds before it drops a batch. The `debug` exporter is still defined and no pipeline uses it. It exposes its own metrics on a second port and has a health endpoint for its probes.

**The services do not send OTLP yet.** They expose Prometheus metrics on `/metrics`, propagate `traceparent` and write the trace ID into their JSON logs, but none of them uses an OpenTelemetry SDK or reads an `OTEL_*` setting ([`apps/README.md`](../../apps/README.md) lists OpenTelemetry instrumentation as open), so no endpoint setting was added to `deploy/helm`. The collector and Tempo are ready for the day they do.

## Logs

Alloy discovers the pods of the `shop` and `data` namespaces and tails their logs through the Kubernetes API (`loki.source.kubernetes`), so it needs no `hostPath` and no node access, which the restricted level would refuse. It pushes them to Loki, a single binary with filesystem storage on an `emptyDir` (2 GiB limit), no tenant header, the TSDB index with schema v13 and **48 hours of retention**. Logs are lost when Loki's pod is rescheduled; [`loki/values-persistent.yaml`](loki/values-persistent.yaml) adds a 5 GiB claim (off by default, outliving `terraform destroy`), and production would use object storage.

The Loki labels are `namespace`, `pod`, `container`, `app` and `service` (the pod's `app.kubernetes.io/name`), plus `service_name`, which Loki derives (the container name for a pod without an app label, such as PostgreSQL). **The level is not a label:** the services write JSON lines (lower-case `level` from the Go and Python services, upper-case from payments), and Alloy stores it, in lower case, as structured metadata, so `| level="error"` works without adding streams. Plain-text lines have no level. `kube-system`, `argocd`, `cert-manager` and this namespace are not collected. The decision and its limits are in [ADR-0021](../../docs/adr/0021-logging-stack.md); the runbook has queries and troubleshooting.

## Traces

Tempo is a single binary with local storage on an `emptyDir` (1 GiB limit), no tenant header, **24 hours of retention**, OTLP over gRPC (4317) and HTTP (4318) as the only receivers and the query API on 3200, all behind the Service `tempo` and nowhere else. The metrics generator is off, so there is no service graph. Traces are lost when the pod is rescheduled; [`tempo/values-persistent.yaml`](tempo/values-persistent.yaml) is an optional overlay that adds a 5 GiB claim, off by default, with the same warning as Loki's. It runs under the restricted level with a read-only root filesystem and asks for 50m CPU and 128Mi memory. The Argo CD application is [`97-observability-tempo.yaml`](../argocd/apps/97-observability-tempo.yaml) at wave 11, so it is created before the collector (wave 12).

**The Tempo chart is deprecated upstream.** It is pinned, vendored and limited to the cluster network; the reason it was chosen over `tempo-distributed` and the way out are in [ADR-0022](../../docs/adr/0022-tracing-stack.md).

Grafana has a data source `Tempo` (uid `tempo`) and the Loki data source has a derived field `trace_id`, matching `"trace_id":"<32 hex digits>"`, the format the services write, that links a log line to its trace; from a trace, a link runs a Loki query for the lines with the same ID, five minutes either side of the span. Both are provisioned in [`kube-prometheus-stack/values.yaml`](kube-prometheus-stack/values.yaml) and checked by `make observability-check`. How to find a trace and send a test trace is in the [runbook](../../docs/runbooks/observability.md#traces).

## Pod Security

The `observability` namespace carries Pod Security **restricted**, enforced, and also on warn and audit. Every pod the charts render meets it, and `make observability-check` fails if one stops meeting it (no host namespaces or ports, no `hostPath`, no privileged container, privilege escalation off, all capabilities dropped, non-root, seccomp). Prometheus's own pod is created by the operator at run time and cannot be rendered offline; its pod-level settings are checked, the container settings the operator adds are not (see the limits below).

**node-exporter is disabled.** It needs `hostNetwork`, `hostPID` and `hostPath` volumes, which `restricted` does not allow, and it would run on every node. Node CPU and memory still come from the kubelet and cAdvisor, but node-level disk, network and filesystem metrics are missing. If they are wanted, deploy node-exporter on its own into a separate namespace that is allowed to be privileged, with its own AppProject, rather than loosening this one.

The admission webhooks of the operator are off too (they need a certificate and a hook Job, and only validate rule files, which CI checks instead), and with them the operator's TLS listener.

## Teardown

Removing the label (re-run the bootstrap script without `--enable-observability`) makes Argo CD delete the Applications. The Prometheus Operator leaves nothing behind that needs clearing in this configuration: its only finalizer, `monitoring.coreos.com/status-cleanup`, is set on `Prometheus` objects and only when the operator's `StatusForConfigurationResources` feature gate is on, which it is not (checked against the operator source at the pinned version; see [ADR-0020](../../docs/adr/0020-metrics-stack.md)). The one thing that survives is the claims of the persistent values (the stack's, or Loki's), if they were used: they outlive the Application and `terraform destroy`. `scripts/teardown-prep.sh` waits for the pods in the `observability` namespace and deletes its claims ([data layer teardown](../../docs/runbooks/data-layer.md#teardown)).

## Checks

```bash
make observability-check
```

Runs `helm lint --strict`, `helm template` and `kubeconform` for every chart and cloud (the stack also with the persistent values), with custom resources validated against CRD schemas from the pinned `datreeio/CRDs-catalog` commit; checks the operator's CRDs (the ones the platform relies on exist, one storage version and a schema each, and the Application syncs with `ServerSideApply=true`, because the large CRDs cannot be applied client-side); checks that `Chart.yaml`, `Chart.lock` and the downloaded tarball agree; runs the contract checks in `scripts/chart-contract-check.py` (restricted Pod Security, no persistent storage, Alertmanager, Ingress or load balancer in the default profile, Grafana reading its admin account from the Secret and no password rendered, the collector pinned by digest, no hook-only chart, and everything rendered allowed by the `platform-observability` AppProject); the Loki configuration (single tenant, TSDB v13, filesystem, retention on) the Alloy configuration (API source only, the `shop` and `data` namespaces, no log field as a label, no access to Secrets) and the Tempo configuration (single tenant, local storage, at most 72 hours of retention, OTLP receivers only, no metrics generator); checks the Grafana data sources (unique uids, the links between Loki and Tempo by uid, and that the derived field's regular expression finds the trace ID in a sample line in the format of each service and in no other); checks the dashboards (valid JSON, unique uid and title, the data source variable, the sidecar label on every ConfigMap, ConfigMaps that hold the files, only confirmed metric names, and for Loki panels only the log stream labels and the level, and no selector that can match the empty value); when Docker is running, validates the collector configuration with `validate` of the pinned image, the Loki configuration with `-verify-config`, the Alloy configuration with `alloy validate`, runs the dashboards' LogQL against a Loki container with sample lines ([`scripts/logql-check.py`](../../scripts/logql-check.py)), and starts Tempo and the collector from the rendered configuration and finds a trace sent to the collector in Tempo ([`scripts/trace-check.py`](../../scripts/trace-check.py)); and runs `yamllint` and `shellcheck`.

## What is and is not verified

The charts are rendered, linted, schema-checked and contract-checked offline. The collector, Loki, Alloy and Tempo were also run locally from their pinned images, the Logs dashboard's LogQL was run against Loki with sample lines (see [ADR-0021](../../docs/adr/0021-logging-stack.md)), and a trace sent to a collector with the chart's traces pipeline was found in Tempo, which ran with a read-only root filesystem (see [ADR-0022](../../docs/adr/0022-tracing-stack.md)).

The stack has also run on a real EKS cluster, in two sessions, written up with screenshots in [Observability on a real cluster](../../docs/observability-evidence.md): every Application Synced and Healthy, every target in the table above up, the Cluster capacity, Sample services, Data layer and Logs dashboards showing data, and Loki and Alloy running under the restricted level without a volume. Tempo, the Tempo data source and the links between logs and traces were added after those sessions and have not run on a cluster, and no service sends traces yet. Not yet seen on a cluster: what Alloy does with lines written while it or Loki restarts. The teardown (`scripts/teardown-prep.sh`, then `scripts/teardown-argocd.sh`, then `terraform destroy`) was run there and left nothing behind. The CRD schemas used for the custom resources come from a pinned catalog commit that may lag the operator version.
