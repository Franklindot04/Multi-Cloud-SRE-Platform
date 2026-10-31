# Observability: metrics foundation

Turns on Prometheus, Grafana and an OpenTelemetry Collector on the hub cluster, checks that they work, and removes them. What it is and why it looks like this is in [ADR-0020](../adr/0020-metrics-stack.md); the definitions are in [`platform/observability`](../../platform/observability/README.md).

**None of this has run on a real cluster yet.** The definitions are rendered, schema-checked and contract-checked offline, and the collector was run locally from its pinned image. The steps below are what to do and what to expect; where something is described as expected, it is expected from the definitions and not yet seen. If reality differs, that is a finding: write it down.

Everything is off unless the cluster Secret carries the label `platform.example/observability=true`. Nothing is exposed outside the cluster; you reach Grafana and Prometheus with a port-forward.

## Before you start

- Argo CD is installed on the cluster ([Argo CD runbook](argocd.md)) and the `platform/argocd/apps` files of this change are on `main` in GitHub: the root Application reads Git, not your working tree.
- There is room on the nodes. The stack requests about 0.3 vCPU and 1 GiB of memory, on top of everything else. On the default two `t3.large` Spot nodes that is tight when the data layer and the services run too; see the capacity paragraph in the ADR before enabling everything at once.
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

Within a few minutes five Applications appear in Argo CD and become `Synced` and `Healthy`:

```bash
kubectl --context <EKS_CONTEXT> -n argocd get applications | grep observability-
```

| Application | What it deploys | Wave |
| --- | --- | --- |
| `observability-secrets-*` | the `observability` namespace (Pod Security `restricted`) and the Secret `grafana-admin` | 10 |
| `observability-stack-*` | Prometheus Operator and its CRDs, Prometheus, Grafana, kube-state-metrics | 11 |
| `observability-collector-*` | the OpenTelemetry Collector and its `ServiceMonitor` | 12 |
| `observability-monitors-*` | monitors for the four services, PostgreSQL and RabbitMQ | 13 |
| `observability-dashboards-*` | the three dashboards, as ConfigMaps | 14 |

The monitors and the collector's `ServiceMonitor` need the operator's CRDs, which the stack installs. If they sync first they report the missing kinds and retry with backoff until the CRDs exist; that is expected during the first sync and should clear by itself.

Check the pods:

```bash
kubectl --context <EKS_CONTEXT> -n observability get pods
```

Expected: the operator, Prometheus (`prometheus-kube-prometheus-stack-prometheus-0`, two containers), Grafana (one pod, three containers), kube-state-metrics and the collector, all `Running` and ready. There is no Alertmanager and no node-exporter pod.

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
| the kubelet (with cAdvisor), the API server and CoreDNS | the cluster, from monitors the stack chart creates | always |
| kube-state-metrics, Prometheus, the operator and Grafana | the stack itself | always |

Targets for the services and the data layer are absent, not down, on a cluster that does not run them: the monitors select nothing. There is no `node-exporter` job; that is deliberate.

Then open the dashboards in Grafana (Dashboards, search for `Sample services`, `Data layer` and `Cluster capacity`). The cluster capacity dashboard shows data as soon as the kubelet and kube-state-metrics targets are up. The service and data layer panels show data when the services are running and receiving requests (the error-rate and latency panels are empty while there is no traffic). `smoke-test.sh` or a few requests through the gateway produce some.

### Check the collector

```bash
kubectl --context <EKS_CONTEXT> -n observability get deployment otel-collector
kubectl --context <EKS_CONTEXT> -n observability logs deployment/otel-collector --tail=20
```

It listens on `otel-collector.observability.svc` (OTLP gRPC 4317, HTTP 4318). The services do not send OTLP yet, so expect no traffic; the collector's own metrics (`otelcol_*`) are in Prometheus. When something sends traces, the log shows one line per batch from the `debug` exporter and the traces are dropped.

## Persistent volumes (optional, off)

By default Prometheus and Grafana keep their data in `emptyDir` and lose it when a pod is rescheduled. To keep it, add `values-persistent.yaml` after `values.yaml` in the `valueFiles` of `platform/argocd/apps/91-observability-stack.yaml`, merge that to `main`, and let Argo CD sync. It creates a 5 GiB claim for Prometheus and a 1 GiB claim for Grafana on the cluster's default StorageClass.

These volumes outlive `terraform destroy` and keep billing: the Prometheus claim is not removed with the Application, because a StatefulSet keeps its claims. [`scripts/teardown-prep.sh`](data-layer.md#teardown) deletes the claims in the `observability` namespace; if you tear down by hand, delete them before the cloud checks.

## Disable and tear down

To stop the metrics foundation but keep the cluster, run the bootstrap script again without `--enable-observability` (and with the other flags you use). The label becomes `false` and Argo CD deletes the Applications. The namespace stays; delete it by hand if you want it gone, after the claims (below).

Before `terraform destroy`, follow the [data layer teardown](data-layer.md#teardown) (`scripts/teardown-prep.sh`, then `scripts/teardown-argocd.sh`, then `terraform destroy`): `scripts/teardown-prep.sh` removes the label, waits for the `observability-*` Applications and the pods in the namespace, and deletes any claims there. The Prometheus Operator does not leave a finalizer behind in this configuration, so teardown does not depend on the operator still running (the reason is in the ADR). If `teardown-prep.sh` stops on the pods in `observability`, read what it printed; it names the finalizer to look for and does not remove it. `scripts/teardown-argocd.sh` then deletes the `observability` namespace with the others.

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

## What to record when you first run this

Because this has not run yet, note the following and update the ADR and this runbook with what you see: whether Prometheus started under `restricted`, whether Grafana started and loaded the data source and the three dashboards, which targets were up, whether the dashboard queries returned data, and how long the first sync took.
