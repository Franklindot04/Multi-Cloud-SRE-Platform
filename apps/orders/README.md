# orders

Order lifecycle (Python, FastAPI). Creating an order stores it as `pending`, authorizes payment with the payments service, settles it as `paid` or `failed`, and asks the notifier to record a notification. Contract: [`docs/api/orders.yaml`](../../docs/api/orders.yaml).

## Endpoints

| Method and path | Description |
| --- | --- |
| `POST /orders` | Create an order. Needs `Idempotency-Key`; body has `customer_id`, `items` (`sku`, `quantity`, `unit_price_minor`) and `currency`. `201` created, `200` replay, `202` payments unavailable, `422` key reused with another body |
| `GET /orders` | List orders, newest first (`limit` 1-200, `offset`) |
| `GET /orders/{id}` | Get an order, or `404` |
| `GET /healthz`, `GET /readyz`, `GET /metrics` | Operational endpoints. `/readyz` requires payments; the notifier is reported as `degraded` when down but does not fail readiness |

### Order states

`pending` becomes `paid` (payment approved) or `failed` (declined or rejected, with `failure_reason`). `paid` and `failed` are final; repeating a request is safe.

### When payments is down

If payments times out, refuses the connection or answers 5xx, the order is **kept** as `pending` with `failure_reason: payment_unavailable` and the response is `202`. Repeating the request with the same `Idempotency-Key` retries the authorization, which is safe because the payment key is derived from the order ID. A notification is sent only by the request that settles the order, so retries do not duplicate it. If the notifier is down the order is unaffected and the failure is logged.

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `PORT` | `8081` | Listen port |
| `PAYMENTS_URL` | `http://payments:8082` | Payments base URL |
| `NOTIFIER_URL` | `http://notifier:8083` | Notifier base URL |
| `PAYMENTS_TIMEOUT_MS` | `2000` | Timeout for payment calls (100-60000) |
| `NOTIFIER_TIMEOUT_MS` | `1000` | Timeout for notifier calls (100-60000) |
| `READINESS_TIMEOUT_MS` | `500` | Timeout for the readiness checks (50-10000) |
| `MAX_ORDERS` | `100000` | Orders kept in memory (oldest dropped first) |
| `MAX_BODY_BYTES` | `1048576` | Largest accepted request body |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn` or `error` |
| `SHUTDOWN_DRAIN_SECONDS` | `5` | Time `/readyz` fails before the listener stops |
| `SHUTDOWN_TIMEOUT_SECONDS` | `20` | Time allowed for in-flight requests to finish |
| `FAULT_INJECTION_ENABLED` | `false` | Turn on fault injection |
| `FAULT_LATENCY_MS` | `0` | Delay added to every non-operational request |
| `FAULT_ERROR_RATE` | `0` | Fraction (0-1) of non-operational requests answered with `503 fault_injected` |

## Metrics

`http_requests_total{service,method,route,status}`, `http_request_duration_seconds{service,method,route}` and `http_requests_in_flight{service}`. Routes are templates such as `/orders/{order_id}`.

## Development

```bash
cd apps/orders
uv venv --python 3.14 .venv
uv pip install --python .venv/bin/python --require-hashes -r requirements-dev.txt
.venv/bin/python -m pytest
.venv/bin/ruff check . && .venv/bin/ruff format --check .
PAYMENTS_URL=http://localhost:8082 NOTIFIER_URL=http://localhost:8083 PYTHONPATH=src .venv/bin/python -m orders.main
```
