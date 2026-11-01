# ADR-0022: Tracing stack

- Status: Accepted
- Date: 2026-11-01

## Context

[ADR-0020](0020-metrics-stack.md) put an OpenTelemetry Collector on the cluster that accepted traces and dropped them, because no trace backend existed. [ADR-0021](0021-logging-stack.md) put the logs of the services in Loki. The services already carry a trace through their own code: each one reads the W3C `traceparent` header of a request, keeps the trace ID, sends a new `traceparent` on its calls to the other services and writes the trace ID into every request log line as `"trace_id":"<32 hex digits>"` ([`apps/README.md`](../../apps/README.md)). The gateway, the orders service and the notifier now also use an OpenTelemetry SDK and send their spans to the collector (see [Services that send traces](#services-that-send-traces)); payments does not yet, so it sends no span.

This decision adds the place the spans go, and the links between that place and the logs. The two Go services were instrumented afterwards, in a separate change. The constraints are those of the other two stacks: a couple of small Spot nodes shared with everything else, Argo CD deploying from this repository behind the cluster label `platform.example/observability` (off by default), the `restricted` Pod Security level in the `observability` namespace, nothing exposed outside the cluster, no credential in Git, and what could not be run has to be said.

## Decision

Storage: Tempo

- **Tempo, from the Grafana `tempo` chart, in single-binary mode**, as a vendored wrapper chart under `platform/observability/tempo` (chart 1.24.4, Tempo 2.9.0). Version in `Chart.yaml`, digest in `Chart.lock`, tarball left out of Git, as for the other charts. One replica, one process. The Service `tempo` takes OTLP on 4317 (gRPC) and 4318 (HTTP) and serves the query API on 3200, all inside the cluster.
- **The Tempo chart is deprecated upstream.** Its own `Chart.yaml` says `deprecated: true`, and Grafana's supported route is the `tempo-distributed` chart. It was still chosen because of the footprint. `tempo-distributed` runs the distributor, ingester, querier, query frontend and compactor as separate workloads, usually with a gateway and caches, and it is built for object storage; for a development cluster with a few small services that is many pods and a bucket to hold a few megabytes of traces. The single binary runs as one pod with requests of 50m CPU and 128Mi memory. The pod used about 21 MiB when it was started with this configuration for a short test, which is a sample and not a measurement of a loaded Tempo. The price is that this chart gets no further fixes, and the exposure is limited by the pinning below, the in-cluster-only Service and the short retention.
- **Pinned and vendored.** The chart version and the lock digest are in Git and `scripts/observability-check.sh` builds the dependency from the lock the way it does for Loki and Alloy. The image is the tag the chart sets (2.9.0), not a digest, like Loki's.
- **Migration path.** Replace the wrapper chart with one on `tempo-distributed` (or on whatever Grafana then supports for a single process), with object storage (an S3 or GCS bucket with its own lifecycle rule and a role the pods can assume) and the same two public names: the Service `tempo` for OTLP on 4317 and the query address in the Grafana data source. If the distributed chart names them differently, the two places to change are the `tempo.endpoint` value of the collector chart and the Tempo data source URL in the stack values. No data has to move: traces live on an `emptyDir`. The contract check on the Tempo configuration is the part that would be rewritten.
- **Local storage on an `emptyDir`** with a 1 GiB size limit, and **24 hours of retention** (`block_retention: 24h`, enforced by the compactor). A claim would tie the pod to one zone on a multi-zone Spot cluster and leave a volume that outlives `terraform destroy`, as the metrics and logging stacks found. **Traces are lost when the pod restarts or is rescheduled,** and so is anything that had not been flushed to a block yet; on Spot nodes that will happen. `values-persistent.yaml` is an optional overlay that adds a 5 GiB claim; it is off by default, rendered by the checks, and says in its first lines that production would use object storage.
- **One tenant, OTLP only.** No tenant header. The Jaeger and OpenCensus receivers of the chart's default configuration are not enabled, so the distributor receives only OTLP over gRPC and HTTP. The chart's template for the Service still lists a few ports for the receivers that are off (Zipkin, the legacy OTLP and OpenCensus ports); nothing listens on them. The metrics generator is off, so there are no service graphs and no span metrics, and usage reporting to the vendor is off.
- **Restricted settings:** non-root (10001), no privilege escalation, all capabilities dropped, seccomp `RuntimeDefault`, read-only root filesystem with the `emptyDir` as the only writable path, and no service account token (Tempo does not call the Kubernetes API). The chart starts Tempo with a 1 GiB memory ballast by default, which is more than the container's memory limit, so it is set to zero. Requests of 50m CPU and 128Mi memory, limits of 300m and 384Mi, no priority class: when a node is short of room the tracing stack goes before the services.

The path

- **service, then Collector, then Tempo.** The services send OTLP to `otel-collector.observability.svc` (4317 or 4318); the gateway, orders and the notifier use gRPC on 4317. The collector's traces pipeline is `otlp` receiver, `memory_limiter`, `batch`, and an `otlp/tempo` exporter to `tempo.observability.svc.cluster.local:4317` over gRPC without TLS, because the traffic does not leave the cluster and nothing in this profile issues certificates for it. The exporter has a small queue (100 batches) and retries for 60 seconds, so a Tempo that is away for a short time loses nothing and one that is away for longer loses the traces of that time, not the collector's memory. The metrics pipeline is unchanged.
- **The `debug` exporter** that used to be the traces exporter is still defined in the configuration and no pipeline uses it. Add it to the traces pipeline to see in the collector's log that traces arrive.

Correlation with logs

- **From a log line to a trace.** The Loki data source has a derived field named `trace_id` with the expression `"trace_id":"([0-9a-f]{32})"` and a link to the Tempo data source by its uid. The expression is anchored on what the services write: the key in quotes, a colon with no space, and 32 lower-case hex digits in quotes. That is the format of the Go services (gateway and notifier, `slog`), of orders (Python, compact JSON) and of payments (Java), read from their code and from the lines the Logs dashboard showed on the cluster. It does not match the `traceparent` field of the notifier's event lines, a short or upper-case ID, or a line with spaces around the colon.
- **From a trace to its log lines.** The Tempo data source has a trace-to-logs link to Loki with this custom query, in which the text between the backticks is a raw LogQL string that Grafana fills with the trace ID:

  ```text
  {namespace=~".+"} |= `${__trace.traceId}`
  ```

  The link has a time shift of five minutes before the span starts and five after it ends. The lines are found by the text of the ID and not by a label, because the trace ID must not be a label: it would make a new stream per request ([ADR-0021](0021-logging-stack.md)). The selector uses `.+` because Loki refuses a selector that can match the empty value.
- **Not turned on:** the service graph, the node graph and trace-to-metrics. They need the metrics generator of Tempo, which is off.

Grafana, monitors and Argo CD

- **A Tempo data source**, provisioned from the stack's values like the Prometheus and Loki ones (the chart's `additionalDataSources`, loaded by the same sidecar) with the fixed uid `tempo`, pointing at the query port 3200 of the Service.
- **A ServiceMonitor for Tempo** in `platform/observability/monitors` (`tracing.yaml`), so Tempo is a target. It selects the Service by its labels and the port `tempo-prom-metrics`, which were read from the rendered chart. The chart's own ServiceMonitor is off, because it also lists a port that exists only when the chart's query component is on.
- **One more ApplicationSet**, `observability-tempo`, at **wave 11**: with the stack and before the collector (wave 12), so Tempo is created before the collector that exports to it. Tempo needs nothing from the stack, so it does not wait for it. A wave only orders how the ApplicationSets are created ([platform/argocd/README.md](../../platform/argocd/README.md)); Argo CD does not wait for one Application before it starts another, so the collector can be up before Tempo is ready. The exporter's queue and retry cover that. The AppProject `platform-observability` needed no change: the kinds Tempo renders (ConfigMap, Service, ServiceAccount, StatefulSet) were already allowed.

Checks

- **The contract checks** (`scripts/chart-contract-check.py`) cover the rendered Tempo configuration (single tenant, local storage, retention in hours and at most 72, only the OTLP receiver with both protocols, no metrics generator, no usage report) and the existing ones for the Tempo render, with the default and the persistent values: restricted Pod Security, no claim in the default profile and a claim only with the persistent values, the AppProject fit. The sync-wave check requires Tempo before the collector.
- **The data source check** (`grafana-datasources`) reads the data sources the stack renders: unique fixed uids for Prometheus, Loki and Tempo; the derived field links to the Tempo uid; its expression finds the trace ID in a sample line in the format of each service and matches none of the lines that look similar but are not that format; the trace-to-logs link points at the Loki uid with a negative and a positive time shift and a query that uses the trace ID; and no service graph, node graph or trace-to-metrics is on.
- **A live test** in `scripts/observability-check.sh` (`scripts/trace-check.py`) starts the Tempo image with the rendered configuration, a read-only root filesystem, no capabilities and a non-root user, and the collector image with the rendered configuration (only the Tempo address changed to the test container), on a Docker network. It sends one trace of two spans to the collector as OTLP over HTTP and fetches it from Tempo by its ID.

## Consequences

- A cluster labelled for observability also gets Tempo, a Tempo data source, a link from log lines to traces, and one monitor. Without the label nothing changes.
- **Capacity.** Tempo adds 50m CPU and 128Mi memory to the requests. The stack's requests total about 0.495 vCPU and 1.47 GiB, from the requests of the charts as rendered. On the two default nodes that is about one percentage point of CPU on top of [ADR-0021](0021-logging-stack.md). These are arithmetic on rendered requests, not measurements.
- **Traces are lost when Tempo's pod is rescheduled,** by design. A trace that matters has to be read before then; the 24-hour window assumes the pod survives that long.
- **Single replica.** Tempo runs once. While it restarts, the collector's exporter queues and retries; whether traces sent meanwhile are replayed or lost was not observed.
- **The collector sends to Tempo without TLS or authentication,** and Tempo accepts any client in the cluster. The namespace has no network policy ([ADR-0020](0020-metrics-stack.md)).
- **A deprecated chart is in the tree.** See above for why and for the way out.
- The trace ID in a log line links to a trace only if the trace exists in Tempo, and no trace does until a service sends spans.

## Production path

None of this is meant to be left as it is for a production cluster:

- **Object storage** (S3 or GCS) for the blocks, with the bucket's own lifecycle rule for retention, a role the pods can assume (IRSA or Workload Identity) and a retention agreed with whoever reads the traces, on the supported chart (see the migration path above).
- **Sampling** decided on purpose, in the SDKs or in the collector, once real traffic exists. Nothing samples now because nothing sends.
- **TLS and authentication** between the collector and Tempo, and network policies on the namespace.
- **The metrics generator**, with a remote-write endpoint, when service graphs or span metrics are wanted; the data source then turns the service map on.

## Services that send traces

The gateway and the notifier create spans with the OpenTelemetry Go SDK, and orders with the Python SDK, and export them to the collector over OTLP/gRPC.

- **Off unless an endpoint is set.** The services read the standard `OTEL_*` variables; without `OTEL_EXPORTER_OTLP_ENDPOINT` no exporter is created, so local runs, tests and CI need no collector. `deploy/helm/values/gateway.yaml`, `orders.yaml` and `notifier.yaml` set the endpoint to `http://otel-collector.observability.svc.cluster.local:4317` (the Service of the collector chart, in the `observability` namespace), a parent-based sampler with ratio 1.0 and `service.namespace=shop`. The `http://` scheme means a plain connection, which is acceptable inside the cluster only.
- **A missing collector costs spans, not requests.** Export runs in the background with a bounded queue, startup does not wait for a connection, and shutdown waits at most 5 seconds. A cluster without the observability stack gets the endpoint all the same, and the services log one warning a minute.
- **Spans.** A server span for each request except the probes and `/metrics`, named by method and route template; a client span for each call from the gateway to orders and payments; in orders a client span for the call to payments, a span for each repository operation and a producer span for each event the outbox relay publishes, with the trace context written into the message headers as a standard `traceparent`; in the notifier a consumer span for each RabbitMQ message, a child of the `traceparent` in the message headers, and spans for recording the notification and for sending a message to the retry or dead-letter queue. The list is in [`apps/README.md`](../../apps/README.md#tracing-gateway-orders-and-notifier).
- **The trace through the outbox.** Orders publishes events later, from a background relay, so the publish span cannot be a child of the request span by context alone: the outbox row keeps the `traceparent` of the span that was active when the order changed, and the relay uses it as the parent of the publish span. A trace from the gateway then runs gateway, orders, the publish, and the notifier's consumer span.
- **Database spans have no SQL.** The asyncpg instrumentation always records the statement text, so orders writes its own spans with only the fixed operation name. Valkey has no spans.
- **Logs.** `trace_id` in the request log line is the trace ID of the server span, in the same format as before, so the derived field and the Tempo links keep working. When tracing is off it is the ID from the `traceparent` header, as it was.
- **Not recorded:** message bodies, message headers and customer data are not attributes. The standard HTTP attributes include the path and query.

## What this does not cover

- **Payments sends no traces.** The gateway, orders and the notifier use an OpenTelemetry SDK; payments (Java) only passes the `traceparent` header on, so a trace has no spans for it until it is instrumented. Orders' call to payments has a client span and carries its `traceparent`; payments does not continue it.
- **No traces in Grafana.** Nothing was seen in Grafana: the data source, the derived field and the trace-to-logs link have been checked as configuration and not clicked.
- **No sampling, no tail-based processing, no span metrics, no service graph.**
- **No trace-based alerts**, no exemplars from metrics to traces, no ingress and no authentication in front of Tempo.
- **No Jaeger, Zipkin or OpenCensus clients.** Only OTLP is received.

## What has been exercised

Checked on a laptop: the Tempo chart with `helm lint --strict`, `helm template` and `kubeconform` for both clouds and the persistent values; chart pinning against `Chart.lock` and the tarball; restricted Pod Security, no claim in the default profile and a claim with the persistent values; the AppProject fit; the Tempo configuration contract and the data source contract, each shown to fail when its rule is broken (a loose expression, a wrong uid, a missing time shift, a service map, a Jaeger receiver, object storage and a long retention); the sync-wave order; the collector and monitors charts.

Run locally with the images the charts deploy, with no cluster: the Tempo image started with the rendered configuration and the restricted container settings, the collector image started with the rendered traces pipeline, and one trace sent to the collector and found in Tempo by its ID, with both of its spans.

Not exercised, because it needs a cluster or a service that sends traces:

- Tempo starting under `restricted` in the namespace, and its target showing as up in Prometheus;
- Grafana loading the Tempo data source and the changed Loki data source, `Save & test` succeeding, the `Trace` link appearing on a log line and the trace-to-logs link finding the lines;
- a trace from a service on a cluster: the gateway, orders and the notifier send traces in unit tests with an in-memory exporter, and have not been run against the collector, Tempo or RabbitMQ in this change; the trace context in the messages orders publishes is covered by unit tests with a fake exchange, not by a broker;
- the sync order of waves 11 and 12, and the collector's behaviour while Tempo is not yet ready;
- what happens to traces across a restart of Tempo or the collector;
- the teardown with Tempo deployed;
- the capacity figures.

## Alternatives considered

- **`tempo-distributed`.** The supported chart. Many components and, in practice, an object store, for a few megabytes of traces a day; see the footprint above. It is the migration target, not the starting point.
- **Jaeger.** A different query UI and, for anything beyond memory, a storage backend of its own. Grafana can read it, but Tempo shares the vendor, the OTLP-first design and the object-storage route with Loki.
- **The collector's `debug` exporter only.** What there was before: traces are visible as a line per batch and gone.
- **A hosted tracing service.** Out of scope for a platform that runs its own components, and it would need a credential.
- **Trace ID as a Loki label.** It would make the link from a trace to its logs a plain selector, and it would create a stream per request. A text filter on the ID is slower and does not grow the index.
- **Enabling the metrics generator now.** It needs a remote-write endpoint and gives service graphs, which no one can use until spans exist.
- **TLS between the collector and Tempo now.** It would need certificates for an in-cluster hop that has no other client; it belongs with the network policies of the security phase.
