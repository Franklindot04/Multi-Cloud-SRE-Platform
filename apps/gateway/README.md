# gateway

Public entry point (Go). Proxies the order and payment APIs to the internal services and adds the shared request ID, trace propagation, metrics and logging. Contract: [`docs/api/gateway.yaml`](../../docs/api/gateway.yaml).

## Endpoints

| Method and path | Description |
| --- | --- |
| `POST /api/orders` | Proxy to `POST /orders` (needs `Idempotency-Key`) |
| `GET /api/orders` | Proxy to `GET /orders` (query string preserved) |
| `GET /api/orders/{id}` | Proxy to `GET /orders/{id}` |
| `GET /api/payments/{id}` | Proxy to `GET /payments/{id}` |
| `GET /version` | `{service, version, commit}` |
| `GET /healthz`, `GET /readyz`, `GET /metrics` | Operational endpoints. `/readyz` requires orders and payments to answer their own `/readyz` within the readiness timeout |

Status codes and bodies from the upstream services are relayed unchanged. Only `Content-Type`, `Accept` and `Idempotency-Key` are forwarded from the client, plus `X-Request-Id` and `traceparent`. An upstream that cannot be reached gives `502 upstream_unavailable`; one that does not answer in time gives `504 upstream_timeout`.

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `PORT` | `8080` | Listen port |
| `ORDERS_URL` | `http://orders:8081` | Orders base URL |
| `PAYMENTS_URL` | `http://payments:8082` | Payments base URL |
| `UPSTREAM_TIMEOUT_MS` | `5000` | Timeout for each upstream call (100-120000) |
| `READINESS_TIMEOUT_MS` | `500` | Timeout for the readiness checks (50-10000) |
| `MAX_BODY_BYTES` | `1048576` | Largest accepted request body |
| `APP_VERSION`, `APP_COMMIT` | `dev`, `unknown` | Reported by `/version` (set at image build time) |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn` or `error` |
| `SHUTDOWN_DRAIN_SECONDS` | `5` | Time `/readyz` fails before the listener stops |
| `SHUTDOWN_TIMEOUT_SECONDS` | `20` | Time allowed for in-flight requests to finish |
| `FAULT_INJECTION_ENABLED` | `false` | Turn on fault injection |
| `FAULT_LATENCY_MS` | `0` | Delay added to every non-operational request |
| `FAULT_ERROR_RATE` | `0` | Fraction (0-1) of non-operational requests answered with `503 fault_injected` |

## Metrics

`http_requests_total{service,method,route,status}`, `http_request_duration_seconds{service,method,route}` and `http_requests_in_flight{service}`, plus Go runtime and process metrics. Routes are templates such as `/api/orders/{id}`.

## Development

```bash
cd apps/gateway
go test -race ./...
go run ./cmd/gateway
```
