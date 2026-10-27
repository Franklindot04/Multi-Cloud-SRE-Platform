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

## Development

Needs a JDK 25. Without one, `make apps-test` runs the tests in a Maven container instead.

```bash
cd apps/payments
./mvnw test                 # tests
./mvnw checkstyle:check     # style
./mvnw spring-boot:run      # run on :8082
```
