# ADR-0021: Logging stack

- Status: Accepted
- Date: 2026-10-31

## Context

[ADR-0020](0020-metrics-stack.md) put metrics and dashboards on the cluster and left logs and traces out. The four sample services already write one line per request to standard output, as JSON, with a request ID and, where a trace is active, its ID. Nothing collects those lines, so after a pod is rescheduled or deleted there is nothing to read, and a request cannot be followed from a dashboard panel to the lines that explain it.

The constraints are those of the metrics stack. The cluster is a couple of small Spot nodes that also run Argo CD, the add-ons, the data layer, the services and the metrics stack; the 3-node development cluster is already about 59 percent requested on CPU. Everything is deployed by Argo CD from this repository behind the cluster label `platform.example/observability`, which is off by default. The `observability` namespace enforces the `restricted` Pod Security level, no credential is committed, nothing is exposed outside the cluster, and what could not be run has to be said.

## Decision

Storage: Loki

- **Loki, from the Grafana chart, in single-binary mode**, as a vendored wrapper chart under `platform/observability/loki` (chart 7.5.0, Loki 3.6.11, pinned the way the other charts are: version in `Chart.yaml`, digest in `Chart.lock`, tarball left out of Git). One replica, one process, no gateway, no caches, no canary, no object store. The Service `loki` serves HTTP on port 3100 inside the cluster and nowhere else.
- **Filesystem storage on an `emptyDir`** with a 2 GiB size limit. A claim would tie the pod to one zone on a multi-zone Spot cluster and leave a volume that outlives `terraform destroy`, as the metrics stack found. The size limit makes a runaway log producer evict Loki instead of filling a node's disk. `values-persistent.yaml` is an optional overlay that adds a 5 GiB claim; it is off by default, rendered by the checks, and says in its first lines that production would use object storage.
- **Single tenant.** `auth_enabled: false`, so no tenant header. Only the collector in the same namespace writes and only Grafana reads, and access from outside the cluster is a port-forward.
- **TSDB index, schema v13**, the current one, from a date in the past so every line is covered. A later schema change needs a new entry with a later date, never an edit of this one; the contract check looks at the newest entry.
- **Forty-eight hours of retention**, through the compactor (retention enabled, a two-hour delete delay) and `retention_period: 48h`, and lines older than that are rejected on the way in. Two days matches the metrics retention, is enough to look at yesterday's incident, and keeps the data far below the 2 GiB limit for a few small services. It is a development setting, not a recommendation.
- **Limits that fit the size of the cluster:** about 4 MB/s ingestion (burst 8), 2 MB/s per stream (burst 6) so one crash-looping pod cannot use the budget of the others, lines up to 256 KB, 5,000 streams, 15 labels per stream, 2,000 entries and 500 series per query, a 48-hour query window. Usage reporting is off.
- **Requests of about 100m CPU and 256Mi memory** (limits 500m and 512Mi), no priority class: as with the metrics stack, when a node is short of room the logging stack goes before the services.

Collection: Alloy

- **Grafana Alloy** (chart 1.15.0, v1.21.3) in the same namespace, as a single-replica Deployment. It discovers the pods of two namespaces and tails their logs through the Kubernetes API with `loki.source.kubernetes`. It mounts nothing from the node: no `hostPath`, no `/var/log`, no host network. That is the reason for the API source: a node agent that reads log files needs `hostPath`, which the `restricted` level forbids, and the namespace keeps that level.
- **A Deployment, not a DaemonSet.** With the API as the source there is no per-node file to read, and a DaemonSet would make every pod tail every log. More than one replica would need Alloy's clustering to split the targets; see the production path below.
- **Trimmed RBAC.** The chart's default role also reads Secrets and ConfigMaps. The role here can only get, list and watch pods, pod logs and namespaces. It is a ClusterRole because the namespaces it reads come and go and the Application cannot create roles in them; the contract check fails if the rendered role can read Secrets or ConfigMaps. The chart's CRD for `PodLogs` is off, and so is usage reporting.
- **Restricted settings:** non-root, no privilege escalation, all capabilities dropped, seccomp `RuntimeDefault`, read-only root filesystem with an `emptyDir` for Alloy's working data. The configuration-reload sidecar of the chart is kept, with small requests. Alloy asks for 50m CPU and 128Mi memory (limits 250m and 256Mi).
- **Namespaces collected: `shop` and `data`.** The sample services and the data layer (PostgreSQL, RabbitMQ, Valkey). The check fails if the list is anything else.

Labels

