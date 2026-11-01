# Gateway SLOs

The gateway is the only entry point of the order flow, so these two objectives describe what a customer of the order API sees. Why these numbers, the burn-rate scheme and what is not covered are in [ADR-0023](../adr/0023-slos-and-alerting.md). The rules are in [`platform/observability/monitors`](../../platform/observability/monitors) (values `slo.slos`, template `slo-rules.yaml`); the numbers here are those values, and the checks in `scripts/observability-check.sh` fail if the rules drift from the shape described there. The targets are a starting point: tune them from the data once the platform has run for a while.

Data source: Prometheus, from the gateway's `/metrics` (`http_requests_total` and `http_request_duration_seconds`, [`apps/README.md`](../../apps/README.md)). Window: 30 days, rolling. Excluded from every count: the routes `/healthz`, `/readyz`, `/metrics` and `/version`.

## Availability: gateway-availability

| | |
| --- | --- |
| Objective | 99.5% of requests are not server errors, over 30 days |
| Error budget | 0.5% of requests; with traffic that does not change, 216 minutes of a total outage in 30 days (43,200 minutes x 0.005) |
| Good event | a response with any status that is not 4xx or 5xx |
| Bad event | a response with a 5xx status (including the 502 and 504 the gateway returns when orders or payments fail or time out) |
| Not counted | client errors (4xx): neither good nor bad, so a burst of bad requests from a client cannot hide server failures or consume the budget |

The SLI, as the ratio of two expressions (the rules use these with `rate` for the ratios and `increase` for the event counts):

```text
bad   sum(rate(http_requests_total{service="gateway", route!~"/healthz|/readyz|/metrics|/version", status=~"5.."}[W]))
total sum(rate(http_requests_total{service="gateway", route!~"/healthz|/readyz|/metrics|/version", status!~"4.."}[W]))
```

The error ratio is `bad / total` (zero when there are no 5xx responses, no value when there is no traffic).

## Latency: gateway-latency

| | |
| --- | --- |
| Objective | 95% of requests take 0.5 seconds or less, over 30 days |
| Error budget | 5% of requests; the same traffic that would use up the availability budget in 216 minutes would use this one up in 36 hours of every request being slow |
| Good event | a request that finished within 0.5 s, which is the `le="0.5"` bucket of the histogram (a bucket boundary, so the count is exact) |
| Bad event | every other request |
| Not counted | nothing but the operational routes. The histogram has no status label, so failed requests and client errors are in both counts |

```text
bad   sum(rate(http_request_duration_seconds_count{service="gateway", route!~"/healthz|/readyz|/metrics|/version"}[W]))
      - sum(rate(http_request_duration_seconds_bucket{service="gateway", route!~"/healthz|/readyz|/metrics|/version", le="0.5"}[W]))
total sum(rate(http_request_duration_seconds_count{service="gateway", route!~"/healthz|/readyz|/metrics|/version"}[W]))
```

## Recording rules and alerts

Per SLO, the rules `slo:sli_error:ratio_rate<window>` (windows 5m, 30m, 1h, 2h, 6h, 1d, 3d, 30d), `slo:sli_events:increase<window>` (1h, 6h, 1d, 3d), `slo:objective:ratio` and `slo:error_budget:ratio`, all with the labels `slo` and `service`. The alerts are `SLOBurnRatePageFast`, `SLOBurnRatePageSlow`, `SLOBurnRateTicketFast` and `SLOBurnRateTicketSlow`; their windows, burn rates and the low-traffic guard are in the ADR.

## Error budget policy

- Budget left and burning slower than 1x: ordinary work.
- A ticket alert (burning at 3x over a day, or 1x over three days): look at the cause in the next working day and put the fix ahead of feature work for the service.
- A page alert: act now. Stop rollouts to the gateway, orders and payments until it is understood.
- Budget exhausted (the 30-day error ratio above the budget): only fixes and rollbacks until it recovers.

The policy has not been used yet; it is the proposal to start from.
