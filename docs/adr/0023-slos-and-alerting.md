# ADR-0023: SLOs and burn-rate alerting

- Status: Accepted
- Date: 2026-11-01

## Context

[ADR-0020](0020-metrics-stack.md) put Prometheus and the dashboards on the cluster and left alerting out: no rules, no Alertmanager, no objectives. [ADR-0005](0005-observability-stack-choice.md) said the platform would evaluate SLOs with recording rules and multi-window burn-rate alerts. This decision defines the objectives for the order flow and the rules that evaluate them, turns Alertmanager on with a routing tree that has nowhere real to send to yet, and adds the runbook the alerts link to ([`docs/runbooks/alerts.md`](../runbooks/alerts.md)) and a dashboard for the objectives.

The constraints are those of the rest of the platform. The traffic is low and uneven: a demo that sits idle for hours and then gets a burst. The nodes are Spot instances, so a pod or a node goes away now and then (one Spot node was replaced during the recorded cluster sessions, and the single PostgreSQL instance was unavailable until its pod ran again, see [the evidence page](../observability-evidence.md)). Prometheus keeps two days of data on an `emptyDir`. The only metrics that can be used are the ones the services expose; none was added for this.

## Decision

The objectives

| SLO | Objective | Window | Error budget |
| --- | --- | --- | --- |
| `gateway-availability` | 99.5% of requests are not server errors | 30 days | 0.5% of requests: 216 minutes of total outage |
| `gateway-latency` | 95% of requests take 0.5 s or less | 30 days | 5% of requests: 36 hours of every request being slow |
| `notifier-delivery` | 99% of order events are recorded, not dead-lettered | 30 days | 1% of events: 1 event in 100 |

The exact SLIs (two PromQL expressions each), what is excluded and the error budget policy are in [`docs/slo`](../slo/README.md): [gateway](../slo/gateway.md) and [notifier](../slo/notifier.md). In short: the operational routes (`/healthz`, `/readyz`, `/metrics`, `/version`) are in no count; client errors (4xx) are in neither the good nor the bad count of availability; the latency threshold is the `le="0.5"` bucket of the shared histogram, a bucket boundary, so the count is exact; a retry of an event is not counted, only its end (recorded, duplicate or dead-lettered).

Why these objectives

- **The gateway is where the order flow is seen.** It is the one entry point, and its 5xx responses include the 502 and 504 it returns when orders or payments fail, so orders and payments are covered through it. There is no separate objective for them: their routes would mostly measure the same requests twice.
- **99.5% availability.** 99.9% would leave 43 minutes a month, which one Spot replacement or one restart of the single PostgreSQL instance can use up. 99.5% leaves 216 minutes, enough for a few such events, and still means that a day-long outage is a clear breach. There is no measured baseline in this repository, so this is a starting point to move up or down once there are weeks of real data.
- **0.5 s at 95% for latency.** Creating an order is a synchronous chain: gateway, orders, payments (timeout 2 s) and the database. 0.5 s is five times the 0.1 s bucket and well below the 2 s and 5 s upstream timeouts, so a request over it is a slow one and not one near its timeout. 95% allows the long tail of the first requests after a pod starts. Again, no baseline exists: compare with the p95 panels of the Sample services dashboard and adjust.
- **99% for notification delivery.** An event ends in the dead-letter queue only after the message is unreadable or fails on every attempt (three by default), so a healthy system should dead-letter almost nothing; 1% is generous enough that a handful of poison messages in a quiet month do not breach it, and tight enough that a broken consumer does.
- **A 30-day window** is the usual compromise between reacting to a change and not forgetting a bad week.

Recording rules

The rules are one `PrometheusRule` named `slo`, rendered by the monitors chart from `slo.slos` in its values, in the `observability` namespace. The naming is `slo:<what>:<unit>[_<window>]`, always with the labels `slo` and `service`:

| Rule | Meaning |
| --- | --- |
| `slo:objective:ratio` | the objective, for example 0.995 |
| `slo:error_budget:ratio` | 1 minus the objective |
| `slo:sli_error:ratio_rate5m` and the same for 30m, 1h, 2h, 6h, 1d, 3d and 30d | bad events divided by valid events over the window (an error ratio, so a burn rate is the value divided by the budget) |
| `slo:sli_events:increase1h` and the same for 6h, 1d and 3d | valid events in the window, for the low-traffic guard |

A window with no valid events has no sample: a quiet service looks neither healthy nor broken, and no alert can fire on nothing. The windows of a day and longer are evaluated every 5 minutes, the others at the Prometheus interval (30 seconds).

Burn-rate alerts

