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

PostgreSQL, Valkey and RabbitMQ can run on their own with `make data-up`, `make data-check` and `make data-down` (credentials from the untracked `apps/.env`, copied from `apps/.env.example`). See the [data layer runbook](data-layer.md).

## Run the services against the data layer

`apps/docker-compose.integration.yml` is an override that switches the services to `STORAGE=postgres`, `CACHE=valkey` and `MESSAGING=rabbitmq`. It runs the two migration containers (`orders-migrate`, `payments-migrate`) to completion before orders and payments start, and waits for the healthchecks of the data components. It is its own Compose project, `sre-sample-integration`, so it does not touch the volumes of `make data-up`. All ports stay on `127.0.0.1` and the credentials come only from `apps/.env`.

```bash
cp apps/.env.example apps/.env     # once; fake values, not tracked. Stop `make data-up` first: the ports are the same
make integration-test              # start, run integration + smoke + chaos tests, always tear down
make smoke-test-integration        # start, run only smoke-test.sh --integration, always tear down
```

Both targets print the container logs when something fails and remove the containers, network and volumes afterwards. `make integration-test` runs:

1. the integration suites (`scripts/apps.sh integration`): orders against real PostgreSQL, Valkey and RabbitMQ (migrations applied twice, 30 parallel same-key requests giving one order and one payment, the outbox publishing and surviving a broker outage, two relays never publishing the same event, the cache with the wrong password or no server); payments against PostgreSQL (migrations twice, 32 parallel same-key requests); the notifier consuming a duplicate event once and dead-lettering poison messages with their reason;
2. `scripts/smoke-test.sh --integration`: the usual checks plus a notification arriving through RabbitMQ, the order read matching the cached read (and a cache hit), an empty outbox and no dead letters;
3. chaos checks: with **RabbitMQ stopped** orders are still created, the outbox fills, orders stays ready and reports `rabbitmq` as degraded, and everything drains and is consumed after it returns; with **Valkey stopped** orders are created and read, cache errors are counted and readiness is only degraded; with **PostgreSQL stopped** orders and payments become not ready (liveness unaffected) and recover.

To keep the stack up and look around instead:

```bash
docker compose -p sre-sample-integration --env-file apps/.env \
  -f apps/docker-compose.yml -f apps/docker-compose.data.yml -f apps/docker-compose.integration.yml up --build -d
./scripts/smoke-test.sh --integration
# ... explore, then
docker compose -p sre-sample-integration --env-file apps/.env \
  -f apps/docker-compose.yml -f apps/docker-compose.data.yml -f apps/docker-compose.integration.yml down -v
```

Useful while it runs: `curl -s localhost:8081/readyz` (the dependency checks), `curl -s localhost:8081/metrics | grep -E 'outbox|cache|db_'`, `curl -s localhost:8083/metrics | grep -E 'messages_consumed|dead_letter|consumer_queue'`, and the RabbitMQ management UI at `http://localhost:15672`.

### Resetting local data

- Stack from the override: `docker compose -p sre-sample-integration ... down -v` (above), which `make integration-test` does for you.
- The standalone data layer: `make data-down PURGE=1`.
- Only the order tables, keeping the containers: `docker compose -p sre-sample-integration exec postgres psql -U "$POSTGRES_USER" -d orders -c 'TRUNCATE orders, order_items, idempotency_keys, outbox_events CASCADE'` (load the variables from `apps/.env` first). Only for local data; the services never truncate.

### Dead-letter queue

How to inspect and replay is in the [data layer runbook](data-layer.md#dead-letter-queue-inspect-and-replay).

## Troubleshooting

- **Port already in use:** another process holds 8080-8083. Stop it, or change the published ports in `apps/docker-compose.yml`.
- **`/readyz` is 503 right after start:** the gateway waits for orders and payments; the JVM needs a few seconds. Check `docker compose ps` and the logs.
- **Gateway returns 502 or 504:** an upstream is down or too slow. Check `curl localhost:8081/readyz` and `localhost:8082/readyz`, and the `upstream_unavailable` or `upstream_timeout` code in the response.
- **Orders stay `pending` with `payment_unavailable`:** payments could not be reached. Fix it and repeat the request with the same `Idempotency-Key`.
- **`422 idempotency_key_mismatch`:** the key was already used with a different body. Use a new key for a new order.
- **`400 missing_idempotency_key`:** add the `Idempotency-Key` header (1-128 printable characters).
- **Payments tests are skipped or slow:** without a JDK 25 they run in a Maven container and download dependencies on first use (kept in the `sre-sample-m2` Docker volume).
- **Orders tests skipped:** create the virtual environment with the commands under "Run a single service".
- **Everything is lost on restart:** storage is in memory by default; run with the integration override to keep data in PostgreSQL.
- **`make integration-test` says apps/.env is missing:** `cp apps/.env.example apps/.env`.
- **`port is already allocated` on 5432, 6379, 5672 or 15672:** `make data-up` or another database is running. Stop it first.
- **Orders is not ready with the integration stack:** `curl localhost:8081/readyz` names the failing check (`postgres`, `payments`). `degraded` entries (`valkey`, `rabbitmq`) do not block readiness.
- **Events are not arriving:** `outbox_unpublished_events` rising means the relay cannot publish (check `rabbitmq`, `messages_published_total{result="error"}` and the orders logs); `consumer_queue_messages` and `dead_letter_messages_total` on the notifier show the other side.
- **Orders pytest integration tests are skipped:** they need `INTEGRATION=1`, which `scripts/apps.sh integration` sets; run them through `make integration-test`.
