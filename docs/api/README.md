# API contracts

One OpenAPI 3.0 file per service. The implementations in [`apps/`](../../apps) follow these files.

| File | Service | Port (default) |
| --- | --- | --- |
| [`gateway.yaml`](gateway.yaml) | gateway (Go) | 8080 |
| [`orders.yaml`](orders.yaml) | orders (Python, FastAPI) | 8081 |
| [`payments.yaml`](payments.yaml) | payments (Java, Spring Boot) | 8082 |
| [`notifier.yaml`](notifier.yaml) | notifier (Go) | 8083 |

## Conventions shared by every service

- **Money** is an integer in minor units (cents) plus an ISO 4217 currency code. There are no floating-point amounts.
- **Errors** use one envelope: `{"error": {"code": "<machine code>", "message": "<text>", "request_id": "<id>"}}`.
- **Request IDs:** `X-Request-Id` is accepted (1-128 characters of letters, digits, `-`, `_`, `.`), generated when missing or invalid, returned on every response and passed on every outbound call.
- **Tracing:** the W3C `traceparent` header is propagated. A valid inbound header keeps its trace ID and gets a new span ID on each outbound hop; a missing one is created at the first service that sees the request.
- **Idempotency:** creating endpoints take an `Idempotency-Key` header. The same key with the same body returns the original result with `200` instead of `201`; the same key with a different body is rejected with `422` (`idempotency_key_mismatch`).
- **Operational endpoints** (`/healthz`, `/readyz`, `/metrics`) exist on every service. `/healthz` means the process is alive; `/readyz` means it can serve and, for the gateway and orders, that its required dependencies answer.
- **Fault injection** (disabled by default) never touches `/healthz`, `/readyz`, `/metrics` or `/version`.
- **Body size** is bounded (default 1 MiB); larger bodies get `413`.
