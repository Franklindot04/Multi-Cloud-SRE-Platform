# Observability: metrics, logs and traces

Turns on Prometheus, Grafana, an OpenTelemetry Collector, Loki, Alloy and Tempo on the hub cluster, checks that they work, and removes them. What it is and why it looks like this is in [ADR-0020](../adr/0020-metrics-stack.md) (metrics) and [ADR-0021](../adr/0021-logging-stack.md) (logs) and [ADR-0022](../adr/0022-tracing-stack.md) (traces); the definitions are in [`platform/observability`](../../platform/observability/README.md).

**This has run on a real EKS cluster**, in two sessions, with screenshots in [the evidence page](../observability-evidence.md): every Application Synced and Healthy, every Prometheus target up, the dashboards showing data, and Loki and Alloy running under `restricted` with their logs in the Logs dashboard. The cluster was temporary. Not yet seen: Alloy's behaviour across restarts, and anything about Tempo and traces, which were added after those sessions. No service sends traces yet. The teardown (`scripts/teardown-prep.sh`, then `scripts/teardown-argocd.sh`, then `terraform destroy`) was run on that cluster and left nothing behind. Where this runbook says something is expected, that comes from those sessions or from the definitions; if reality differs, that is a finding: write it down. The [logging section](#logs) ends with a checklist for an apply, with the Tempo steps in it.

Everything is off unless the cluster Secret carries the label `platform.example/observability=true`. Nothing is exposed outside the cluster; you reach Grafana and Prometheus with a port-forward.

## Before you start

- Argo CD is installed on the cluster ([Argo CD runbook](argocd.md)) and the `platform/argocd/apps` files of this change are on `main` in GitHub: the root Application reads Git, not your working tree.
- There is room on the nodes. The stack requests about 0.5 vCPU and 1.5 GiB of memory, on top of everything else. On the default two `t3.large` Spot nodes that is tight when the data layer and the services run too; see the capacity paragraph in the ADR before enabling everything at once.
- You know which other flags you use. The bootstrap script writes every cluster label on each run, so repeat them (for example `--enable-data`), or they are switched off.

## Enable

Dry run first. It changes nothing and calls no cluster or cloud API:

```bash
./scripts/bootstrap-argocd.sh --context <EKS_CONTEXT> --dry-run --enable-observability
```

Check that the printed cluster Secret has `"platform.example/observability": "true"` and the labels you expect for the data layer and the services. Then run it without `--dry-run`:

```bash
./scripts/bootstrap-argocd.sh --context <EKS_CONTEXT> --enable-observability
```

Within a few minutes eight Applications appear in Argo CD and become `Synced` and `Healthy`:

```bash
kubectl --context <EKS_CONTEXT> -n argocd get applications | grep observability-
```

| Application | What it deploys | Wave |
| --- | --- | --- |
| `observability-secrets-*` | the `observability` namespace (Pod Security `restricted`) and the Secret `grafana-admin` | 10 |
| `observability-stack-*` | Prometheus Operator and its CRDs, Prometheus, Grafana, kube-state-metrics | 11 |
| `observability-tempo-*` | Tempo (single binary, `emptyDir`, 24 hours of retention) | 11 |
| `observability-collector-*` | the OpenTelemetry Collector and its `ServiceMonitor` | 12 |
| `observability-monitors-*` | monitors for the four services, PostgreSQL and RabbitMQ | 13 |
| `observability-dashboards-*` | the four dashboards, as ConfigMaps | 14 |
| `observability-loki-*` | Loki (single binary, `emptyDir`, 48 hours of retention) | 15 |
| `observability-alloy-*` | Alloy, the log collector | 16 |

The monitors and the collector's `ServiceMonitor` need the operator's CRDs, which the stack installs. If they sync first they report the missing kinds and retry with backoff until the CRDs exist; that is expected during the first sync and should clear by itself.

Check the pods:

```bash
kubectl --context <EKS_CONTEXT> -n observability get pods
```