The scheme is the one from the Google SRE Workbook (multiple windows, multiple burn rates). A burn rate is the error ratio divided by the error budget; 1 spends the budget exactly over the window. Each alert needs the error ratio above burn times budget over a long window and over a short window, so it fires when the problem is real and stops soon after it ends.

| Alert | Severity | Burn rate | Long window | Short window | Budget spent in the long window |
| --- | --- | --- | --- | --- | --- |
| `SLOBurnRatePageFast` | page | 14.4 | 1h | 5m | 2% |
| `SLOBurnRatePageSlow` | page | 6 | 6h | 30m | 5% |
| `SLOBurnRateTicketFast` | ticket | 3 | 1d | 2h | 10% |
| `SLOBurnRateTicketSlow` | ticket | 1 | 3d | 6h | 10% |

Each SLO has all four, labelled with `slo`, `service` and `severity`. The thresholds follow from the budget: for gateway availability (0.5%) they are 7.2%, 3%, 1.5% and 0.5% of requests failing; for gateway latency (5%) 72%, 30%, 15% and 5% of requests slow; for notification delivery (1%) 14.4%, 6%, 3% and 1% of events dead-lettered. The page alerts wait 2 and 5 minutes before firing and the ticket alerts 15, to ride out a flap. Every alert has a `summary`, a `description` that says what the rate means for the budget, and a `runbook_url` that points at `docs/runbooks/alerts.md` with an anchor into the [alert runbook](../runbooks/alerts.md), which has one section for each. The anchors are `slo-burn-rate-page-fast`, `slo-burn-rate-page-slow`, `slo-burn-rate-ticket-fast`, `slo-burn-rate-ticket-slow`, `service-target-down`, `notifier-broker-disconnected` and `outbox-backlog`.

The low-traffic guard

With a few requests an hour, one failed request is an error ratio of tens of percent and would trip every threshold. Each burn-rate alert therefore also needs `events x burn x budget >= 5`, where events is `slo:sli_events:increase` over the long window: at the alert's own threshold, at least 5 bad events. The number 5 is the smallest that still means "more than a coincidence" here, and it is one value (`slo.minBadEvents`) in the chart. The minimum number of valid events in the long window that follows from it:

| SLO | PageFast (1h) | PageSlow (6h) | TicketFast (1d) | TicketSlow (3d) |
| --- | --- | --- | --- | --- |
| gateway-availability (budget 0.5%) | 70 | 167 | 334 | 1,000 |
| gateway-latency (budget 5%) | 7 | 17 | 34 | 100 |
| notifier-delivery (budget 1%) | 35 | 84 | 167 | 500 |

So an idle demo with three requests an hour never alerts, and thirty failing requests an hour can raise the slow page alert (180 requests in 6h, above 167) but not the fast one (30 in 1h, below 70). The guard is measured on the events in the window, not on the length of the data, so after a restart it also holds the alerts back until there are enough events. The price is that a real outage at very low traffic is not noticed by the SLO alerts: the alerts below are for that.

Alerts for what the SLOs cannot see

An SLO is built from counts, so a service that serves nothing produces no burn. Three alerts cover the cases where the counts stop, with a severity and a runbook anchor each:

- `ServiceTargetDown` (page): a scrape target of the four services in `shop` has been down for 5 minutes. If the gateway itself is down there are no requests to fail.
- `NotifierBrokerDisconnected` (ticket): `amqp_connected` has been 0 for 10 minutes; events wait in the queue and `notifier-delivery` sees none of them.
- `OutboxBacklog` (ticket): the oldest unpublished order event is more than 5 minutes old for 10 minutes; the notifier receives nothing, so the notification objective shows no failures.

