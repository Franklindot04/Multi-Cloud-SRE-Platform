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
| `SHUTDOWN_DRAIN_SECONDS` | `5` | Time `/readyz` fails before the listener stops |
| `SHUTDOWN_TIMEOUT_SECONDS` | `20` | Time allowed for in-flight requests to finish |
| `FAULT_INJECTION_ENABLED` | `false` | Turn on fault injection |
| `FAULT_LATENCY_MS` | `0` | Delay added to every non-operational request |
| `FAULT_ERROR_RATE` | `0` | Fraction (0-1) of non-operational requests answered with `503 fault_injected` |

## Metrics

`http_requests_total{service,method,route,status}`, `http_request_duration_seconds{service,method,route}` and `http_requests_in_flight{service}`, exposed with the Prometheus Java client under the same names as the other services. Routes are templates such as `/payments/{id}`. The container needs a writable `/tmp`.

Always registered: `db_pool_connections{state}` (`idle`, `in_use`, `max`) and `db_query_duration_seconds{operation}` (`save_payment`, `get_payment`). Label values are fixed sets. The request ID and trace ID are written to the database-layer log lines.

## Development

Needs a JDK 25. Without one, `make apps-test` runs the tests in a Maven container instead.

```bash
cd apps/payments
./mvnw test                 # tests
./mvnw checkstyle:check     # style
./mvnw spring-boot:run      # run on :8082
```

The PostgreSQL tests (`PostgresPaymentRepositoryTest`, including 32 parallel same-key requests and migrations applied twice) run only when `INTEGRATION=1` and the `DB_*` variables point at a database; `make integration-test` does this against the integration stack.
