# Alerts

What to do when an alert of the platform fires. One section for each alert; the alerts link here by their anchor. The rules are in [`platform/observability/monitors`](../../platform/observability/monitors), the reasoning in [ADR-0023](../adr/0023-slos-and-alerting.md), the objectives in [`docs/slo`](../slo/README.md), and the setup of Alertmanager in the [observability runbook](observability.md#alerts).

**Nothing pages anyone yet.** There is no real notification channel: Alertmanager records alerts and sends them nowhere. Someone has to look at it. Open the **SLOs** dashboard in Grafana (uid `sre-slos`) or the Alertmanager UI (below) to see what is firing.

## Read this first

- **Page** means the error budget is burning fast, or a service cannot be reached. Act now. Stop rollouts until you know why.
- **Ticket** means a slow burn or a part that is broken but not yet hurting users. Look at it in working hours. Put the fix ahead of feature work.
- A page alert for an SLO hides the ticket alerts of the same SLO and service. `ServiceTargetDown` hides the burn-rate alerts of the same service. If a ticket alert is missing, look for a page alert first.
- The alerts are only as good as the traffic. With a few requests an hour the burn-rate alerts stay quiet on purpose (the minimum-traffic guard, see the ADR). An outage at very low traffic shows up as `ServiceTargetDown`, not as a burn.
- Prometheus keeps two days of data here. The 3-day alert (`slo-burn-rate-ticket-slow`) and the 30-day numbers on the dashboard cover at most two days.

### Open Alertmanager

```bash
kubectl --context <CTX> -n observability port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
```

Open <http://localhost:9093>. The Alerts tab lists what is firing and the receiver it was routed to (`page`, `ticket` or `default`). Tick `Inhibited` to see the alerts that were hidden. The Prometheus page <http://localhost:9090/alerts> (port-forward `svc/kube-prometheus-stack-prometheus 9090:9090`) shows the same alerts with the expression and how long they have been pending.

### Silence an alert

In the Alertmanager UI: `Silence` next to the alert, set a short time (hours, not days), put your name and the reason in the comment. From the command line:

```bash
amtool --alertmanager.url=http://localhost:9093 silence add alertname=OutboxBacklog --duration=2h --author=<you> --comment="<why>"
```

A silence hides the alert in the UI and stops it reaching a receiver. It does not fix anything and it does not stop the rule: the alert is still firing in Prometheus. Limits:

- Silences live in the Alertmanager pod's memory and disk, which is an `emptyDir`. A restart or a reschedule of the pod, for example when a Spot node is replaced, removes every silence.
- A silence matches labels. A silence on `alertname` and `service` also hides the same alert for the next incident until it ends.
- Do not silence a page alert to get some sleep unless you have looked at the cause. If the budget is burning, silencing it only hides that.

### Look at the objectives

The **SLOs** dashboard shows, for each objective, the target, the SLI, the error budget left and the burn rate over 1 hour and 6 hours. The **Sample services** dashboard shows the request rate, the 5xx share and the latency by service and by route. The **Data layer** dashboard shows PostgreSQL, RabbitMQ, the outbox and the dead-letter counts. The **Logs** dashboard shows the log lines; a request ID or trace ID from a log line finds every line of that request.

The error budget policy is in [`docs/slo/gateway.md`](../slo/gateway.md#error-budget-policy) and [`docs/slo/notifier.md`](../slo/notifier.md#error-budget-policy).

## SLO burn-rate alerts

The four burn-rate alerts exist for each of the three objectives: `gateway-availability`, `gateway-latency` and `notifier-delivery`. The label `slo` says which. They differ in how fast the error budget is burning. The steps are the same for each, so read the part that matches the `slo`.

**First, for every burn-rate alert:**

1. Open the SLOs dashboard. Find the row of the `slo` in the alert. Is the burn rate still high, or has it already come down?
2. Find what is failing. Which route, which service, since when? The Sample services dashboard, panels `5xx responses per second by route` and `Latency p95 by route`.
3. Check what changed: a rollout (`kubectl --context <CTX> -n argocd get applications | grep apps-`), a Spot node replaced (`kubectl --context <CTX> get nodes`; a node younger than the incident), a restart of PostgreSQL or RabbitMQ.

### What to check for each SLO

**`gateway-availability` (requests that fail with a 5xx).** The gateway returns 502 when it cannot reach orders or payments, 504 when they are too slow, and 5xx of its own when it is broken.

```bash
kubectl --context <CTX> -n shop get pods
kubectl --context <CTX> -n shop logs deployment/gateway --tail=50
```

Which status? In Prometheus: `sum by (status) (rate(http_requests_total{service="gateway", status=~"5.."}[5m]))`. 502 and 504 point at orders or payments: `kubectl --context <CTX> -n shop port-forward svc/orders 8081:8081`, then `curl -s localhost:8081/readyz` names the failing check (`postgres`, `payments`). A 500 from orders with a ready PostgreSQL is a bug: read the orders log.

**`gateway-latency` (requests slower than 0.5 seconds).** Which route is slow: `histogram_quantile(0.95, sum by (le, route) (rate(http_request_duration_seconds_bucket{service="gateway"}[5m])))`. Then walk down the chain: orders, payments, the database. The Data layer dashboard panels `Query latency p95 by operation` and `Connection pool` show a slow or exhausted database. A node under CPU pressure slows every pod on it: the Cluster capacity dashboard.

**`notifier-delivery` (events dead-lettered).** Events that end in the dead-letter queue are either unreadable (orders published something the notifier cannot use) or failed on every attempt. Count them: `sum by (result) (increase(messages_consumed_total[1h]))`. Read why: [Dead-letter queue: inspect and replay](data-layer.md#dead-letter-queue-inspect-and-replay); the reason is in the message headers (`x-failure-reason`). Notifier log: `kubectl --context <CTX> -n shop logs deployment/notifier --tail=100`, lines with `giving up on event` or `poison message`.

### slo-burn-rate-page-fast

**What it means.** The error budget is burning at 14.4 times the allowed rate or faster, over the last hour and the last 5 minutes. At that speed the whole 30-day budget would be gone in about 2 days. For `gateway-availability` that is 7.2% of requests failing; for `gateway-latency`, 72% of requests slow; for `notifier-delivery`, 14.4% of events dead-lettered.

**User impact.** Real and current. For the gateway, a large part of the requests of customers fail or are slow right now. For the notifier, notifications are not being recorded.

**Confirm it.** The SLOs dashboard, row of the `slo`: burn rate 1h above 14.4. In Prometheus: `slo:sli_error:ratio_rate5m{slo="<slo>"}` and `slo:sli_error:ratio_rate1h{slo="<slo>"}` are both above 14.4 times `slo:error_budget:ratio{slo="<slo>"}`.

**Likely causes on this platform.**

- A Spot node was replaced and a single-instance PostgreSQL is down until its pod runs somewhere else. Orders is not ready; the gateway returns 502. Check `kubectl --context <CTX> -n data get cluster.postgresql.cnpg.io platform-pg` and `kubectl --context <CTX> -n data get pods`.
- The orders or payments pods were restarted or are `Pending` after a node loss: `kubectl --context <CTX> -n shop get pods`.
- A bad rollout. `kubectl --context <CTX> -n argocd get applications | grep apps-` and the revision of the last sync.
- RabbitMQ unreachable (notifier): see [notifier-broker-disconnected](#notifier-broker-disconnected).
- A fault injection left on (`FAULT_INJECTION_ENABLED`) in a service: `kubectl --context <CTX> -n shop get deployment gateway -o yaml | grep -A1 FAULT`.

**Do first.** Find which service is failing (steps above) and make it work again: wait for the node and the database if it is a replacement, restart a stuck pod, or roll back the last release ([Roll back](service-deployment.md#roll-back)). Do not scale or tune anything before you know the cause.

**Escalate** if it is not clearly recovering within 30 minutes, if the cause is the data layer and PostgreSQL does not come back (see the [data layer runbook](data-layer.md#troubleshooting)), or if you cannot find the cause.

**Recovered when.** The burn rate over 5 minutes is below 14.4 (the alert clears first, within minutes), and the 1h burn rate falls below 1 within about an hour. The ticket alerts can stay for hours after: they cover longer windows.

### slo-burn-rate-page-slow

**What it means.** The budget is burning at 6 times the allowed rate or faster, over the last 6 hours and the last 30 minutes. At that speed the whole budget is gone in about 5 days. For `gateway-availability` that is 3% of requests failing; for `gateway-latency`, 30% slow; for `notifier-delivery`, 6% dead-lettered.

**User impact.** A steady, smaller problem: some requests fail or are slow, for hours already. Less sharp than the fast page alert, but it will exhaust the budget within days.

**Confirm it.** As for the fast alert, with `ratio_rate6h` and `ratio_rate30m` above 6 times the budget. The graph `SLI over time and the target` on the SLOs dashboard shows whether it is flat or getting worse.

**Likely causes on this platform.** One route or one dependency that fails part of the time: an intermittent database connection problem (Data layer dashboard, `Connection pool`), a payments decline-or-timeout pattern, a replica that is unhealthy (two gateway replicas: one pod failing readiness), a slow node. For the notifier: a producer bug dead-lettering one kind of event.

**Do first.** Find the failing route or pod with the steps above. If one pod is bad, delete it (`kubectl --context <CTX> -n shop delete pod <name>`) and watch the burn fall. If it follows a release, roll back.

**Escalate** if the burn is not falling after a fix, or if you cannot name the route or the dependency within an hour.

**Recovered when.** The 30 minute window drops below 6 times the budget (the alert clears within minutes of the fix), and the dashboard burn rate 6h trends down.

### slo-burn-rate-ticket-fast

**What it means.** The budget is burning at 3 times the allowed rate or faster, over the last day and the last 2 hours. At that speed the budget is gone in about 10 days. For `gateway-availability` that is 1.5% of requests failing; for `gateway-latency`, 15% slow; for `notifier-delivery`, 3% dead-lettered.

**User impact.** A small share of requests is affected, for a day. Users may notice some failures; nothing is down.

**Confirm it.** `slo:sli_error:ratio_rate1d{slo="<slo>"}` and `ratio_rate2h` above 3 times the budget. If the page alert for the same `slo` is also firing, this one is hidden: handle the page alert.

**Likely causes on this platform.** A flaky dependency, a recurring job or a restart loop (`kubectl --context <CTX> -n shop get pods`: a high `RESTARTS` count), one bad route, a misconfigured timeout (`UPSTREAM_TIMEOUT_MS`, `PAYMENTS_TIMEOUT_MS`), or a Spot node that was replaced during the day.

**Do first.** The same investigation as for the page alerts, without the hurry. Write down the cause. If it is a known, accepted pattern (for example a node replacement that used part of the budget), say so on the ticket and decide whether the target or the platform should change.

**Escalate** if the cause is unknown after the working day, or the burn rate is rising.

**Recovered when.** The 2 hour window falls below 3 times the budget (the alert clears), and the SLO row on the dashboard shows the burn rate near or below 1.

### slo-burn-rate-ticket-slow

**What it means.** The budget is burning at exactly the allowed rate or faster, over the last 3 days and the last 6 hours: at this speed the budget is used up by the end of the 30 days. For `gateway-availability` that is 0.5% of requests failing; for `gateway-latency`, 5% slow; for `notifier-delivery`, 1% dead-lettered. **Prometheus keeps two days here, so this alert looks at about two days, not three.**

**User impact.** Small and long: a background level of errors or slowness that is acceptable day to day but, kept up, uses the whole budget.

**Confirm it.** `slo:sli_error:ratio_rate3d{slo="<slo>"}` and `ratio_rate6h` above the error budget `slo:error_budget:ratio{slo="<slo>"}`. On the dashboard, `Error budget remaining` is dropping.

**Likely causes on this platform.** The target may be too tight for what the platform does: single-instance PostgreSQL and Spot nodes mean a few minutes of failures after every node replacement. Otherwise a low-grade bug or a dependency timing out now and then.

**Do first.** Look at the SLI over time: are there a few clear spikes (node replacements, rollouts) or a constant trickle? Spikes: decide if the cost is acceptable and, if so, change the objective in a reviewed change rather than silencing the alert. Trickle: find it in the logs by route and status.

**Escalate** if the budget would be exhausted this month and no fix is planned: that is a decision for whoever owns the objective.

**Recovered when.** The 6 hour window drops below the budget rate (the alert clears); the 3 day window clears over the next days.

## Alerts for what the SLOs cannot see

### service-target-down

**What it means.** Prometheus has not been able to scrape one of `gateway`, `orders`, `payments` or `notifier` in the `shop` namespace for 5 minutes. The label `job` (and `service`) says which, `instance` the pod address.

**User impact.** Depends on the service. If it is `gateway`, nothing can reach the order API and the burn-rate alerts cannot fire (no requests, no failures). For the others the gateway returns errors, and the burn-rate alerts of the other services are hidden while this one fires for the same service.

**Confirm it.**

```bash
kubectl --context <CTX> -n shop get pods -o wide
kubectl --context <CTX> -n shop describe pod <pod>
```

In Prometheus, Status, Targets: the error on the target (`connection refused`, timeout, 404 on `/metrics`). The query `up{namespace="shop"}` shows which are 0.

**Likely causes on this platform.** The pod is down or not ready after a Spot node replacement (`Pending` because the nodes are full, or still starting); a crash loop (`kubectl logs --previous`); the image cannot be pulled; the Service lost its endpoints (`kubectl -n shop get endpoints <service>`); or only the metrics path is broken while the service works (a `curl` through a port-forward to `/healthz` answers).

**Do first.** Get the pod running: `Pending` with `Insufficient cpu` means the nodes are full (see the capacity paragraph in [ADR-0020](../adr/0020-metrics-stack.md)); `CrashLoopBackOff` means read the previous log; `ImagePullBackOff` see [Troubleshooting](service-deployment.md#troubleshooting). Then check that requests succeed: port-forward to the gateway and create a test order ([Verify](service-deployment.md#verify)).

**Escalate** if the pod cannot start within 15 minutes, or the node group cannot add a node.

**Recovered when.** `up` is 1 for the target and the alert clears after the next evaluation. The burn-rate alerts that were hidden come back by themselves if the problem is still there.

### notifier-broker-disconnected

**What it means.** The notifier has had no connection to RabbitMQ for 10 minutes (`amqp_connected` is 0). It consumes nothing. Events wait in the queue; the notification objective sees none of them, so it does not burn.

**User impact.** Order notifications are late. They are not lost: the queue keeps them, and the notifier consumes them when it reconnects. If the broker itself lost data, events could be lost.

**Confirm it.**

```bash
kubectl --context <CTX> -n data get rabbitmqcluster platform-mq
kubectl --context <CTX> -n data get pods
kubectl --context <CTX> -n shop logs deployment/notifier --tail=50
```

The notifier log says `rabbitmq session ended, reconnecting` and the error. The Data layer dashboard, panel `Notifier connected to the broker` and `Broker metrics endpoint up`.

**Likely causes on this platform.** The RabbitMQ pod was rescheduled (a Spot node was replaced) and is starting; the broker is unreachable or refusing the credentials (the Secret `rabbitmq-auth` in `shop` is missing or out of date: `kubectl -n shop get secret rabbitmq-auth`; the generator Jobs are described in the [data layer runbook](data-layer.md#troubleshooting)); the notifier runs in the memory profile (`MESSAGING=http`) and has no broker at all, in which case this alert has no series and cannot fire.

**Do first.** If `platform-mq` is not ready, wait for the pod and the volume; if it stays down, follow the data layer runbook. If the broker is fine, restart the notifier pod (`kubectl --context <CTX> -n shop delete pod <notifier pod>`) and read why it failed to connect.

**Escalate** if the broker does not come back in 30 minutes or reports data loss.

**Recovered when.** `amqp_connected` is 1, `consumer_queue_messages{queue="main"}` falls to 0, and the alert clears. Then check the dead-letter count did not rise.

### outbox-backlog

**What it means.** The oldest order event in the orders outbox table has waited more than 5 minutes to be published (`outbox_oldest_unpublished_age_seconds`), for 10 minutes. Orders writes an event with the order change and a relay publishes it to RabbitMQ; the relay is not keeping up or cannot publish. The notifier receives nothing, so the notification objective shows no failures.

**User impact.** Orders are created and paid as normal. The notifications for them are late. Events are not lost: they stay in the table and are published in order when the relay works again.

**Confirm it.** The Data layer dashboard: `Outbox backlog`, `Outbox lag`, and `Messages published by result` (a rising `error`).

```bash
kubectl --context <CTX> -n shop logs deployment/orders --tail=100
```

Lines `outbox publish failed, will retry` with `retry_in_s` say the relay is backing off; the `error` names the failure type.

**Likely causes on this platform.** RabbitMQ is down or unreachable (then `notifier-broker-disconnected` is also firing); orders cannot publish because a queue does not exist for the routing key (the broker rejects an unroutable message: the notifier declares the queues, so a notifier that never started leaves none); the orders pod is stuck or restarting; PostgreSQL is slow.

**Do first.** Fix the broker first (see above). If the broker is fine, read the orders log for the error, restart the orders pod if the relay loop is stuck, and make sure the notifier has started once (it declares the exchange bindings). Nothing has to be done to the table: the relay catches up by itself. See [Stuck or growing outbox](data-layer.md#stuck-or-growing-outbox).

**Escalate** if the lag keeps growing after the broker is healthy.

**Recovered when.** `outbox_oldest_unpublished_age_seconds` drops to 0, `outbox_unpublished_events` falls, and the alert clears after the next evaluation.

## After an incident

- Write down what happened, the time, the cause and what you did, in `docs/postmortems` if it used a good part of the budget.
- Check the error budget on the SLOs dashboard. If it is below zero, the policy in `docs/slo` applies.
- If an alert was noisy, or silent when it should have fired, change the rule or the target in a reviewed change. The rules are tested ([ADR-0023](../adr/0023-slos-and-alerting.md)): add a case to `platform/observability/monitors/tests/slo-rules.test.yaml`.
