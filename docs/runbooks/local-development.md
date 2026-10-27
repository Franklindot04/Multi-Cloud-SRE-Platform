# Local development

Run, test and try the sample order-processing application on your machine. Nothing here touches a cloud account.

## Prerequisites

| Tool | Needed for | Notes |
| --- | --- | --- |
| Docker (with Compose) | The compose stack, container builds, payments tests when no JDK 25 is installed | Docker Desktop or any engine with the `docker compose` plugin |
| Go 1.27 | gateway and notifier tests | `go version` |
| Python 3.14 and [uv](https://docs.astral.sh/uv/) | orders tests | uv creates the virtual environment and installs hash-pinned dependencies |
| JDK 25 | payments tests without Docker | Optional: `make apps-test` falls back to a Maven container |
| curl | The examples and the smoke test | |

`make apps-test`, `make apps-lint` and `make apps-build` skip a service when its toolchain is missing and say so.

## Run the whole stack

```bash
docker compose -f apps/docker-compose.yml up --build -d
docker compose -f apps/docker-compose.yml ps
```

All ports are bound to `127.0.0.1`: gateway 8080, orders 8081, payments 8082, notifier 8083. Only the gateway is meant for clients; the others are exposed for metrics and debugging. Stop and remove everything with:

```bash
docker compose -f apps/docker-compose.yml down -v
```

Logs are one JSON object per line: `docker compose -f apps/docker-compose.yml logs -f gateway orders`.

## Try the happy path

```bash
# Create an order (the Idempotency-Key header is required)
curl -s -X POST localhost:8080/api/orders \
  -H 'Content-Type: application/json' -H 'Idempotency-Key: demo-1' \
  -d '{"customer_id":"cust-1","items":[{"sku":"sku-1","quantity":2,"unit_price_minor":1250}],"currency":"USD"}'
# -> 201, status "paid", total_minor 2500

# Repeat it: same key and body returns the same order with 200
curl -si -X POST localhost:8080/api/orders -H 'Content-Type: application/json' -H 'Idempotency-Key: demo-1' \
  -d '{"customer_id":"cust-1","items":[{"sku":"sku-1","quantity":2,"unit_price_minor":1250}],"currency":"USD"}' | head -1

# Read it back and its payment
curl -s localhost:8080/api/orders | head -c 400; echo
curl -s localhost:8080/api/orders/<ORDER_ID>
curl -s localhost:8080/api/payments/<PAYMENT_ID>

# A decline: amounts above 100000 minor units are declined by the simulation
curl -s -X POST localhost:8080/api/orders -H 'Content-Type: application/json' -H 'Idempotency-Key: demo-2' \
  -d '{"customer_id":"cust-1","items":[{"sku":"big","quantity":1,"unit_price_minor":150000}],"currency":"USD"}'
# -> 201, status "failed", failure_reason "amount_exceeds_limit"

# Follow one request across services by its request ID
curl -si localhost:8080/api/orders -H 'X-Request-Id: my-trace-1' | grep -i x-request-id
docker compose -f apps/docker-compose.yml logs --no-log-prefix | grep my-trace-1
```

Metrics: `curl -s localhost:8080/metrics | grep http_requests_total`. Readiness: `curl -s localhost:8080/readyz` shows the state of orders and payments.

The same flow is automated by the smoke test, which exits non-zero on any failure. There are two targets:

```bash
# One command: starts the stack (--build -d), runs the test, and always stops the stack afterwards.
# If the test fails, the container logs are printed before the stack is removed.
make smoke-test-stack

# Client only: tests a stack you already started (see above). It does not start or stop anything.
make smoke-test
```

If `make smoke-test` is run without a stack, it waits up to 90 seconds (`WAIT_SECONDS`), then prints how to start one and exits non-zero.

## Run a single service

```bash
# Go services (separate terminals)
cd apps/notifier && go run ./cmd/notifier
cd apps/gateway  && ORDERS_URL=http://localhost:8081 PAYMENTS_URL=http://localhost:8082 go run ./cmd/gateway

# orders
cd apps/orders
uv venv --python 3.14 .venv
uv pip install --python .venv/bin/python --require-hashes -r requirements-dev.txt
PAYMENTS_URL=http://localhost:8082 NOTIFIER_URL=http://localhost:8083 PYTHONPATH=src .venv/bin/python -m orders.main

# payments (needs JDK 25)
cd apps/payments && ./mvnw spring-boot:run
```

Defaults for each setting are in the service READMEs. A bad setting stops the process at startup with every problem listed and exit status 2.

## Run the tests

```bash
make apps-test     # all four services
make apps-lint     # go vet and gofmt, ruff, checkstyle
make apps-build    # container images sre-sample/<service>:local
```

Per service: `go test -race ./...` (gateway, notifier), `.venv/bin/python -m pytest` (orders), `./mvnw test` (payments).

The tests cover the business rules (idempotency, decline rules, order status transitions, repositories, configuration), every endpoint including failure and timeout paths, and the fault injection switch. They need no network or other services.

## Enable fault injection

Fault injection is off by default. Turn it on with environment variables for the whole stack:

```bash
FAULT_INJECTION_ENABLED=true FAULT_ERROR_RATE=0.3 FAULT_LATENCY_MS=200 \
  docker compose -f apps/docker-compose.yml up -d
```

Every service then delays non-operational requests by 200 ms and fails 30% of them with `503 fault_injected`. `/healthz`, `/readyz`, `/metrics` and `/version` are never affected, and each service logs a `fault injection is ENABLED` warning at startup. To target one service, set the variables only for it, for example `FAULT_INJECTION_ENABLED=true FAULT_ERROR_RATE=1 docker compose -f apps/docker-compose.yml up -d payments` (the variables apply to every service in the file, so recreate others without them afterwards). Turn it off by recreating the stack without the variables.

Try the payments-outage behaviour:

```bash
docker compose -f apps/docker-compose.yml stop payments
curl -si -X POST localhost:8080/api/orders -H 'Content-Type: application/json' -H 'Idempotency-Key: outage-1' \
  -d '{"customer_id":"c","items":[{"sku":"s","quantity":1,"unit_price_minor":500}],"currency":"USD"}' | head -1   # 202, pending
docker compose -f apps/docker-compose.yml start payments
# once payments is ready, repeat the same request: 200 and status "paid"
```

Other simulation settings: `PAYMENT_DECLINE_ABOVE_MINOR` and `PAYMENT_APPROVAL_RATIO` (for example `0.5` declines about half of the order IDs, always the same ones).

## Local data layer

PostgreSQL, Valkey and RabbitMQ can run locally with `make data-up`, `make data-check` and `make data-down` (credentials from the untracked `apps/.env`, copied from `apps/.env.example`). The services are not wired to them yet. See the [data layer runbook](data-layer.md).

## Troubleshooting

- **Port already in use:** another process holds 8080-8083. Stop it, or change the published ports in `apps/docker-compose.yml`.
- **`/readyz` is 503 right after start:** the gateway waits for orders and payments; the JVM needs a few seconds. Check `docker compose ps` and the logs.
- **Gateway returns 502 or 504:** an upstream is down or too slow. Check `curl localhost:8081/readyz` and `localhost:8082/readyz`, and the `upstream_unavailable` or `upstream_timeout` code in the response.
- **Orders stay `pending` with `payment_unavailable`:** payments could not be reached. Fix it and repeat the request with the same `Idempotency-Key`.
- **`422 idempotency_key_mismatch`:** the key was already used with a different body. Use a new key for a new order.
- **`400 missing_idempotency_key`:** add the `Idempotency-Key` header (1-128 printable characters).
- **Payments tests are skipped or slow:** without a JDK 25 they run in a Maven container and download dependencies on first use (kept in the `sre-sample-m2` Docker volume).
- **Orders tests skipped:** create the virtual environment with the commands under "Run a single service".
- **Everything is lost on restart:** storage is in memory by design until the data layer arrives.
