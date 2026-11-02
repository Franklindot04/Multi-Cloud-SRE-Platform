# Observability on a real cluster

What the metrics, logging and tracing stack looked like when it ran on an EKS cluster. The screenshots were taken over three apply sessions on temporary clusters, which have since been destroyed. The first session brought up everything except Loki and Alloy; the second added them. The third, on 2026-11-02 (Kubernetes 1.37), added tracing, the SLO rules, Alertmanager and the SLO dashboard; its screenshots are in the sections on the SLO dashboard, traces, trace to logs and logs to trace. What the stack is and why it looks like this is in [ADR-0020](adr/0020-metrics-stack.md), [ADR-0021](adr/0021-logging-stack.md), [ADR-0022](adr/0022-tracing-stack.md) and [ADR-0023](adr/0023-slos-and-alerting.md); the procedure is in the [observability runbook](runbooks/observability.md). What the page does not show is listed [at the end](#what-this-page-does-not-show).

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

## SLO dashboard

The SLOs dashboard on 2026-11-02, with the time range Last 30 minutes. The screenshots were taken after an order test and some minutes of normal traffic. The banner at the top of the dashboard says that Prometheus keeps only two days of data, so every 30d figure on it covers at most two days. **The 30d SLI on these screenshots is not a 30-day measurement.**

At the top, the page alerts firing, ticket alerts firing, pending alerts and targets down in `shop` are all 0, and the panel "Alerts firing or pending" says No data, because nothing was firing. Below them is the gateway availability objective: the target is 99.5%, the SLI over the 30d window 100%, the error budget remaining 100%, and the burn rate over 1 hour and over 6 hours 0.

![SLOs dashboard, top: page alerts, ticket alerts, pending alerts and targets down in shop all 0, the alerts panel with No data, and the gateway availability panels with a 99.5% target, 100% SLI, 100% budget remaining and burn rates of 0](images/grafana-08-slo-dashboard-1.png)

The middle part has the chart for gateway availability (the SLI at 100% above the 99.5% target line) and the gateway latency objective, 95% of requests at or under 0.5 s. Its SLI is 96.9% against the 95% target, the error budget remaining is 38.5%, and the burn rate is 0.604 over both 1 hour and 6 hours. The chart for the 6-hour SLI rises from about 96% to about 97% over the 30 minutes shown.

![SLOs dashboard, middle: the gateway availability chart, then gateway latency with a 95% target, 96.9% SLI, 38.5% budget remaining, burn rate 0.604 on 1h and 6h, and a chart of the 6h SLI rising from about 96% to about 97%](images/grafana-08-slo-dashboard-2.png)

The lower part repeats the latency chart and shows the notification delivery objective: 99% target, 100% SLI, 100% budget remaining and burn rates of 0, with the SLI at 100% on its chart.

![SLOs dashboard, bottom: the end of the latency chart and the notification delivery panels with a 99% target, 100% SLI, 100% budget remaining and burn rates of 0, and its chart at 100%](images/grafana-08-slo-dashboard-3.png)

## Traces

One order created through the gateway makes one trace across four services. In Explore with the Tempo data source, the trace `d0e5f3a1c2b44d7e9a1b2c3d4e5f6a7b` is `shop/gateway POST /api/orders` with status 201, started at 2026-11-02 05:12:56.472, lasting 794.71 ms, with 4 services and 15 spans. The overview above the span list shows the spans along the time axis.

![Grafana Explore with Tempo: the trace for shop/gateway POST /api/orders with status 201, 794.71 ms, 4 services and 15 spans, the trace overview and the first rows of the span list](images/grafana-09-trace-view-top.png)

The span list, from the top:

- the gateway request `POST /api/orders` (775.94 ms) and its call `POST orders:8081`;
- the orders request `POST /orders` (773.12 ms) with `db create_order` (32.94 ms);
- under it `platform.events publish` (17.98 ms), which is the first hop through RabbitMQ, with the notifier's `notifier.orders process` and `record notification` inside the same trace;
- the call from orders to payments `POST payments:8082` (719.95 ms), the payments request `POST /payments/authorize` (688.43 ms), `db save_payment` (13.09 ms) and `payments.decide`;
- `db transition_order` (16.84 ms) in orders, then a second `platform.events publish` (5.97 ms), with the notifier's `notifier.orders process` and `record notification` again.

Both RabbitMQ hops are in the same trace. The spans are coloured by service: gateway, orders, notifier and payments.

![Tempo trace, span list: gateway, orders, db create_order, publish to RabbitMQ and the notifier's process and record notification spans, the call to payments with db save_payment and payments.decide, db transition_order and a second publish with the notifier's spans](images/grafana-09-trace-view-bottom.png)

## Trace to logs

From the trace, the Related logs link opens Loki in Explore with a query that selects every namespace and filters the lines by the trace id (the selector `{namespace=~".+"}` and a line filter with the id). The screenshot shows 5 lines displayed, the logs volume with a total of 5 info lines, and the common labels `job=loki.source.kubernetes.pods` and `namespace=shop`. The first line is the notifier's `event recorded` at 05:12:57.267, with its `request_id` and the trace id highlighted.

![Grafana Explore with Loki: the query for the trace id, the logs volume with 5 info lines, 5 lines displayed in the shop namespace and the first line, the notifier event recorded, with the trace id highlighted](images/grafana-10-trace-to-logs-1.png)

Scrolled down, the two lines that fit on the screen are from the notifier and from the gateway. The notifier line is `event recorded` with `event_type` `order.paid`; it has the `trace_id` and also a `traceparent` that holds the same trace id, which came through the RabbitMQ message header. The gateway line is the request log for `POST /api/orders` with status 201. The trace id is highlighted in each. The list at the left shows the stream labels: `app`, `container`, `instance`, `job`, `namespace`, `pod`, `service` and `service_name`.

![Grafana Explore with Loki: the notifier line event recorded with event_type order.paid, trace_id and traceparent highlighted, and the gateway request line for POST /api/orders with status 201 and trace_id highlighted](images/grafana-10-trace-to-logs-2.png)

## Logs to trace

In the other direction, a log line in Loki leads to the trace. The line here is the notifier's `event recorded` at 05:15:11.373, with `event_type` `order.paid` and the `trace_id` `9db71a352f74b8c3bb9863a1c98758e9`; its `traceparent` carries the same trace id. In the log details, under Links, the field `trace_id` has a Trace button (the derived field of the Loki data source). It opens the trace in Tempo inside Grafana, below the log line: `shop/gateway POST /api/orders`, status 201, 537.98 ms, 4 services, 15 spans. This is a second order, not the one in the figures above.

![Grafana Explore with Loki: the notifier event recorded line with trace_id and traceparent, its log details with the Trace link for trace_id, and the trace below it with the gateway as the root, 537.98 ms, 4 services and 15 spans](images/grafana-11-logs-to-trace-1.png)

The same view split into Loki and Tempo. The trace has the gateway as its root span (`POST /api/orders`, 42.1 ms) and the orders request (39.2 ms). Under it are `db create_order` (12 ms), `platform.events publish` with the notifier's spans, the call to payments (10.83 ms), the payments request (6.7 ms) and `db save_payment` (4.52 ms). The trace as a whole lasts 537.98 ms, longer than the gateway request, because it includes the later spans.

![Grafana Explore split into Loki and Tempo: the trace for the log line with the gateway request as root, orders, db create_order at 12 ms, the publish and the notifier's spans, the call to payments and db save_payment at 4.52 ms](images/grafana-11-logs-to-trace-2.png)

## What was observed

**First session.** All applications Synced and Healthy, every Prometheus target up, and three dashboards showing data: Cluster capacity, Sample services and Data layer.

**Second session.** Loki and Alloy started under the restricted Pod Security level with no PersistentVolumeClaim (storage is `emptyDir`), and their Prometheus targets were up. Logs arrived with the labels `namespace`, `pod`, `container`, `app` and `service`, and `level` was available as structured metadata. The Logs dashboard worked, including the search box and the PostgreSQL error view.

**Third session (2026-11-02).** All four services were ready and every Argo CD Application was Synced and Healthy (no screenshot of this session's Argo CD list). All 34 Prometheus targets were up. Prometheus loaded 57 SLO and alert rules, and it discovered Alertmanager. Alertmanager and Tempo ran under the restricted Pod Security level, and the four Grafana data source tests passed (Prometheus, Loki, Tempo and Alertmanager). The SLOs dashboard showed the values in the section above: the availability and notification delivery objectives at 100% with no burn, and the latency objective at 96.9% with 38.5% of the budget left. Tracing was seen end to end: one order created through the gateway made one trace with 15 spans across 4 services, including both hops through RabbitMQ, from the gateway to the notifier's `record notification`. The `Related logs` link from the trace found the log lines of the trace in Loki, and the `Trace` button of the `trace_id` field on a notifier log line opened that line's trace in Grafana.

**Log lines for health and metrics requests have a trace id but no trace.** The request log lines for `/readyz` and `/metrics` also carry a `trace_id`. Their Trace button shows "Could not retrieve trace", because Tempo has no trace for them. We saw that the services do not produce a trace for those routes; we did not check why.

**A Spot node was replaced during the second session.** The PostgreSQL primary and the Valkey pods were rescheduled onto the new node and recovered without anyone doing anything. PostgreSQL is a single instance today, so while its node is gone the database is down until the pod runs again somewhere else; that is what happened here, and it recovered. This is an observation about one event. High availability for PostgreSQL is planned, and nothing here shows that it works.

**Found and fixed during these sessions.**

- The Logs dashboard search put the text inside a double-quoted LogQL string, so a double quote or a backslash in the search broke the query. It now uses a backtick (raw) string.
- The Service dropdown looked as if it lacked PostgreSQL; it was only clipped on screen, and `postgresql` was in the list.
- Teardown needed a second step to get past Argo CD finalizers. It is now scripted in [`scripts/teardown-argocd.sh`](../scripts/teardown-argocd.sh), after `scripts/teardown-prep.sh` and before `terraform destroy`. At the end of the second session both scripts were run on the cluster in that order (`scripts/teardown-argocd.sh` first as a dry run, then for real), `terraform destroy` removed all 54 resources, and the AWS checks afterwards came back empty. `scripts/teardown-prep.sh` had already been run on a cluster in the first session, which is where its problem with a finalizer whose operator was already gone was found and fixed.

**Known limits.**

- In the first two sessions the services were not instrumented with an OpenTelemetry SDK, so the OpenTelemetry Collector received nothing and there were no traces; the services only wrote a `trace_id` into their log lines. The services send traces since the tracing change, and the third session is where that was seen.
- There is no ingress. Everything on this page was viewed through `kubectl port-forward`.
- Storage is `emptyDir`, so metrics and logs do not survive a pod restart.
- In the first two sessions there were no alert rules and no Alertmanager. They came later ([ADR-0023](adr/0023-slos-and-alerting.md)) and ran in the third session, with the limits in the next section.

## What this page does not show

- **A burn-rate alert firing and reaching Alertmanager.** Nothing fired in the third session. Alertmanager has no receivers, so an alert would be recorded there and sent nowhere.
- **The 3-day and 30-day windows filling.** Prometheus keeps two days. The 30d numbers on the SLOs dashboard are not 30-day measurements.
- **The notifier freshness objective.** It needs a handling-time metric, which does not exist.
- **Persistent storage for Prometheus, Loki and Tempo.** All three used `emptyDir`.
- **Why `/readyz` and `/metrics` requests have no trace.** It was seen, not investigated.
