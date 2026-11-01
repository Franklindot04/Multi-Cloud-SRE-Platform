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

## Storage, cache and messaging modes

Three switches select how the service runs; the defaults keep the in-memory behaviour and need no infrastructure. The HTTP API is identical in every mode. Design and trade-offs are in [ADR-0015](../../docs/adr/0015-service-data-integration.md).

| Variable | Values | Default | Effect |
| --- | --- | --- | --- |
| `STORAGE` | `memory`, `postgres` | `memory` | Orders and idempotency keys in memory, or in PostgreSQL (pooled, with timeouts) |
| `CACHE` | `none`, `valkey` | `none` | Cache-aside for `GET /orders/{id}` (30 s TTL, deleted on every state change). Any cache error is a logged, counted miss |
| `MESSAGING` | `http`, `rabbitmq` | `http` | `http`: the synchronous best-effort notifier call. `rabbitmq`: `order.created`, `order.paid` and `order.failed` events go through a transactional outbox and a relay to RabbitMQ (needs `STORAGE=postgres`) |

Passwords are read from `<NAME>` or `<NAME>_FILE` (a mounted secret); setting both is an error. Invalid or missing settings stop the process at startup with every problem listed (exit code 2).

| Variable | Default | Used when | Description |
| --- | --- | --- | --- |
| `DB_HOST`, `DB_PORT` | `postgres`, `5432` | `STORAGE=postgres` | Server |
| `DB_NAME`, `DB_USER` | `orders`, `orders` | `STORAGE=postgres` | Database and role |
| `DB_PASSWORD` / `DB_PASSWORD_FILE` | required | `STORAGE=postgres` | Role password |
| `DB_POOL_MIN`, `DB_POOL_MAX` | `1`, `5` | `STORAGE=postgres` | Pool bounds |
| `DB_CONN_MAX_IDLE_SECONDS` | `300` | `STORAGE=postgres` | Idle connections are closed after this |
| `DB_CONNECT_TIMEOUT_MS`, `DB_STATEMENT_TIMEOUT_MS` | `3000`, `5000` | `STORAGE=postgres` | Connect and statement timeouts |
| `CACHE_HOST`, `CACHE_PORT` | `valkey`, `6379` | `CACHE=valkey` | Server |
| `CACHE_PASSWORD` / `CACHE_PASSWORD_FILE` | required | `CACHE=valkey` | Password of the `default` user |
| `CACHE_TTL_SECONDS`, `CACHE_TIMEOUT_MS` | `30`, `200` | `CACHE=valkey` | Entry lifetime and per-call timeout |
| `AMQP_HOST`, `AMQP_PORT`, `AMQP_VHOST` | `rabbitmq`, `5672`, `/` | `MESSAGING=rabbitmq` | Broker |
| `AMQP_USER` | `platform` | `MESSAGING=rabbitmq` | User |
| `AMQP_PASSWORD` / `AMQP_PASSWORD_FILE` | required | `MESSAGING=rabbitmq` | Password |
| `AMQP_CONNECT_TIMEOUT_MS`, `AMQP_PUBLISH_TIMEOUT_MS` | `3000`, `3000` | `MESSAGING=rabbitmq` | Connect and publish-confirm timeouts |
| `OUTBOX_BATCH_SIZE` | `20` | `MESSAGING=rabbitmq` | Events published per cycle |
| `OUTBOX_POLL_INTERVAL_MS` | `500` | `MESSAGING=rabbitmq` | Wait between cycles when idle |
| `OUTBOX_MAX_BACKOFF_SECONDS` | `30` | `MESSAGING=rabbitmq` | Longest wait after repeated publish failures |

### Migrations

The schema is created by a separate forward-only step, never by the service: `python -m orders.migrate` (same `DB_*` variables, `STORAGE=postgres`). It takes a PostgreSQL advisory lock, applies the numbered files in `src/orders/migrations` each in a transaction, verifies the checksums of those already applied, and exits 0 on success, 1 on a failed migration and 2 on a configuration problem. Run it as a one-shot container, init container or Kubernetes Job before the service starts.

### Readiness

`/readyz` fails (503) when payments or, with `STORAGE=postgres`, PostgreSQL is unreachable. Valkey, RabbitMQ and (in `http` mode) the notifier are reported as `degraded` and do not fail readiness: orders can still be taken. `/healthz` only says the process is alive.

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

Data layer metrics (always registered, so dashboards do not depend on the mode; label values are fixed sets, never IDs or SQL):

| Metric | Labels | Meaning |
| --- | --- | --- |
| `db_pool_connections` | `state` = `idle`, `in_use`, `max` | PostgreSQL pool connections |
| `db_query_duration_seconds` | `operation` = `create_order`, `get_order`, `list_orders`, `transition_order`, `mark_unavailable`, `outbox_relay`, ... | Query latency histogram |
| `cache_requests_total` | `result` = `hit`, `miss`, `error` | Valkey lookups and writes |
| `outbox_unpublished_events` | none | Events written but not yet confirmed by the broker |
| `outbox_oldest_unpublished_age_seconds` | none | Age of the oldest unpublished event, 0 when empty (the outbox lag) |
| `messages_published_total` | `result` = `ok`, `error` | Publish attempts to RabbitMQ |

