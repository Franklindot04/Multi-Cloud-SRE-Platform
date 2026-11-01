# Observability on a real cluster

What the metrics and logging stack looked like when it ran on an EKS cluster. The screenshots were taken over two apply sessions on a temporary cluster, which has since been destroyed. The first session brought up everything except Loki and Alloy; the second added them. What the stack is and why it looks like this is in [ADR-0020](adr/0020-metrics-stack.md) and [ADR-0021](adr/0021-logging-stack.md); the procedure is in the [observability runbook](runbooks/observability.md).

## Argo CD

The three pages of the Applications list, sorted by name. Every application is Synced and Healthy. These pages count 25 applications, which is the first session (no Loki or Alloy in the list); the second session had 27, also all Synced and Healthy.

![Argo CD applications list, page 1 of 3: gateway, notifier, orders, payments, argocd, the load balancer controller, cert-manager and the data namespaces, all Synced and Healthy](images/argocd-01-applications-healthy-page1.png)

![Argo CD applications list, page 2 of 3: the data layer applications (PostgreSQL, RabbitMQ and its operator, secrets, storage, Valkey), metrics-server and the first observability applications, all Synced and Healthy](images/argocd-01-applications-healthy-page2.png)

![Argo CD applications list, page 3 of 3: the observability monitors, secrets and stack, the root application and the priority classes, all Synced and Healthy](images/argocd-01-applications-healthy-page3.png)

## Prometheus

The target health page, scrolled in five parts. Every scrape pool shows all of its targets up: the PostgreSQL pod monitor, Alloy, the gateway, the API server, CoreDNS, Grafana, kube-state-metrics, the kubelet (three paths on three nodes), the Prometheus Operator and Prometheus itself, Loki, the notifier, orders, the OpenTelemetry Collector (its own metrics and the exporter), payments and RabbitMQ. This is the second session, which is why Alloy and Loki are in the list.

![Prometheus target health, part 1: PostgreSQL, Alloy, gateway, API server and CoreDNS, all up](images/prometheus-01-targets-up-1.png)

![Prometheus target health, part 2: CoreDNS, Grafana, kube-state-metrics and the kubelet metrics endpoint on three nodes, all up](images/prometheus-01-targets-up-2.png)

![Prometheus target health, part 3: the kubelet cAdvisor and probes endpoints, and the Prometheus Operator, all up](images/prometheus-01-targets-up-3.png)

![Prometheus target health, part 4: Prometheus and its config reloader, Loki, notifier and orders, all up](images/prometheus-01-targets-up-4.png)

![Prometheus target health, part 5: the OpenTelemetry Collector, payments and RabbitMQ, all up](images/prometheus-01-targets-up-5.png)

## Grafana

The dashboard list shows the four dashboards the platform provisions: Cluster capacity, Data layer, Logs and Sample services.

![Grafana dashboard list with Cluster capacity, Data layer, Logs and Sample services](images/grafana-01-dashboard-list.png)

Cluster capacity: three nodes ready, 58.9% of allocatable CPU and 32.7% of allocatable memory requested, 48 pods and none not ready, then CPU and memory per node and per namespace.

![Cluster capacity dashboard, top: node and pod counts, requested CPU and memory, usage by node and by namespace](images/grafana-02-cluster-capacity-top.png)

The lower half has the top pods by CPU and memory and the restart and readiness panels. The restart and not-ready panels say No data, which is what a healthy cluster looks like for them.

![Cluster capacity dashboard, bottom: requests by namespace, top pods, restarts and readiness panels with No data, pods by phase](images/grafana-02-cluster-capacity-bottom.png)

Sample services: seven targets up and none down, about 4 requests per second across the four services, and no 5xx responses.

![Sample services dashboard, top: targets up, request rate, error rate and latency by service](images/grafana-03-sample-services-top.png)

The lower half breaks requests down by route: request rate, 5xx and 4xx responses, p95 latency and the slowest routes.

![Sample services dashboard, bottom: request rate, error responses and p95 latency by route, and the slowest routes table](images/grafana-03-sample-services-bottom.png)