Expected: the operator, Prometheus (`prometheus-kube-prometheus-stack-prometheus-0`, two containers), Grafana (one pod, three containers), kube-state-metrics, the collector, Loki (`loki-0`), Alloy (two containers) and Tempo (`tempo-0`), all `Running` and ready. There is no Alertmanager and no node-exporter pod.

## Reach Grafana and Prometheus

There is no ingress. Use a port-forward and leave it running in its own terminal:

```bash
kubectl --context <EKS_CONTEXT> -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80
kubectl --context <EKS_CONTEXT> -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

Grafana is then at <http://localhost:3000> and Prometheus at <http://localhost:9090>.

### Read the Grafana admin password

The password was generated in the cluster the first time the secrets Application synced, and is stored only in the Secret `grafana-admin`. Read it yourself; do not paste it into a ticket, a chat or a file in the repository:

```bash
kubectl --context <EKS_CONTEXT> -n observability get secret grafana-admin -o jsonpath='{.data.admin-user}' | base64 -d; echo
kubectl --context <EKS_CONTEXT> -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Sign in with that user and password. The Job that creates the Secret prints only its name, and a later sync never changes it. To rotate it, delete the Secret, sync `observability-secrets-*` again and restart Grafana: `kubectl --context <EKS_CONTEXT> -n observability rollout restart deployment/kube-prometheus-stack-grafana`. (With the persistent values Grafana keeps the password in its own database after the first start, so change it in Grafana too.)

## Check that the targets are up

