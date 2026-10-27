# notifier

Records the notifications that would be sent for an order (Go). **Nothing is delivered**: there is no email, SMS or webhook integration, only an in-memory record. Contract: [`docs/api/notifier.yaml`](../../docs/api/notifier.yaml).

## Endpoints

| Method and path | Description |
| --- | --- |
| `POST /notifications` | Record a notification: `order_id`, `channel` (`email`, `sms`, `webhook`), `message` (1-1000 characters). Returns `201` with status `recorded` |
| `GET /notifications/{id}` | Get a recorded notification, or `404` |
| `GET /healthz`, `GET /readyz`, `GET /metrics` | Operational endpoints |

The repository keeps at most `MAX_NOTIFICATIONS` entries and drops the oldest, so memory stays bounded.

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `PORT` | `8083` | Listen port |
| `MAX_NOTIFICATIONS` | `100000` | Notifications kept in memory |
| `MAX_BODY_BYTES` | `1048576` | Largest accepted request body |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn` or `error` |
| `SHUTDOWN_DRAIN_SECONDS` | `5` | Time `/readyz` fails before the listener stops |
| `SHUTDOWN_TIMEOUT_SECONDS` | `20` | Time allowed for in-flight requests to finish |
| `FAULT_INJECTION_ENABLED` | `false` | Turn on fault injection |
| `FAULT_LATENCY_MS` | `0` | Delay added to every non-operational request |
| `FAULT_ERROR_RATE` | `0` | Fraction (0-1) of non-operational requests answered with `503 fault_injected` |

## Metrics

`http_requests_total{service,method,route,status}`, `http_request_duration_seconds{service,method,route}` and `http_requests_in_flight{service}`, plus Go runtime and process metrics.

## Development

```bash
cd apps/notifier
go test -race ./...
go run ./cmd/notifier
```