Data layer: one PostgreSQL instance reporting, connections, transactions, cache hit ratio and volume use. The replication panel has no data, and there is only one instance.

![Data layer dashboard, top: PostgreSQL panels and the first RabbitMQ panels](images/grafana-04-data-layer-top.png)

The lower half covers RabbitMQ (broker endpoint up, messages published and consumed, dead letters, outbox lag) and the database and cache as the services see them: connection pools, query latency and cache lookups.

![Data layer dashboard, bottom: RabbitMQ message panels, outbox lag, connection pools, query latency and cache lookups](images/grafana-04-data-layer-bottom.png)

## Logs

The Logs dashboard with every namespace and service selected: about 5 lines per second, seven services and thirteen pods logging, and the lines themselves, which are the services' JSON log lines. The log volume panel has a series for each of the seven services: gateway, notifier, orders, payments, platform-mq, postgresql and valkey.

![Logs dashboard with all namespaces and services: stat panels, log volume by service, error lines by service and the newest JSON log lines](images/grafana-05-logs-overview.png)

The same dashboard filtered to the `data` namespace with the search text `level.:error`. The matching part of each line is highlighted. The lines shown are errors logged by the PostgreSQL pod (the CloudNativePG instance manager failing to connect while the database was shutting down), and the error panels show only PostgreSQL.

![Logs dashboard filtered to the data namespace and a search for level.:error, with PostgreSQL error lines highlighted](images/grafana-06-logs-postgres-errors.png)

Explore with the Loki data source and the query `{namespace="shop"} | level="info"`. The field list shows the stream labels `namespace`, `pod`, `container`, `app`, `service` and `service_name`, plus `job` and `instance` from Alloy's log source, and `level` and `detected_level` as metadata.

![Grafana Explore on Loki with a query on the shop namespace filtered by level, showing the log volume, the JSON lines and the list of labels and fields](images/grafana-07-logs-explore-level.png)

## What was observed

**First session.** All applications Synced and Healthy, every Prometheus target up, and three dashboards showing data: Cluster capacity, Sample services and Data layer.

**Second session.** Loki and Alloy started under the restricted Pod Security level with no PersistentVolumeClaim (storage is `emptyDir`), and their Prometheus targets were up. Logs arrived with the labels `namespace`, `pod`, `container`, `app` and `service`, and `level` was available as structured metadata. The Logs dashboard worked, including the search box and the PostgreSQL error view.

**A Spot node was replaced during the second session.** The PostgreSQL primary and the Valkey pods were rescheduled onto the new node and recovered without anyone doing anything. PostgreSQL is a single instance today, so while its node is gone the database is down until the pod runs again somewhere else; that is what happened here, and it recovered. This is an observation about one event. High availability for PostgreSQL is planned, and nothing here shows that it works.

**Found and fixed during these sessions.**

- The Logs dashboard search put the text inside a double-quoted LogQL string, so a double quote or a backslash in the search broke the query. It now uses a backtick (raw) string.
- The Service dropdown looked as if it lacked PostgreSQL; it was only clipped on screen, and `postgresql` was in the list.
- Teardown needed a second step to get past Argo CD finalizers. It is now scripted in [`scripts/teardown-argocd.sh`](../scripts/teardown-argocd.sh), after `scripts/teardown-prep.sh` and before `terraform destroy`. At the end of the second session both scripts were run on the cluster in that order (`scripts/teardown-argocd.sh` first as a dry run, then for real), `terraform destroy` removed all 54 resources, and the AWS checks afterwards came back empty. `scripts/teardown-prep.sh` had already been run on a cluster in the first session, which is where its problem with a finalizer whose operator was already gone was found and fixed.

**Known limits.**

- At the time of these sessions the services were not instrumented with an OpenTelemetry SDK, so the OpenTelemetry Collector received nothing and there were no traces. The services only wrote a `trace_id` into their log lines.
- There is no ingress. Everything on this page was viewed through `kubectl port-forward`.
- Storage is `emptyDir`, so metrics and logs do not survive a pod restart.
- At the time of these sessions there were no alert rules and no Alertmanager (they came later, see [ADR-0023](adr/0023-slos-and-alerting.md)).