In Prometheus, open Status, then Targets (<http://localhost:9090/targets>). Or from a terminal, with the Prometheus port-forward running:

```bash
curl -s 'http://localhost:9090/api/v1/query?query=count%20by%20(job)%20(up%20%3D%3D%201)'
curl -s 'http://localhost:9090/api/v1/query?query=up%20%3D%3D%200'
```

The first lists the jobs that answer; the second must come back with an empty result. Expected jobs:

| Job | Target | Present when |
| --- | --- | --- |
| `gateway`, `orders`, `payments`, `notifier` | the services, port `http`, path `/metrics` (job = service name) | the services are deployed (`--enable-apps`) |
| `platform-mq` | RabbitMQ, port `prometheus` | the data layer is deployed (`--enable-data`) |
| `observability/postgres` | PostgreSQL instance pods, port `metrics` | the data layer is deployed |
| `otel-collector` | the collector's own metrics and the metrics it receives | always |
| `loki`, `alloy` | the log stack, port `http-metrics` | the logging stack is deployed (always, with the label) |
| `tempo` | Tempo, port `tempo-prom-metrics` (3200) | the tracing stack is deployed (always, with the label) |
| the kubelet (with cAdvisor), the API server and CoreDNS | the cluster, from monitors the stack chart creates | always |
| kube-state-metrics, Prometheus, the operator and Grafana | the stack itself | always |

Targets for the services and the data layer are absent, not down, on a cluster that does not run them: the monitors select nothing. There is no `node-exporter` job; that is deliberate.

Then open the dashboards in Grafana (Dashboards, search for `Sample services`, `Data layer`, `Cluster capacity` and `Logs`). The cluster capacity dashboard shows data as soon as the kubelet and kube-state-metrics targets are up. The service and data layer panels show data when the services are running and receiving requests (the error-rate and latency panels are empty while there is no traffic). `smoke-test.sh` or a few requests through the gateway produce some.

### Check the collector

```bash
kubectl --context <EKS_CONTEXT> -n observability get deployment otel-collector
kubectl --context <EKS_CONTEXT> -n observability logs deployment/otel-collector --tail=20
```

It listens on `otel-collector.observability.svc` (OTLP gRPC 4317, HTTP 4318). The services do not send OTLP yet, so expect no traffic; the collector's own metrics (`otelcol_*`) are in Prometheus. The traces pipeline sends what it receives to Tempo (see [Traces](#traces)); a failed export is logged by the collector (`Exporting failed`) and retried for a minute.

## Logs

Alloy tails the logs of the pods in the `shop` and `data` namespaces through the Kubernetes API and pushes them to Loki; Grafana reads them from the data source `Loki`. Nothing else is collected: not `kube-system`, `argocd`, `cert-manager` or this namespace. Logs are kept for **48 hours** and are lost when the Loki pod is rescheduled (see capacity and retention below). The reasons are in [ADR-0021](../adr/0021-logging-stack.md).

### Open the Logs dashboard and Explore

With the Grafana port-forward from above running, open <http://localhost:3000>, sign in, and open Dashboards, then `Logs`. Pick the namespaces and services at the top; the search box takes a case-insensitive regular expression and applies to the volume panel and the lines. The Sample services and Data layer dashboards have a `Logs` link in their header that keeps the time range and the variables of the same name.

For free-form queries use Explore: choose the data source `Loki`, switch the editor to Code, and type a query. Loki itself has no port-forward of its own unless you want one (`kubectl --context <EKS_CONTEXT> -n observability port-forward svc/loki 3100:3100`; there is no authentication, and the API is at <http://localhost:3100>).

### Useful queries

The labels are `namespace`, `pod`, `container`, `app`, `service` and `service_name` (Loki's own, the same as `service` for the services and the container name for pods without an app label, such as PostgreSQL). The `level` is structured metadata on JSON lines: filter on it with `| level="error"`, do not use it in the selector.

```text
{namespace="shop", service_name="orders"}
{namespace="shop"} | level="error"
{namespace="shop"} |= "<request id>"
{namespace="shop", service_name="gateway"} | json | status >= 500
{namespace="shop"} | json | duration_ms > 500
sum by (service_name) (rate({namespace="shop"} | level="error" [5m]))
sum by (service_name) (count_over_time({namespace=~"shop|data"} [1h]))
{namespace="data", container="postgres"} |~ "(?i)error|fatal"
```

A selector must have at least one matcher that cannot match the empty value: `{namespace=~".*"}` is refused, `{namespace=~".+"}` is not. The request and trace IDs are in the line, so `|= "<id>"` finds every line of a request across services. `| json` parses a line at query time, which is slower than a plain filter; the field names `status` and `duration_ms` are what the gateway writes, and the other services were not all checked line by line (payments goes through the framework's own JSON format). Plain-text lines (PostgreSQL's, for example) have no level and no JSON fields.

### Capacity and retention

Loki asks for 100m CPU and 256Mi memory and Alloy for 55m and 152Mi (with its reload sidecar), about 0.155 vCPU and 0.4 GiB together, on top of the metrics stack. The Loki data directory is an `emptyDir` limited to 2 GiB; if it fills, the pod is evicted and the logs go with it. Retention is 48 hours (the compactor deletes older data after a delay of two hours, so the disk can briefly hold a little more), and lines older than 48 hours are refused on the way in. Ingestion is capped at about 4 MB/s overall and 2 MB/s per stream; lines over 256 KB are refused. To keep logs across restarts, add `values-persistent.yaml` of the `loki` chart after `values.yaml` in the `valueFiles` of `platform/argocd/apps/95-observability-loki.yaml`: it adds a 5 GiB claim that outlives `terraform destroy` until deleted (`scripts/teardown-prep.sh` deletes the claims in the `observability` namespace). Production would use object storage instead; see the ADR.

### Troubleshooting logs

**The Logs dashboard shows no logs.** Work from the source to the screen. Is anything running in `shop` and `data` (`kubectl -n shop get pods`)? Is Alloy up (`kubectl -n observability get pods`; `kubectl -n observability logs deployment/alloy -c alloy --tail=50`)? Is Loki ready (`kubectl -n observability get pod loki-0`)? In Explore, `{namespace=~".+"}` over the last hour tells whether anything arrived at all; if it does, a variable at the top of the dashboard is excluding it. A time range shorter than the lines you want is the other common cause.

**Alloy cannot list pods.** The log of the `alloy` container shows `forbidden` for `pods` or `namespaces`. Check that the ClusterRole `alloy` and its binding exist (`kubectl get clusterrole alloy clusterrolebinding alloy`) and that the Application is not blocked by the AppProject (`kubectl -n argocd get application | grep observability-alloy`). The role lets Alloy get, list and watch pods, pod logs and namespaces and nothing else; do not widen it to read Secrets.

**Alloy is up but sends nothing.** Look for `error` lines in its log: the push URL is `http://loki.observability.svc.cluster.local:3100/loki/api/v1/push`, and `connection refused` means Loki is not ready yet (it retries on its own). `kubectl -n observability port-forward deployment/alloy 12345:12345` opens Alloy's own page at <http://localhost:12345> with the state of each component; `loki.source.kubernetes.pods` should list the targets it found.

**Loki is not ready.** `kubectl -n observability describe pod loki-0` and `logs loki-0`. Under `restricted` a pod that cannot start usually names the setting in the events. A pod stuck in `Pending` is a node out of room (the same cause as for the other pods). A pod in `Evicted` or restarted after running for a while had its 2 GiB `emptyDir` filled or its node removed: the logs are gone, and the cause of the volume is the first thing to look at (a crash-looping pod writing a lot).

**Lines are missing or rejected.** The Alloy log and Loki's log (`ingestion rate limit exceeded`, `per stream rate limit exceeded`, `entry too far behind`, `line too long`) say which limit was hit. The limits are in the `limits_config` of `platform/observability/loki/values.yaml`. Lines older than 48 hours are dropped on purpose (`reject_old_samples_max_age`), which matters when Alloy first reads a pod that has been running for longer than that: the old part of its log is not stored. If one pod floods the stream limit, fix the pod; raising the limit hides it.

**Why a log line has no level.** Only JSON lines have one. PostgreSQL and RabbitMQ write plain text, and so do the lines some frameworks print before the services start. Loki also derives its own `detected_level` from the text; the dashboards use `level`.

**A pod without an `app` label is called after its container.** That is `service_name`: for a pod without the `service` label, Loki uses the container name (for example `postgres`).

### Verify after install

Run these once on the first cluster apply, and write down what differs from the expectation. The Loki and Alloy items were seen on a real cluster ([evidence](../observability-evidence.md)); the Tempo and trace items at the end have not been seen yet.

- [ ] `kubectl -n observability get pods`: `loki-0` and the `alloy-` pod are `Running` and ready under the `restricted` Pod Security level, with no admission warning in `kubectl -n observability get events`.
- [ ] In Prometheus, Status, Targets: the jobs `loki` and `alloy` are up (`up{job=~"loki|alloy"} == 1` returns both).
- [ ] In Grafana, Connections, Data sources: `Loki` is present and `Save & test` succeeds. In the `Logs` dashboard, lines appear for services in `shop` and for the pods in `data`.
- [ ] In Explore, `{namespace="shop"} | level="error"` returns lines of the services that logged an error and nothing from PostgreSQL; `{namespace="shop", service_name="payments"}` shows lines whose JSON has an upper-case level and whose metadata level is lower case (open a line and read the structured metadata).
- [ ] The level is not a label: Explore, the label browser lists `namespace`, `pod`, `container`, `app`, `service` and `service_name`, and no `level`.
- [ ] No PersistentVolumeClaim was created in the namespace: `kubectl -n observability get pvc` shows nothing (unless the persistent values were added on purpose).
- [ ] Alloy can read pods only: `kubectl auth can-i get secrets --as=system:serviceaccount:observability:alloy` answers `no`.
- [ ] After a Loki restart (`kubectl -n observability delete pod loki-0`) the pod comes back, the older lines are gone, and new lines arrive again within a minute or two without restarting Alloy.
- [ ] `kubectl -n observability get pods`: `tempo-0` is `Running` and ready under the `restricted` Pod Security level, with no admission warning in `kubectl -n observability get events`, and `kubectl -n observability get pvc` still shows nothing.
- [ ] In Prometheus, Status, Targets: the job `tempo` is up (`up{job="tempo"} == 1`).
- [ ] In Grafana, Connections, Data sources: `Tempo` is present and `Save & test` succeeds, and `Loki` still does, with a derived field `trace_id` that links to `Tempo`.
- [ ] A test trace sent to the Collector (see [Send a test trace](#send-a-test-trace)) is found in Grafana, in Explore with the data source `Tempo`, by its ID; the collector's log has no `Exporting failed` line.
- [ ] From the test trace, `Logs for this span` finds nothing (the test span has no log lines) and does not return an error; once a service sends traces, it finds the lines that carry the trace ID.
- [ ] After a Tempo restart (`kubectl -n observability delete pod tempo-0`) the pod comes back, the test trace is gone, and a new test trace is found again within a minute without restarting the collector.
- [ ] Teardown still ends clean: run `scripts/teardown-prep.sh` as described in the [data layer teardown](data-layer.md#teardown); it waits for the `observability-loki-*`, `observability-alloy-*` and `observability-tempo-*` Applications and for the pods, finds no claim, and `scripts/teardown-argocd.sh` then finishes.

## Traces

The Collector sends the traces it receives to Tempo, a single binary with storage on an `emptyDir` and **24 hours of retention**; Grafana reads them from the data source `Tempo`. The path is service, then Collector (`otel-collector.observability.svc`, OTLP on 4317 or 4318), then Tempo (`tempo.observability.svc`, OTLP on 4317, plain gRPC inside the cluster). Traces are lost when the Tempo pod restarts or is rescheduled. The reasons are in [ADR-0022](../adr/0022-tracing-stack.md). **No service sends traces yet**: none uses an OpenTelemetry SDK, so Tempo is empty until one does, apart from a test trace you send yourself. The Tempo chart is deprecated upstream; the ADR says why it is used anyway and how to leave it.

### Open Explore with Tempo

With the Grafana port-forward from above running, open <http://localhost:3000>, sign in, and open Explore. Choose the data source `Tempo`. To find a trace by its ID, use the query type `TraceQL` (or the TraceID tab, if the editor offers it) and paste the 32-character ID. To find traces by service, once services send traces, use TraceQL:

```text
{ resource.service.name = "gateway" }
{ resource.service.name = "orders" && status = error }
{ resource.service.name = "payments" && duration > 500ms }
```

Search by service, span name or duration uses TraceQL, which Tempo answers without the metrics generator. There is no service graph and no node graph: both need the metrics generator, which is off. Tempo has no port-forward of its own unless you want one (`kubectl --context <EKS_CONTEXT> -n observability port-forward svc/tempo 3200:3200`; there is no authentication, and a trace is at `http://localhost:3200/api/traces/<trace id>`).

### From a log line to its trace, and back

Every request log line has `"trace_id":"<32 hex digits>"`. In Explore with the data source `Loki`, open a line: the field `trace_id` has a `Trace` link that opens the trace in Tempo. In a trace, `Logs for this span` runs `{namespace=~".+"} |= "<trace id>"` against Loki, for the time of the span with five minutes either side. This works for a trace only if the trace exists in Tempo, which needs a service that sends spans. Neither link has been seen working in Grafana yet.

### Send a test trace

There is no honest way to do this from a pod in the cluster: the Collector, Tempo and Grafana images have no shell or `curl`, and a throwaway pod would have to pull a tool image and meet the `restricted` level by hand. Send it from your laptop through a port-forward to the Collector instead. In one terminal:

```bash
kubectl --context <EKS_CONTEXT> -n observability port-forward svc/otel-collector 4318:4318
```

In another:

```bash
TRACE_ID=$(openssl rand -hex 16)
SPAN_ID=$(openssl rand -hex 8)
NOW=$(date +%s)
echo "trace id: $TRACE_ID"
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:4318/v1/traces \
  -H 'Content-Type: application/json' \
  -d '{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"manual-test"}}]},"scopeSpans":[{"scope":{"name":"manual"},"spans":[{"traceId":"'"$TRACE_ID"'","spanId":"'"$SPAN_ID"'","name":"test span","kind":2,"startTimeUnixNano":"'"${NOW}"'000000000","endTimeUnixNano":"'"$((NOW + 1))"'000000000"}]}]}]}'
```

`200` means the Collector accepted it. In a local test of this command against the same images, Tempo returned the trace by its ID within about ten seconds, and a TraceQL search for the service had found nothing after eight, so look it up by ID first and allow a minute for the search. Paste the trace ID into Explore with the data source `Tempo`, or fetch it from `http://localhost:3200/api/traces/<trace id>` with the Tempo port-forward above.

### Troubleshooting traces

**Explore with Tempo says the trace was not found.** Wait a few seconds and ask again (a search by service can take a minute); a new trace is not available at once. Then check the path from the end: is Tempo ready (`kubectl -n observability get pod tempo-0`), does the collector log `Exporting failed` (`kubectl -n observability logs deployment/otel-collector --tail=50`), and did the Collector answer `200` to the test trace. A collector that cannot reach Tempo retries for a minute and then drops the batch.

**Tempo restarted and the traces are gone.** Expected: the storage is an `emptyDir` and the retention is 24 hours at most. Send the test trace again. To keep traces, add `tempo/values-persistent.yaml` after `values.yaml` in `platform/argocd/apps/97-observability-tempo.yaml` (a 5 GiB claim that outlives `terraform destroy`; the file says what that costs), or move to object storage as the ADR describes.

**Tempo is not ready.** `kubectl -n observability describe pod tempo-0` and `logs tempo-0`. Under `restricted` a pod that cannot start usually names the setting in the events. A pod in `Evicted` had its 1 GiB `emptyDir` filled or its node removed.

**The `Trace` link on a log line does nothing, or the link from a trace finds no lines.** The first needs the data source `Loki` to have the derived field `trace_id` (Connections, Data sources, Loki) and a trace with that ID in Tempo. The second runs a text search for the ID over the span's time range plus five minutes either side: widen the Explore time range if the logs are older than that, and remember that Loki keeps 48 hours and Tempo 24.

## Persistent volumes (optional, off)

By default Prometheus and Grafana keep their data in `emptyDir` and lose it when a pod is rescheduled. (Loki and Tempo have their own optional claims; see the logs and traces sections.) To keep it, add `values-persistent.yaml` after `values.yaml` in the `valueFiles` of `platform/argocd/apps/91-observability-stack.yaml`, merge that to `main`, and let Argo CD sync. It creates a 5 GiB claim for Prometheus and a 1 GiB claim for Grafana on the cluster's default StorageClass.

These volumes outlive `terraform destroy` and keep billing: the Prometheus claim is not removed with the Application, because a StatefulSet keeps its claims. [`scripts/teardown-prep.sh`](data-layer.md#teardown) deletes the claims in the `observability` namespace; if you tear down by hand, delete them before the cloud checks.

## Disable and tear down

To stop the metrics and logging stack but keep the cluster, run the bootstrap script again without `--enable-observability` (and with the other flags you use). The label becomes `false` and Argo CD deletes the Applications. The namespace stays; delete it by hand if you want it gone, after the claims (below).

Before `terraform destroy`, follow the [data layer teardown](data-layer.md#teardown) (`scripts/teardown-prep.sh`, then `scripts/teardown-argocd.sh`, then `terraform destroy`): `scripts/teardown-prep.sh` removes the label, waits for the `observability-*` Applications (Loki, Alloy and Tempo included) and the pods in the namespace, and deletes any claims there (including Loki's, if its persistent values were used). The Prometheus Operator does not leave a finalizer behind in this configuration, so teardown does not depend on the operator still running (the reason is in the ADR). If `teardown-prep.sh` stops on the pods in `observability`, read what it printed; it names the finalizer to look for and does not remove it. `scripts/teardown-argocd.sh` then deletes the `observability` namespace with the others.

## Troubleshooting

**The Grafana pod is in `CreateContainerConfigError`.** The Secret `grafana-admin` does not exist yet. Check the secrets Application and its Job: `kubectl --context <EKS_CONTEXT> -n argocd get application | grep observability-secrets`, then `kubectl --context <EKS_CONTEXT> -n observability get jobs,pods` and `logs` of the generator Job (it prints `created` or `exists` with the Secret's name, never a value). A sync creates the Secret; a Job that was not run because the Application was never synced leaves it missing: sync the Application. Grafana starts by itself once the Secret exists.

**A pod is `Pending`.** Look at `kubectl -n observability describe pod <name>`. `Insufficient cpu` means the nodes are full: this stack has no priority class on purpose, so the scheduler places the services first. Add a node or free room, see the capacity paragraph in the ADR. A Spot node that was reclaimed shows the same.

**Prometheus has no pod, or a pod admission error appears in events.** The namespace enforces Pod Security `restricted`. The `Prometheus` object's own pod is created by the operator, and its container settings were not checked offline. Read `kubectl -n observability get events` and `describe statefulset prometheus-kube-prometheus-stack-prometheus`; the message names the setting that was refused. Report it; do not weaken the namespace label to get past it.

**An Application is `OutOfSync` on a CRD, or says an annotation is too long.** The operator's CRDs are larger than client-side apply allows, so the stack Application must sync with `ServerSideApply=true`; `make observability-check` fails if it does not. Look at the sync options of `observability-stack-*`.

**The monitors Application reports `no matches for kind ServiceMonitor`.** The CRDs are not installed yet because the stack has not synced. It retries; check `observability-stack-*` first.

**A target is down.** On the Targets page, read the error. `connection refused` or a timeout from a service in `shop` means the pod is not ready or the port name differs from `http`. `404` means the path is not `/metrics`. For a target that does not appear at all, compare the labels on the Service with the selector in [`monitors`](../../platform/observability/monitors/templates): `kubectl -n shop get svc --show-labels` should show `app.kubernetes.io/name=<service>` and `app.kubernetes.io/part-of=sre-sample`. PostgreSQL is a `PodMonitor`: check `kubectl -n data get pods --show-labels` for `cnpg.io/cluster=platform-pg` and `cnpg.io/podRole=instance`.

**A dashboard is missing in Grafana.** The ConfigMaps must be in the `observability` namespace with the label `grafana_dashboard: "1"`: `kubectl -n observability get configmap -l grafana_dashboard=1`. If they are there, look at the sidecar log: `kubectl -n observability logs deployment/kube-prometheus-stack-grafana -c grafana-sc-dashboard`. A dashboard that loads but shows no data usually means the metric is not being scraped: check the target, then run the panel's query in Prometheus.

**A panel says No data on a healthy cluster.** The error-rate and latency panels need traffic. The PostgreSQL panels need the data layer. The RabbitMQ panels that come from the services need the notifier and orders in the `data` profile. The data layer dashboard has no RabbitMQ broker panels yet.

**Node disk or network figures are missing.** node-exporter is disabled on purpose (it cannot run under `restricted`). The cluster dashboard shows node CPU and memory as the sum of the pods on the node.

**Everything was fine and the history is gone.** A Prometheus or Grafana pod was rescheduled, and the data was in `emptyDir`. Expected in the default profile; see the persistent volumes section.

## What to record when you run this

The first two runs are written up in [the evidence page](../observability-evidence.md). On a new run, note what differs from it: whether Prometheus and Grafana started under `restricted` and loaded the data source and the dashboards, which targets were up, whether the dashboard queries returned data, how long the first sync took, and, still unseen, what happens to log lines across a restart of Alloy or Loki.