Request ID and `traceparent` are written to the database-layer log lines and sent as message headers, so one request can be followed from the gateway through PostgreSQL to the notifier. With tracing on, the `traceparent` is the one of the active span (see Tracing below).

## Tracing

Orders sends traces to the OpenTelemetry Collector over OTLP/gRPC. **It is off unless `OTEL_EXPORTER_OTLP_ENDPOINT` (or `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`) is set**; `OTEL_SDK_DISABLED=true` and `OTEL_TRACES_EXPORTER=none` turn it off even then. The settings are the standard `OTEL_*` variables, listed with the other services in [Tracing](../README.md#tracing-gateway-orders-and-notifier): the endpoint, `OTEL_SERVICE_NAME` (default `orders`), `OTEL_RESOURCE_ATTRIBUTES` (for example `service.namespace=shop`), `OTEL_TRACES_SAMPLER` and `OTEL_TRACES_SAMPLER_ARG`. An endpoint that starts with `http://` is a plain connection, meant for a Collector inside the cluster; `https://` uses TLS. `service.version` comes from `APP_VERSION` and is `1.0.0` when that is not set. `deploy/helm/values/orders.yaml` sets the variables for the cluster.

- **Requests:** a server span named by method and route template, for example `GET /orders/{order_id}`, from the FastAPI instrumentation. There is none for `/healthz`, `/readyz`, `/metrics` and `/version`. It continues the trace of an incoming `traceparent`.
- **PostgreSQL:** one client span for each repository operation of a request (`db create_order`, `db get_order`, `db list_orders`, `db transition_order`, `db mark_payment_unavailable`), with `db.system.name` and `db.operation.name`. **There is no SQL text and no parameter in a span**: the asyncpg instrumentation always records the statement, so the spans are written by hand. A failed operation records the exception type and a fixed description, not the message.
- **Payments:** one client span for each authorization call, named `POST payments:8082` (method, and host and port from `PAYMENTS_URL`), with `http.request.method`, `url.scheme`, `server.address`, `server.port` and `http.response.status_code`. The `traceparent` sent to payments is the one of this span. A 5xx answer, a connection error or a timeout sets the status to error with a fixed description and records only the exception type. It is written by hand rather than with the httpx instrumentation, so it records no URL, query, headers or bodies and adds no package. The readiness probe and the call to the notifier have no span.
- **Valkey:** no spans. The valkey client has no maintained instrumentation.
- **RabbitMQ:** the outbox relay publishes each event in a producer span named `platform.events publish`, with `messaging.system`, `messaging.operation.type`, `messaging.destination.name`, `messaging.rabbitmq.destination.routing_key` and `messaging.message.body.size`. The message headers include a standard `traceparent` (a string, and `tracestate` when there is one), so the notifier's consumer span becomes a child of the publish span. The publish span is a child of the span that was active when the order changed: the outbox row keeps that `traceparent`, which is why the trace of the request survives the delay between the request and the publish. Bodies and headers are not span attributes.
- **Logs:** `trace_id` is the active span's trace ID in the same form as before (`"trace_id":"<32 lower-case hex digits>"`). Every log line written inside a span has it, including the lines of a failed or successful publish. Without a span the request line uses the trace of the `traceparent` header, as it did.
- **Errors:** a 5xx response or an unhandled exception sets the span status to error; the exception type is recorded, not its message.

A Collector that is missing or slow costs spans, never requests: export runs in the background, startup does not wait for it, the exporter's own messages are limited to one a minute, and shutdown waits at most 5 seconds. HTTP spans carry the standard URL and client attributes; see the privacy note in [apps/README.md](../README.md#tracing-gateway-orders-and-notifier).

## Dependencies

`requirements.in` and `requirements-dev.in` list the direct dependencies. `requirements.txt` and `requirements-dev.txt` are the full, hash-pinned results and are installed with `--require-hashes`, so pip and uv refuse anything that is not listed with a matching hash. They were last regenerated with uv 0.12.5 and Python 3.14. To regenerate (run in `apps/orders`; existing pins are kept unless an input changes):

```bash
uv pip compile --python-version 3.14 --generate-hashes --no-header requirements.in -o requirements.txt
uv pip compile --python-version 3.14 --generate-hashes --no-header requirements-dev.in -o requirements-dev.txt
```

The image contains the dependencies from `requirements.txt` and no pip. The virtual environment is built without pip, the build stage installs into it from outside, and the final stage removes the pip that ships with the base image. pip carries its own copies of other libraries (msgpack, urllib3 and a pkg_resources copy of setuptools), which a vulnerability scan reports as if the application used them, and nothing installs packages at run time. The Dockerfile fails the build if pip is reachable again.

## Development

```bash
cd apps/orders
uv venv --python 3.14 .venv
uv pip install --python .venv/bin/python --require-hashes -r requirements-dev.txt
.venv/bin/python -m pytest
.venv/bin/ruff check . && .venv/bin/ruff format --check .
PAYMENTS_URL=http://localhost:8082 NOTIFIER_URL=http://localhost:8083 PYTHONPATH=src .venv/bin/python -m orders.main
```

Integration tests (real PostgreSQL, Valkey and RabbitMQ) are marked `integration` and skipped unless `INTEGRATION=1`; `make integration-test` starts the stack and runs them (see [local development](../../docs/runbooks/local-development.md)). They run in a scratch schema, so they never touch the running service's data.
