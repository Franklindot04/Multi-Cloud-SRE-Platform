# notifier

Records the notifications that would be sent for an order (Go). **Nothing is delivered**: there is no email, SMS or webhook integration, only an in-memory record. Contract: [`docs/api/notifier.yaml`](../../docs/api/notifier.yaml).

## Endpoints

| Method and path | Description |
| --- | --- |
| `POST /notifications` | Record a notification: `order_id`, `channel` (`email`, `sms`, `webhook`), `message` (1-1000 characters). Returns `201` with status `recorded` |
| `GET /notifications/{id}` | Get a recorded notification, or `404` |
| `GET /healthz`, `GET /readyz`, `GET /metrics` | Operational endpoints |

The repository keeps at most `MAX_NOTIFICATIONS` entries and drops the oldest, so memory stays bounded.

## Consuming events from RabbitMQ

`MESSAGING=http` (default) serves only the HTTP endpoint above. With `MESSAGING=rabbitmq` the notifier also consumes the order events the orders service publishes ([ADR-0015](../../docs/adr/0015-service-data-integration.md)); the HTTP endpoint keeps working.

Topology, declared idempotently on every connection:

| Name | Kind | Role |
| --- | --- | --- |
| `platform.events` | topic exchange, durable | Where orders publishes (`order.created`, `order.paid`, `order.failed`) |
| `notifier.orders` | quorum queue, durable | Bound to `order.*`; rejected messages dead-letter to the DLX |
| `notifier.orders.retry` | quorum queue, message TTL | Delay queue: after `CONSUMER_RETRY_DELAY_MS` messages return to `notifier.orders` |
| `platform.events.dlx` / `notifier.orders.dlq` | direct exchange / quorum queue | Dead letters, with `x-failure-reason`, `x-attempts` and `x-original-routing-key` headers |

Behaviour: manual acknowledgements with a prefetch limit; a failing message is republished to the retry queue up to `CONSUMER_MAX_ATTEMPTS`, then dead-lettered; a poison message (invalid JSON, unknown type, unsupported `schema_version`, invalid fields) is dead-lettered immediately. The original is acknowledged only after the broker confirmed the copy, otherwise it is requeued. On SIGTERM the consumer stops taking new messages and finishes those in flight. The connection is re-established with exponential backoff and jitter. Inspect and replay dead letters as described in [the data layer runbook](../../docs/runbooks/data-layer.md).

The handler is idempotent on the event ID: the notification is stored under the event ID and a bounded in-memory set of recent IDs (`CONSUMER_DEDUPE_SIZE`) acknowledges redeliveries without handling them. The notifier has no database and only records notifications, so this is enough today; real delivery would need a durable store (see the ADR).

`/readyz` requires RabbitMQ when `MESSAGING=rabbitmq` (the check is named `rabbitmq`); `/healthz` is process-only.

| Variable | Default | Used when | Description |
| --- | --- | --- | --- |
| `MESSAGING` | `http` | always | `http` or `rabbitmq` |
| `AMQP_HOST`, `AMQP_PORT`, `AMQP_VHOST` | `rabbitmq`, `5672`, `/` | `rabbitmq` | Broker |
| `AMQP_USER` | `platform` | `rabbitmq` | User |
| `AMQP_PASSWORD` / `AMQP_PASSWORD_FILE` | required | `rabbitmq` | Password; set one, not both |
| `AMQP_CONNECT_TIMEOUT_MS` | `3000` | `rabbitmq` | Connect timeout |
| `AMQP_RECONNECT_MAX_BACKOFF_SECONDS` | `30` | `rabbitmq` | Longest wait between reconnect attempts |
| `CONSUMER_PREFETCH` | `10` | `rabbitmq` | Unacknowledged messages allowed at once |
| `CONSUMER_MAX_ATTEMPTS` | `3` | `rabbitmq` | Attempts before dead-lettering |
| `CONSUMER_RETRY_DELAY_MS` | `5000` | `rabbitmq` | Delay between attempts |
| `CONSUMER_DEDUPE_SIZE` | `10000` | `rabbitmq` | Event IDs remembered |

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `PORT` | `8083` | Listen port |
| `MAX_NOTIFICATIONS` | `100000` | Notifications kept in memory |
| `MAX_BODY_BYTES` | `1048576` | Largest accepted request body |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn` or `error` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | unset | Turns tracing on; see [Tracing](../README.md#tracing-gateway-orders-and-notifier) for this and the other `OTEL_*` settings |
| `SHUTDOWN_DRAIN_SECONDS` | `5` | Time `/readyz` fails before the listener stops |
| `SHUTDOWN_TIMEOUT_SECONDS` | `20` | Time allowed for in-flight requests to finish |
| `FAULT_INJECTION_ENABLED` | `false` | Turn on fault injection |
| `FAULT_LATENCY_MS` | `0` | Delay added to every non-operational request |
| `FAULT_ERROR_RATE` | `0` | Fraction (0-1) of non-operational requests answered with `503 fault_injected` |

## Metrics

`http_requests_total{service,method,route,status}`, `http_request_duration_seconds{service,method,route}` and `http_requests_in_flight{service}`, plus Go runtime and process metrics. With `MESSAGING=rabbitmq`:

| Metric | Labels | Meaning |
| --- | --- | --- |
| `messages_consumed_total` | `result` = `processed`, `duplicate`, `retry`, `dead_letter`, `error` | How each delivery was handled (`error`: could not hand the message on, so it was requeued) |
| `dead_letter_messages_total` | none | Messages moved to the dead-letter queue |
| `consumer_queue_messages` | `queue` = `main`, `retry`, `dead_letter` | Messages waiting, sampled every 10 s |
| `amqp_connected` | none | 1 while a broker connection works |

Log lines for an event carry `event_id`, `request_id` and `traceparent` from the message headers. The consumer also starts a span for each message as a child of that `traceparent`, when tracing is on.

## Development

```bash
cd apps/notifier
go test -race ./...
go run ./cmd/notifier
# with the integration stack running (make integration-test starts it and sets these):
go test -tags integration -count=1 ./internal/events
```