The three carry the label `service` as well (for `ServiceTargetDown`, the `job` of the target), which the grouping and the inhibitions below use. Nothing else is alerted on. Prometheus's own alerts (a target down in the cluster, the API server, nodes) would come from the stack's default rules, but those are off in this profile (`defaultRules.create: false`, the chart's rules and dashboards go together), so they do not exist here and are not duplicated.

Alertmanager

Alertmanager is on, from the same chart as Prometheus (kube-prometheus-stack, Alertmanager v0.34.2): one replica, no volume (the operator uses an `emptyDir`, so silences and the notification log are lost when the pod is rescheduled; `values-persistent.yaml` adds a 1 GiB claim), requests of 10m CPU and 32Mi memory with limits of 100m and 64Mi, plus the 10m and 24Mi of its config reloader. It runs as user 1000, non-root, with the default seccomp profile. The operator is expected to give its containers a read-only root filesystem, no privilege escalation and no capabilities (as it does for Prometheus); that happens at run time and cannot be checked offline, so it is on the list of what has not been seen. Prometheus sends its alerts to it (the chart wires `spec.alerting`), Grafana reads it through a data source with the fixed uid `alertmanager`, and its own metrics are scraped. There is no ingress: it is reached by port-forward, like Grafana and Prometheus.

- **The routing tree.** Alerts are grouped by `alertname`, `slo` and `service`. The root route goes to the receiver `default` (wait 30 s, interval 5 m, repeat 12 h). Severity `page` goes to the receiver `page` (wait 10 s, interval 2 m, repeat every hour while it lasts); severity `ticket` goes to `ticket` (wait 2 m so a flapping alert is one entry, interval 15 m, repeat once a day). Everything else, including any alert without a severity, goes to `default`.
- **The receivers are empty.** `default`, `page` and `ticket` take an alert and send it nowhere: the alert is visible in the Alertmanager UI, in the Prometheus Alerts page and on the SLO dashboard. There is no notification channel and no secret in the repository, and a placeholder address that looks real would be worse than none, so none is written. The contract check `alertmanager` fails if a receiver is not empty or if the configuration holds anything that looks like a URL, token or password.
- **How a real receiver is added later.** Keep the routing in Git and the address out of it: create the Secret that holds the address in the cluster, list it in `alertmanagerSpec.secrets` so that it is mounted under `/etc/alertmanager/secrets/<name>/`, and let the receiver read it with `url_file`. The change then also relaxes the contract check to allow `url_file` and nothing else. The runbook ([observability](../runbooks/observability.md#adding-a-real-receiver-later)) says the same.
- **Inhibitions.** A page alert hides the ticket alerts with the same `slo` and `service`, because the page alert already says it. `ServiceTargetDown` hides the burn-rate alerts (`SLOBurnRate.*`) with the same `service`: a service that cannot be scraped fails requests for that reason, and the alerts about the failures add nothing. The second works for a service that the burn is *about*, not for a failure it causes elsewhere: when `orders` is down the gateway burns, and the alert for `service="gateway"` is not hidden by the alert for `orders`. That is intended: the gateway alert is the customer's symptom.
- **No Watchdog.** An always-firing alert is useful only when something outside the cluster watches for it to stop (a dead man's switch). There is nothing outside the cluster to send it to, and a permanent alert would sit in every list and on the dashboard. The check that alerts reach the UI is a test alert posted by hand (runbook).
- **No default rules, still.** The chart's default rules come in groups (for example `kubernetesApps` or `kubernetesSystem`), not one alert at a time, and bring dozens of alerts and the recording rules they use, several for components this platform does not run (the control plane, kube-proxy, node-exporter). The chart can disable single alerts by name (`defaultRules.disabled`), but a list of names is tied to the chart version and would have to be re-read at every upgrade. Pod crash looping and node not ready are the two worth having; they are not enabled here and are the first candidates for a small rule of their own in the monitors chart, with a test, once the cluster has run with this setup.
- **The configuration is a Secret, so the AppProject allows Secrets.** The operator reads the Alertmanager configuration from a Secret, which the chart renders from the values. The `platform-observability` AppProject did not allow the kind Secret (the Grafana password is generated in the cluster and never was a manifest in Git); it now does, with a comment, and the contract check keeps credentials out of what the Secret holds. An existing cluster needs `scripts/bootstrap-argocd.sh` run again so that the AppProject is updated. The alternative, a Job that copies the configuration from a ConfigMap into a Secret in the cluster, would keep the AppProject as it was at the price of a Job and an ordering problem for a configuration that has no secret in it.

The dashboard and the runbook

- **The SLO dashboard** (`sre-slos`, in the dashboards chart like the others) shows for each SLO the target, the SLI, the error budget left and the burn rate over 1 h and 6 h, and the SLI over time with the target as a flat line, plus the alerts firing or pending (from the `ALERTS` series) and targets down. Every query is made of the recording rules above, so the dashboard and the alerts agree by construction, and the dashboard check fails if a query uses a name that is neither a service metric nor a rule the monitors chart renders. The top of the page says that Prometheus keeps two days, so the 30 day numbers are partial. It uses only the panel types of the other dashboards (stat, timeseries, table, row).
- **The alert runbook** is [`docs/runbooks/alerts.md`](../runbooks/alerts.md): the severities, how to open Alertmanager, silences and their limits, then one section for each alert with what it means, the user impact, how to confirm it, the causes likely on this platform, what to do first, when to escalate and how to tell it has recovered. The checks do not read it, so the anchors are listed above and in the rules; a rule whose `runbook_url` does not end in `docs/runbooks/alerts.md#<anchor>` fails the contract check.

Where the rules live and how they are tested

The rules are a template of the existing monitors chart, because the monitors chart is the one that already holds the Prometheus custom resources of the platform, is deployed by its own Argo CD ApplicationSet (`observability-monitors`, wave 13) and is selected by Prometheus: the stack sets `ruleSelectorNilUsesHelmValues: false`, so every `PrometheusRule` in every namespace is loaded and no release label is needed. The objectives, targets, burn rates and the guard are values, so a change of a target is a change of one number plus its documentation.

- **Unit tests** in `platform/observability/monitors/tests/slo-rules.test.yaml`, run with `promtool test rules`: the recording rules for a case worked by hand; a service inside its budget (no alert); a total outage that pages in 25 minutes, ends, and clears in the order the windows predict (page alerts first, tickets hours later); a constant 4x burn that raises tickets only; a 10x burn that raises the slow page alert but not the fast one; a 20x burn that raises all four; traffic too low to alert, and traffic that passes the guard in the long windows only; a 4x latency burn; the notification objective; the text of one alert in full; and the three alerts above.
- **A contract check** (`slo-rules` in `scripts/chart-contract-check.py`, run by `scripts/observability-check.sh` on the rendered chart) that fails if an SLO lacks a window, the objective and budget do not add up to 1, an alert has a window or burn rate other than the four above, the guard is missing or below 3, an annotation or a runbook link of the right shape is missing, a metric is not defined in the service code, an operational route is not excluded, or the latency threshold is not a bucket boundary. `scripts/test-scripts.sh` tests the check with a good rendering and eighteen broken ones.
- **`promtool check rules --lint-fatal`** on the rendered rules.

promtool comes from the Prometheus image the stack deploys (`quay.io/prometheus/prometheus` v3.15.1, the same tag the Prometheus resource uses), started with `--entrypoint /bin/promtool`. The unit test file lists the order in which the rule groups are evaluated (`group_eval_order`): without it promtool evaluated them in an arbitrary order, and because the test interval of 5 minutes equals the look-back, an alert sometimes read a recorded series that had not been written yet and the same test passed or failed from run to run. Prometheus evaluates every 30 seconds and does not depend on the order.

## Consequences

- **Alerts are evaluated and recorded, and delivered nowhere.** A firing alert reaches Alertmanager and is routed to a receiver that sends nothing, so someone has to look: at the Alertmanager UI, the Prometheus Alerts page or the SLO dashboard. Nothing pages anyone until a real receiver is added. The new Alertmanager pod adds 20m and 56Mi to the requests of the stack, which now total 515m and 1560Mi (recomputed from the rendered charts), and the Prometheus alerts for Alertmanager itself (it is down, it fails to send) do not exist, because those are default rules.
- **Prometheus keeps two days of data,** so the 3-day and 30-day windows cannot be filled. `rate` and `increase` work over the samples that exist, so the 3d windows behave like a window of about two days (the slow ticket alert needs `events` of the same data and may fire sooner than designed), and the 30-day error ratio is really the ratio of the last two days. The 30-day budget cannot be read from this Prometheus. To make the windows true, the retention (and the volume, `values-persistent.yaml`) must be raised to at least 30 days, with the size that costs, or the data kept elsewhere. This is the biggest gap.
- **The latency SLI includes failed requests.** The shared histogram has no status label, so a fast 500 counts as a good request and a slow one as a bad one. A slow outage therefore shows in both objectives; a fast one only in availability.
- **No freshness objective.** The notifier exposes no handling-time or event-age metric. `notifier-delivery` says whether events end up recorded, not how soon. A histogram of the time from publish to record in the notifier would allow a "95% within 30 seconds" objective.
- **The objectives are guesses.** The targets rest on reasoning about the platform and not on measured data. Treat the first month as calibration: read the error ratios from the recording rules, then move the targets.
- **A missing target is not caught.** `ServiceTargetDown` fires on a target that is down. A Service that selects no pod has no target and raises nothing (an `absent` alert would, at the price of firing on clusters without the services).
- **One `PrometheusRule`, one place to edit.** The expressions are in the values file as text with a window placeholder, so a typo in one is found by the unit tests or the contract check and not by the YAML schema.

## What this does not cover

- A receiver that sends anywhere, the on-call tool, and a dead man's switch (see above).
- High availability of Alertmanager: one replica, so alerts are lost while it restarts and its silences with them.
- Alerts on Alertmanager itself (down, failing to send) and on the rest of the observability stack.
- A dashboard of the alert history: the `ALERTS` series covers what Prometheus keeps, two days.
- Objectives for orders and payments on their own, for the data layer (PostgreSQL, RabbitMQ, Valkey), for the platform itself, or end to end from outside the cluster (no probe or synthetic request exists).
- A freshness or latency objective for the notifier (no metric).
- An objective per route. The gateway objectives pool the business routes.
- Alerts on the budget remaining (as opposed to its burn), on the observability stack itself, and on missing data from the rules.
- Retention long enough for the 30-day window (above).

## What has been exercised

Run on a laptop: `helm lint --strict` and `helm template` of the monitors chart and `kubeconform` of the `PrometheusRule` against the CRD catalog (through `scripts/addons-check.sh`); the AppProject check (a `PrometheusRule` in the `observability` namespace is allowed); the `slo-rules` contract check on the rendered rules; `promtool check rules --lint-fatal` (57 rules) and `promtool test rules` with promtool 3.15.1 from the image the stack deploys, with the unit tests described above; `scripts/test-scripts.sh` with its good and bad cases. To see that the unit tests can fail, the rules were changed three ways by hand (the fast page burn rate raised to 30 and lowered to 8, the guard removed, a bucket changed) and each change made the tests fail.

Run on a laptop for Alertmanager: the stack renders with Alertmanager under the `restricted` check (one replica, requests and limits, no volume, no ingress, Prometheus wired to it, a Secret with the configuration); the configuration passes `amtool check-config` of the Alertmanager image the stack deploys; `amtool config routes test` sends a page alert to `page`, a ticket alert to `ticket` and alerts with another severity or none to `default`; an Alertmanager started from that image with that configuration (read-only root filesystem, no capabilities, non-root) was sent six alerts through its API, and a page alert hid the ticket alert of the same SLO and service, `ServiceTargetDown` hid the burn-rate alert of the same service, and the other alerts went to their receivers; the `alertmanager` contract check refuses eighteen broken configurations in the script tests; the datasource check covers the Alertmanager data source; the SLO dashboard passes the dashboard checks (valid JSON, unique uid and title, the data source variable, every query built from a service metric, a recording rule or `ALERTS`); and the links and anchors of the runbook resolve. The sizing was recomputed from the rendered charts.

Not run, because it needs a cluster:

- Prometheus loading the `PrometheusRule` through the operator, and the rules evaluating against the real metrics. In particular the `service` label of the series is assumed to be the one the services expose (the Sample services dashboard uses it the same way and showed data on the recorded cluster), and `le="0.5"` is assumed to be written that way by the Go client.
- An alert firing and its state in the Prometheus UI, and in Alertmanager and on the dashboard.
- The Alertmanager pod running under `restricted` on a cluster, with the container settings the operator adds, Prometheus listing it as active, and the Grafana data source and the SLO dashboard rendering.
- The Argo CD sync of the changed AppProject and of the Secret.
- The cost of the 3-day and 30-day rules on a Prometheus with two days of data.
- The synchronisation of the Application with the new resource (wave 13, after the CRDs).

## Alternatives considered

- **Sloth or Pyrra** (generators of SLO rules from an SLO definition), which ADR-0005 mentioned. They produce the same kind of rules and add a controller or a command to maintain; with three SLOs a template and a values file are less to run, and the tests are written against the rules whichever way they are made. A move to one of them later would keep the names of the recorded series.
- **The AlertmanagerConfig resource instead of the chart's configuration Secret.** It would need no Secret in the AppProject, but the operator adds a `namespace` matcher to every route and inhibition of such a resource, and the alerts of this platform come from series of several namespaces, so the routes would not match as written.
- **Success ratios instead of error ratios.** The usual dashboards show availability as a success ratio, but burn rates are the error ratio divided by the budget, so recording the error ratio makes the alerts and the checks simple. A success ratio is one minus the recorded value.
- **One alert name for all SLOs, with the SLO in a label (chosen), or a set of alerts per SLO.** The name and anchor stay the same across SLOs, and the runbook has four burn-rate entries instead of twelve.
- **A request-count guard in absolute terms** (for example 100 requests in the window for every alert). Simpler to explain, but it ignores that a 3-day window at 1x burn needs far more events than a 1-hour window at 14.4x for the same meaning. The guard here is derived from the burn and the budget.
- **Alerting on the 30-day ratio alone.** It reacts in days. The multi-window scheme exists to react in minutes to a fast burn and still notice a slow one.
- **Probes from outside the cluster** (blackbox-style) for availability. They would see what a client sees, including the ingress, but there is no ingress today and no probe infrastructure.
