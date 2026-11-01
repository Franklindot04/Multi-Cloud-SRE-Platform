# Observability: metrics and logs

Turns on Prometheus, Grafana, an OpenTelemetry Collector, Loki and Alloy on the hub cluster, checks that they work, and removes them. What it is and why it looks like this is in [ADR-0020](../adr/0020-metrics-stack.md) (metrics) and [ADR-0021](../adr/0021-logging-stack.md) (logs); the definitions are in [`platform/observability`](../../platform/observability/README.md).

**This has run on a real EKS cluster**, in two sessions, with screenshots in [the evidence page](../observability-evidence.md): every Application Synced and Healthy, every Prometheus target up, the dashboards showing data, and Loki and Alloy running under `restricted` with their logs in the Logs dashboard. The cluster was temporary. Not yet seen: Alloy's behaviour across restarts. The teardown (`scripts/teardown-prep.sh`, then `scripts/teardown-argocd.sh`, then `terraform destroy`) was run on that cluster and left nothing behind. Where this runbook says something is expected, that comes from those sessions or from the definitions; if reality differs, that is a finding: write it down. The [logging section](#logs) ends with a checklist for an apply.

Everything is off unless the cluster Secret carries the label `platform.example/observability=true`. Nothing is exposed outside the cluster; you reach Grafana and Prometheus with a port-forward.

## Before you start

- Argo CD is installed on the cluster ([Argo CD runbook](argocd.md)) and the `platform/argocd/apps` files of this change are on `main` in GitHub: the root Application reads Git, not your working tree.
- There is room on the nodes. The stack requests about 0.45 vCPU and 1.4 GiB of memory, on top of everything else. On the default two `t3.large` Spot nodes that is tight when the data layer and the services run too; see the capacity paragraph in the ADR before enabling everything at once.
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

Within a few minutes seven Applications appear in Argo CD and become `Synced` and `Healthy`:

```bash
kubectl --context <EKS_CONTEXT> -n argocd get applications | grep observability-
```

| Application | What it deploys | Wave |
| --- | --- | --- |
| `observability-secrets-*` | the `observability` namespace (Pod Security `restricted`) and the Secret `grafana-admin` | 10 |
| `observability-stack-*` | Prometheus Operator and its CRDs, Prometheus, Grafana, kube-state-metrics | 11 |
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

Expected: the operator, Prometheus (`prometheus-kube-prometheus-stack-prometheus-0`, two containers), Grafana (one pod, three containers), kube-state-metrics, the collector, Loki (`loki-0`) and Alloy (two containers), all `Running` and ready. There is no Alertmanager and no node-exporter pod.

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
| the kubelet (with cAdvisor), the API server and CoreDNS | the cluster, from monitors the stack chart creates | always |
| kube-state-metrics, Prometheus, the operator and Grafana | the stack itself | always |

Targets for the services and the data layer are absent, not down, on a cluster that does not run them: the monitors select nothing. There is no `node-exporter` job; that is deliberate.

Then open the dashboards in Grafana (Dashboards, search for `Sample services`, `Data layer`, `Cluster capacity` and `Logs`). The cluster capacity dashboard shows data as soon as the kubelet and kube-state-metrics targets are up. The service and data layer panels show data when the services are running and receiving requests (the error-rate and latency panels are empty while there is no traffic). `smoke-test.sh` or a few requests through the gateway produce some.

### Check the collector

```bash
kubectl --context <EKS_CONTEXT> -n observability get deployment otel-collector
kubectl --context <EKS_CONTEXT> -n observability logs deployment/otel-collector --tail=20
```

It listens on `otel-collector.observability.svc` (OTLP gRPC 4317, HTTP 4318). The services do not send OTLP yet, so expect no traffic; the collector's own metrics (`otelcol_*`) are in Prometheus. When something sends traces, the log shows one line per batch from the `debug` exporter and the traces are dropped.

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

Run these once on the first cluster apply, and write down what differs from the expectation. All of them are expected from the definitions and none has been seen yet.

- [ ] `kubectl -n observability get pods`: `loki-0` and the `alloy-` pod are `Running` and ready under the `restricted` Pod Security level, with no admission warning in `kubectl -n observability get events`.
- [ ] In Prometheus, Status, Targets: the jobs `loki` and `alloy` are up (`up{job=~"loki|alloy"} == 1` returns both).
- [ ] In Grafana, Connections, Data sources: `Loki` is present and `Save & test` succeeds. In the `Logs` dashboard, lines appear for services in `shop` and for the pods in `data`.
- [ ] In Explore, `{namespace="shop"} | level="error"` returns lines of the services that logged an error and nothing from PostgreSQL; `{namespace="shop", service_name="payments"}` shows lines whose JSON has an upper-case level and whose metadata level is lower case (open a line and read the structured metadata).
- [ ] The level is not a label: Explore, the label browser lists `namespace`, `pod`, `container`, `app`, `service` and `service_name`, and no `level`.
- [ ] No PersistentVolumeClaim was created in the namespace: `kubectl -n observability get pvc` shows nothing (unless the persistent values were added on purpose).
- [ ] Alloy can read pods only: `kubectl auth can-i get secrets --as=system:serviceaccount:observability:alloy` answers `no`.
- [ ] After a Loki restart (`kubectl -n observability delete pod loki-0`) the pod comes back, the older lines are gone, and new lines arrive again within a minute or two without restarting Alloy.
- [ ] Teardown still ends clean: run `scripts/teardown-prep.sh` as described in the [data layer teardown](data-layer.md#teardown); it waits for the `observability-loki-*` and `observability-alloy-*` Applications and for the pods, finds no claim, and `scripts/teardown-argocd.sh` then finishes.

## Persistent volumes (optional, off)

By default Prometheus and Grafana keep their data in `emptyDir` and lose it when a pod is rescheduled. (Loki has its own optional claim; see the logs section.) To keep it, add `values-persistent.yaml` after `values.yaml` in the `valueFiles` of `platform/argocd/apps/91-observability-stack.yaml`, merge that to `main`, and let Argo CD sync. It creates a 5 GiB claim for Prometheus and a 1 GiB claim for Grafana on the cluster's default StorageClass.

These volumes outlive `terraform destroy` and keep billing: the Prometheus claim is not removed with the Application, because a StatefulSet keeps its claims. [`scripts/teardown-prep.sh`](data-layer.md#teardown) deletes the claims in the `observability` namespace; if you tear down by hand, delete them before the cloud checks.

## Disable and tear down

To stop the metrics and logging stack but keep the cluster, run the bootstrap script again without `--enable-observability` (and with the other flags you use). The label becomes `false` and Argo CD deletes the Applications. The namespace stays; delete it by hand if you want it gone, after the claims (below).

Before `terraform destroy`, follow the [data layer teardown](data-layer.md#teardown) (`scripts/teardown-prep.sh`, then `scripts/teardown-argocd.sh`, then `terraform destroy`): `scripts/teardown-prep.sh` removes the label, waits for the `observability-*` Applications (Loki and Alloy included) and the pods in the namespace, and deletes any claims there (including Loki's, if its persistent values were used). The Prometheus Operator does not leave a finalizer behind in this configuration, so teardown does not depend on the operator still running (the reason is in the ADR). If `teardown-prep.sh` stops on the pods in `observability`, read what it printed; it names the finalizer to look for and does not remove it. `scripts/teardown-argocd.sh` then deletes the `observability` namespace with the others.

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