- **Five labels, all low in cardinality except `pod`:** `namespace`, `pod`, `container`, `app` (the pod's `app.kubernetes.io/name`, or the older `app`) and `service` (the same value, the name the services' metrics use). Loki adds `service_name` itself, from `service` and, for a pod without one, from the container name, so PostgreSQL's log stream is `service_name="postgres"`. The dashboards group and filter by `service_name` for that reason.
- **No field of a log line becomes a label.** What the services log was read from their code: the gateway and notifier (Go `slog`) and orders (Python) write one JSON object per line with `timestamp`, `level` in lower case, `message` and `service`; payments (Spring Boot, logstash format) writes JSON with `@timestamp`, `message` and `level` in upper case. Alloy reads `level` from the JSON, lowers it to one spelling and stores it as **structured metadata**, so it can be filtered on (`| level="error"`) without adding streams. Lines that are not JSON, such as PostgreSQL's, have no level. The checks fail if the Alloy configuration uses `stage.labels`, a file source or a namespace other than the two.
- **Request IDs and trace IDs stay in the line.** They would be the worst possible labels. Finding a request is `|= "<id>"`.

Grafana and monitors

- **A Loki data source**, provisioned from the stack's values the way the Prometheus one is (the chart's `additionalDataSources`, loaded by the same sidecar), with `maxLines: 1000` and no derived fields: trace links waited for traces ([ADR-0022](0022-tracing-stack.md) adds the Tempo data source and the derived field).
- **A fourth dashboard, Logs** (`sre-logs`): lines per second, error lines per second, the services and pods that logged, log volume and error lines by service, and the lines themselves, with namespace and service variables and a free-text search (a case-insensitive regular expression). The Sample services and Data layer dashboards link to it, keeping the time range and the variables of the same name.
- **ServiceMonitors for Loki and Alloy** in `platform/observability/monitors`, like the other monitors, so both appear as targets.
- **Two more ApplicationSets** under the same label: `observability-loki` (wave 15) before `observability-alloy` (wave 16), so Loki exists when Alloy starts to push. The AppProject `platform-observability` gained one namespaced kind, `StatefulSet`, because Loki is one; Alloy's ClusterRole and binding fit the kinds it already allowed.

Checks

- **The contract checks** (`scripts/chart-contract-check.py`) cover the rendered Loki configuration (single tenant, TSDB v13, filesystem, retention on and at most a week, the limits set) and the Alloy configuration (above), and the existing ones: restricted Pod Security, no claim or hostPath in the default profile, the AppProject fit. The dashboards check accepts Loki panels through a `loki` data source variable and only the stream labels and `level`; it also rejects a selector that can match the empty value, which Loki refuses, by looking at the variable's "All" value.
- **The images validate the configuration:** `loki -verify-config` and `alloy validate` run in `scripts/observability-check.sh`, and `scripts/logql-check.py` starts Loki with the rendered configuration, pushes sample lines and runs every Loki query of every dashboard with "All" selected and with concrete values.

## Consequences

