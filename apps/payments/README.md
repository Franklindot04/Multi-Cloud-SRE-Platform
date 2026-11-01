# payments

> **This service is a simulation.** It never contacts a payment network, never accepts card data or any real payment details, and moves no money. Decisions are made by simple deterministic rules for testing and demonstrations.

Payment authorization for the sample order system (Java, Spring Boot). Contract: [`docs/api/payments.yaml`](../../docs/api/payments.yaml).

## Endpoints

| Method and path | Description |
| --- | --- |
| `POST /payments/authorize` | Authorize a payment: `order_id`, `amount_minor`, `currency`; needs `Idempotency-Key`. `201` created (approved or declined), `200` replay, `422` key reused with another body |
| `GET /payments/{id}` | Get a payment, or `404` |
| `GET /healthz`, `GET /readyz`, `GET /metrics` | Operational endpoints |

### Decision rules

In order, first match wins:

1. Currency not in `PAYMENT_ALLOWED_CURRENCIES`: declined, `currency_not_supported`.
2. `amount_minor` above `PAYMENT_DECLINE_ABOVE_MINOR`: declined, `amount_exceeds_limit`.
3. The order ID is hashed (SHA-256) to a number in [0, 1); at or above `PAYMENT_APPROVAL_RATIO`: declined, `issuer_declined`. Ratio 1.0 (default) approves everything within the limits; 0.0 declines everything; 0.5 declines roughly half of order IDs, always the same ones.
4. Otherwise: approved.

### Idempotency

The `Idempotency-Key` is stored with a fingerprint of the request (`order_id`, `amount_minor`, `currency`). The same key and body always return the original payment, approved or declined, with `200`; the same key with a different body is `422 idempotency_key_mismatch`. Creation is atomic, so concurrent requests with one key produce one payment.

## Storage

`STORAGE=memory` (default) keeps payments in memory and needs nothing. `STORAGE=postgres` stores them in PostgreSQL ([ADR-0015](../../docs/adr/0015-service-data-integration.md)): the `payments` table has a unique idempotency key, the request hash, the decision and its reason, and constraints on amount, currency and status. Money is an integer in minor units, identifiers are UUIDs and timestamps are UTC. The insert uses `ON CONFLICT (idempotency_key) DO NOTHING`, so concurrent requests with one key create one payment and a replay returns the stored decision. A database failure is `503 unavailable` (the orders service keeps its order pending and retries).

| Variable | Default | Description |
| --- | --- | --- |
| `STORAGE` | `memory` | `memory` or `postgres` |
| `DB_HOST`, `DB_PORT` | `postgres`, `5432` | Server (`STORAGE=postgres`) |
| `DB_NAME`, `DB_USER` | `payments`, `payments` | Database and role |
| `DB_PASSWORD` / `DB_PASSWORD_FILE` | required | Role password; set one, not both |
| `DB_POOL_MAX` | `5` | Pool size (HikariCP) |
| `DB_CONNECT_TIMEOUT_MS`, `DB_STATEMENT_TIMEOUT_MS` | `3000`, `5000` | Connect and statement timeouts |

The password never appears in logs or in the printed configuration. The service starts even if the database is down and reports it through `/readyz` (503); `/healthz` stays process-only.

### Migrations

