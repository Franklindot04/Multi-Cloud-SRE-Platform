# Notifier SLO

The notifier turns the order events that orders publishes to RabbitMQ into notifications. This is the objective for the second half of the order flow, the asynchronous one. Why this number, the burn-rate scheme and what is not covered are in [ADR-0023](../adr/0023-slos-and-alerting.md); the rules are in [`platform/observability/monitors`](../../platform/observability/monitors) (values `slo.slos`). The target is a starting point: tune it from the data.

Data source: Prometheus, from the notifier's `/metrics` (`messages_consumed_total{result}`, [`apps/notifier/README.md`](../../apps/notifier/README.md)). Window: 30 days, rolling.

## Notification delivery: notifier-delivery

| | |
| --- | --- |
| Objective | 99% of the order events that reach the notifier are recorded, over 30 days |
| Error budget | 1% of events: 1 event in 100 may end in the dead-letter queue; at 1,000 events a day that is 300 events in 30 days |
| Good event | an event recorded (`result="processed"`) or recognised as a duplicate of one already recorded (`result="duplicate"`) |
| Bad event | an event moved to the dead-letter queue (`result="dead_letter"`): a message that could not be read, or one that failed on every attempt |
| Not counted | retries (`result="retry"`): the event is counted again when it ends as recorded or dead-lettered; and `result="error"`, a failure to hand a message on, after which the broker redelivers it |

```text
bad   sum(rate(messages_consumed_total{job="notifier", result="dead_letter"}[W]))
total sum(rate(messages_consumed_total{job="notifier", result=~"processed|duplicate|dead_letter"}[W]))
```

**What this does not measure: freshness.** The notifier has no metric for how long an event waited or how long it took to handle, so there is no objective such as "95% of events handled within 30 seconds". The nearest metrics are gauges (`consumer_queue_messages` for the queue depth and, in orders, `outbox_oldest_unpublished_age_seconds`). The alert `OutboxBacklog` watches the second one, and `NotifierBrokerDisconnected` watches `amqp_connected`. A handling-time histogram in the notifier would allow a freshness objective.

A poison message (invalid JSON, an unknown event type, an unsupported schema version) is dead-lettered at once and counts as bad. That is intended: it means orders published something the notifier cannot use.

## Recording rules and alerts

The same rules and alerts as for the gateway, with `slo="notifier-delivery"` and `service="notifier"`. With a 1% budget the thresholds are 14.4%, 6%, 3% and 1% of events dead-lettered.

## Error budget policy

The same as for the gateway ([`gateway.md`](gateway.md)), with orders and the notifier in place of the gateway, orders and payments.