- A cluster labelled for observability also gets Loki, Alloy, a data source, a fourth dashboard and two monitors. Without the label nothing changes.
- **Capacity.** The two pods add about 0.155 vCPU (Alloy's reload sidecar included) and about 0.4 GiB of memory to the requests of [ADR-0020](0020-metrics-stack.md). On the two default nodes that moves the estimated CPU requests from about 78 to about 81 percent of allocatable, and on the three-node development cluster it is under 3 percentage points. These are arithmetic on rendered requests and estimated allocatable, not measurements.
- **Logs are lost when Loki's pod is rescheduled,** by design, and so is anything not yet flushed. On Spot nodes that will happen. A log line that matters has to be read before then; the 48-hour window assumes the pod survives that long.
- **Single replica.** Loki and Alloy each run once. While Loki restarts, Alloy's pushes fail and retry; whether lines written meanwhile are replayed or lost was not verified, and Alloy's own working data is also on an `emptyDir`.
- **The API server serves every log stream** Alloy reads. For a few small services that is negligible. For many pods or high volume it is not, and it is the first thing that makes a node agent worth its privileges.
- **`pod` is a label,** so every rescheduled pod creates new streams. At this size it is fine; a deployment with fast pod churn would drop it from the index.
- **Not collected: `kube-system`, `argocd`, `cert-manager`, `observability` itself** and everything else. A failure in Argo CD or the add-ons is not visible in Loki. Adding a namespace is one line in the Alloy configuration and the check that pins the list.
- The level metadata exists only for JSON lines. Loki also derives its own `detected_level` from the text of every line; the dashboards use `level`, which is the services' own word for it.
- The images are pinned by tag through the chart versions, not by digest, like the metrics stack's; only the collector image is pinned by digest.

## Production path

None of this is meant to be left as it is for a production cluster:

- **Object storage** (S3 or GCS) for chunks and the index, with the bucket's own lifecycle rule for retention, a role the Loki pod can assume (IRSA or Workload Identity) and a longer retention agreed with whoever uses the logs. That frees the pod from a local disk, and with it the single-replica limit.
- **Scaling Loki** beyond one process means leaving the single-binary mode (the chart's simple scalable or distributed mode), which needs the object store above, replicated ingesters and the caches that are switched off here.
- **Scaling the collector.** One Alloy tailing through the API stops being enough at some volume. The options are clustering (several replicas that split the targets) or, in a namespace that is allowed to be privileged and has its own AppProject, a DaemonSet reading files from the node, as node-exporter would be added.
- **Authentication and tenants** once more than one team or cluster writes, and TLS between the parts, with the rest of the security phase.

## What this does not cover

- **Only part of it is recorded on a cluster.** See below, and [the screenshots](../observability-evidence.md).
- **No trace correlation:** no derived fields, no link from a log line to a trace, and the services still do not send OpenTelemetry data ([ADR-0020](0020-metrics-stack.md)). Request IDs and trace IDs are in the lines, searchable with a text filter.
- **No log-based alerts,** no recording rules from logs, no ruler. (Alertmanager came with [ADR-0023](0023-slos-and-alerting.md), for alerts on metrics.)
- **No long-term or cross-cluster storage, no replication, no backup.**
- **Only the `shop` and `data` namespaces,** and only pod logs: no Kubernetes events, no audit logs, no node logs.
- **No parsing beyond the level.** Fields such as `route` or `status` stay in the line. Querying them is `| json | status >= 500`, which parses at query time.
- **No authentication in front of Loki.** The namespace has network policies (default deny with explicit allows, on EKS only), so only Alloy, Grafana and Prometheus reach it.

## What has been exercised

Checked on a laptop: both charts with `helm lint --strict`, `helm template` and `kubeconform` for both clouds (and Loki with the persistent values); the monitors against the pinned CRD catalog; chart pinning against `Chart.lock` and the tarballs; restricted Pod Security, no claim, volume claim template or hostPath in the default profile and a claim only with the persistent values; the AppProject fit; the Loki and Alloy configuration contracts, each shown to fail when its rule is broken; the dashboards, including the label, empty-selector and variable rules for Loki queries.

Run locally with the images the charts deploy, with no cluster:

- `loki -verify-config` on the rendered configuration. It found a key that only the enterprise edition knows, which was removed.
- `alloy validate` on the rendered configuration. It accepted a `stage.match` selector with a line filter that Alloy then refused when it ran, so the final version uses no `stage.match`; running the pipeline was what found it.
- Loki and Alloy together on sample lines in the three shapes the services write (JSON with a lower-case level, JSON with an upper-case level, plain text). The level came out as structured metadata in lower case on the JSON lines and was absent on plain text, and the labels API listed no `level`.
- Every Loki query of the dashboards against Loki with sample lines, with "All" and with concrete values: all parse, the counts come out as expected, error lines are found for both spellings of the level, the pod without an app label is grouped under its container name, and a selector such as `{namespace=~".*"}` is refused with HTTP 400 (which is why "All" for the namespace variable is `.+`). Loki returns a separate stream per value of the structured metadata, so a count of streams is not a count of pods.

Observed on a real EKS cluster ([evidence](../observability-evidence.md)): Loki and Alloy started under `restricted` with no claim (`emptyDir`) and both targets were up in Prometheus; logs arrived with the labels `namespace`, `pod`, `container`, `app` and `service`, and `level` was available as structured metadata; Grafana loaded the Loki data source, and the Logs dashboard worked, including the search box and an error view of the PostgreSQL pod; the Argo CD sync of waves 15 and 16 finished Healthy. Alloy's source also adds the labels `job` and `instance`. The cluster was temporary and has been destroyed: the teardown ran with Loki and Alloy deployed (`scripts/teardown-prep.sh`, then `scripts/teardown-argocd.sh`, then `terraform destroy`) and the AWS checks came back empty.

Not covered by that run:

- what Alloy does with lines written while it or Loki restarts;
- the capacity estimate, which was not compared with the running pods in any recorded way.

## Alternatives considered

- **Promtail.** The earlier Grafana agent, which Grafana has deprecated in favour of Alloy, and it reads files from the node, so it needs `hostPath`.
- **Alloy as a DaemonSet reading `/var/log/pods`.** The usual production layout and cheaper on the API server, but it needs `hostPath` volumes, which this namespace does not allow. It becomes the right answer in a namespace that is allowed it.
- **The OpenTelemetry Collector with the `filelog` receiver.** The collector is already there and would unify the pipeline, but its file-based receiver has the same `hostPath` need.
- **Loki in simple scalable mode with MinIO.** Three process types, caches and an object store for a few megabytes of logs a day. The single binary is the documented choice for this size.
- **A persistent volume by default.** Logs of the last two days are worth less than a clean teardown and no zone-bound pod.
- **`level` as a label.** It would make queries by level cheap, and it would multiply the streams of every pod by the number of levels. Structured metadata filters just as well at this size.
- **`stage.labels` for route and status.** The same objection, with unbounded values for the route.
- **A hosted log service.** Out of scope for a platform that runs its own components, and it would need a credential.