Run separately, never on service start: `java -jar payments.jar migrate` (with `STORAGE=postgres` and the `DB_*` variables) applies the Flyway migrations in `src/main/resources/db/migration`. Flyway serialises concurrent runs with a PostgreSQL advisory lock, verifies checksums, and `clean` is disabled. Exit code 0 on success, 1 on a failed migration, 2 on a configuration problem. Use it as a one-shot container, init container or Kubernetes Job. Migrations are forward-only.

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `PORT` | `8082` | Listen port |
| `PAYMENT_DECLINE_ABOVE_MINOR` | `100000` | Amounts above this (minor units) are declined |
| `PAYMENT_APPROVAL_RATIO` | `1.0` | Fraction (0-1) of order IDs approved |
| `PAYMENT_ALLOWED_CURRENCIES` | `USD,EUR,GBP,SEK` | Comma-separated 3-letter codes |
| `MAX_PAYMENTS` | `100000` | Payments kept in memory (oldest dropped first) |
| `MAX_BODY_BYTES` | `1048576` | Largest accepted request body |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn` or `error` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | unset | Turns tracing on; see [Tracing](#tracing) |
| `SHUTDOWN_DRAIN_SECONDS` | `5` | Time `/readyz` fails before the listener stops |
| `SHUTDOWN_TIMEOUT_SECONDS` | `20` | Time allowed for in-flight requests to finish |
| `FAULT_INJECTION_ENABLED` | `false` | Turn on fault injection |
| `FAULT_LATENCY_MS` | `0` | Delay added to every non-operational request |
| `FAULT_ERROR_RATE` | `0` | Fraction (0-1) of non-operational requests answered with `503 fault_injected` |

## Metrics

`http_requests_total{service,method,route,status}`, `http_request_duration_seconds{service,method,route}` and `http_requests_in_flight{service}`, exposed with the Prometheus Java client under the same names as the other services. Routes are templates such as `/payments/{id}`. The container needs a writable `/tmp`.

Always registered: `db_pool_connections{state}` (`idle`, `in_use`, `max`) and `db_query_duration_seconds{operation}` (`save_payment`, `get_payment`). Label values are fixed sets. The request ID and trace ID are written to the database-layer log lines.

## Tracing

Payments sends traces to the OpenTelemetry Collector over OTLP/gRPC. **It is off unless `OTEL_EXPORTER_OTLP_ENDPOINT` (or `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`) is set**; `OTEL_SDK_DISABLED=true` and `OTEL_TRACES_EXPORTER=none` turn it off even then. The settings are the standard `OTEL_*` variables, listed with the other services in [Tracing](../README.md#tracing-gateway-orders-payments-and-notifier): the endpoint, `OTEL_SERVICE_NAME` (default `payments`), `OTEL_RESOURCE_ATTRIBUTES` (for example `service.namespace=shop`), `OTEL_TRACES_SAMPLER` and `OTEL_TRACES_SAMPLER_ARG`. An endpoint that starts with `http://` is a plain connection, meant for a Collector inside the cluster; `https://` uses TLS. `service.version` comes from `APP_VERSION` when it is set. `deploy/helm/values/payments.yaml` sets the variables for the cluster.

**How it is done.** The service uses the OpenTelemetry Java SDK with its environment-variable configuration and the OTLP exporter (`opentelemetry-api`, `opentelemetry-sdk`, `opentelemetry-sdk-extension-autoconfigure` and `opentelemetry-exporter-otlp`). Their versions come from the Spring Boot dependency management, so the Spring Boot version in `pom.xml` fixes them (1.62.0 for Spring Boot 4.1.2). There is no Java agent, no download in the Dockerfile and no extra writable path. The spans are written by hand in the code the service already has; ADR-0022 compares this with the agent and the Spring starter.

- **Requests:** a server span named by method and route template, `POST /payments/authorize` or `GET /payments/{id}`, made by `ObservabilityFilter`. It continues the trace of an incoming `traceparent` and has the attributes `http.request.method`, `url.scheme`, `http.route` and `http.response.status_code`; there is no path, query, client address, header or body. There is none for `/healthz`, `/readyz`, `/metrics` and `/version`. A 5xx answer sets the status to error with the description `server error`, and a failure records the exception type as an event, never its message.
- **Decision:** a span `payments.decide` around the authorization decision, only for an idempotency key that is new. Its attributes are `payments.decision` (`approved` or `declined`) and, when declined, `payments.decline_reason` (a fixed code). It has no order, amount, currency or customer data.
- **PostgreSQL:** when `STORAGE=postgres`, a client span for each repository operation (`db save_payment`, `db get_payment`), with `db.system.name` and `db.operation.name`. There is no SQL text and no parameter in a span, and a failed operation records the exception type and the description `database operation failed`. The in-memory repository has no spans. The service has no broker and makes no outgoing HTTP calls, so there are no spans for those.
- **Logs:** `trace_id` is the trace ID of the server span in the same form as before (`"trace_id":"<32 lower-case hex digits>"`), and every log line written inside a span carries it. Without a span the request line uses the trace of the `traceparent` header, as it did.

A Collector that is missing or slow costs spans, never requests: export runs in the background, startup does not wait for it, the exporter's failures are logged by the SDK (one error line with a stack trace was seen in a minute against an unreachable address) and shutdown waits at most 5 seconds. In a run of the image on a laptop with the restricted settings and a 640 MiB limit, the container used about 10 MiB more memory with tracing on than off, and its start-up time did not differ beyond the noise of that run; neither figure is a measurement under load.

## Development

Needs a JDK 25. Without one, `make apps-test` runs the tests in a Maven container instead.

```bash
cd apps/payments
./mvnw test                 # tests
./mvnw checkstyle:check     # style
./mvnw spring-boot:run      # run on :8082
```

The PostgreSQL tests (`PostgresPaymentRepositoryTest`, including 32 parallel same-key requests and migrations applied twice) run only when `INTEGRATION=1` and the `DB_*` variables point at a database; `make integration-test` does this against the integration stack.
