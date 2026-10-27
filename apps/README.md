# Applications

A small order-processing system that gives the platform realistic workloads to operate, measure and break. It is sample code: the payments service is a simulation and no real payment data or money is involved. Design rationale is in [ADR-0013](../docs/adr/0013-sample-application-design.md); the API contracts are in [`docs/api`](../docs/api).

| Service | Language | Port | Role |
| --- | --- | --- | --- |
| [`gateway`](gateway) | Go | 8080 | Public entry point; proxies `/api/orders` and `/api/payments/{id}` |
| [`orders`](orders) | Python (FastAPI) | 8081 | Order lifecycle; calls payments, then the notifier |
| [`payments`](payments) | Java (Spring Boot) | 8082 | **Simulated** payment authorization with strict idempotency |
| [`notifier`](notifier) | Go | 8083 | Records the notifications that would be sent; delivers nothing |

By default storage is in memory behind a repository interface in every service, and data is lost on restart. The services can instead use the data layer (PostgreSQL, a Valkey cache and RabbitMQ, defined in [`platform/data`](../platform/data)), selected by environment variables: `STORAGE=memory|postgres` (orders, payments), `CACHE=none|valkey` (orders) and `MESSAGING=http|rabbitmq` (orders, notifier). The defaults are `memory`, `none` and `http`, so nothing changes unless you ask for it. Orders publishes events through a transactional outbox; see [ADR-0015](../docs/adr/0015-service-data-integration.md). Run the whole thing with `make integration-test` or see [local development](../docs/runbooks/local-development.md).

## Pinned versions

Checked on **2026-10-26**.

| Component | Version | Where checked |
| --- | --- | --- |
| Go | 1.27.3 | go.dev download list (latest stable; 1.26.10 is the previous release) |
| Python | 3.14.9 | endoflife.date. 3.15.1 exists (released 2026-10-09) but is two weeks old; 3.14 is the mature release with full wheel support for the pinned dependencies |
| Java | 25 (LTS) | The current Long-Term Support release; JDK image `maven:3.9.12-eclipse-temurin-25-noble` |
| FastAPI | 0.162.0 | PyPI |
| Uvicorn | 0.54.0 | PyPI |
| HTTPX | 0.28.1 | PyPI |
| Pydantic | 2.14.1 | PyPI (pulled in by FastAPI, pinned by the lock file) |
| prometheus-client (Python) | 0.26.0 | PyPI |
| Spring Boot | 4.1.2 | Maven Central, endoflife.date (4.1 released 2026-06-30; 3.5 is already past its end of life) |
| Prometheus Java client (`prometheus-metrics-*`) | 1.10.0 | Maven Central. Overrides the 1.7.0 managed by Spring Boot, set with `prometheus-client.version` in the POM |
| Prometheus Go client (`client_golang`) | v1.25.0 | Go module proxy |
| Maven (wrapper) | 3.9.12 | Maven Central |
| Checkstyle (plugin / engine) | 3.6.0 / 14.3.0 | Maven Central |
| Test and lint tools | pytest 9.1.1, pytest-asyncio 1.4.1, ruff 0.17.2 | PyPI |

### Data layer libraries

Checked on **2026-10-27**. Each choice is justified in [ADR-0015](../docs/adr/0015-service-data-integration.md); all are maintained and permissively licensed (psycopg was rejected as LGPL-3.0).

| Service | Component | Version | Licence | Where checked |
| --- | --- | --- | --- | --- |
| orders | asyncpg (PostgreSQL driver and pool) | 0.32.0 | Apache-2.0 | PyPI |
| orders | valkey-py (Valkey client) | 6.2.0 | MIT | PyPI |
| orders | aio-pika (AMQP client) | 10.2.1 | Apache-2.0 | PyPI (pulls in aiormq 7.2.4 and pamqp 4.0.1) |
| notifier | amqp091-go (AMQP client) | v1.16.0 | BSD-2-Clause | Go module proxy |
| payments | Flyway (`flyway-core`, `flyway-database-postgresql`) | 12.4.0 | Apache-2.0 | Managed by Spring Boot 4.1.2 (the newer 13.x line is not in its dependency management) |
| payments | HikariCP | 7.0.2 | Apache-2.0 | Managed by Spring Boot 4.1.2 |
| payments | PostgreSQL JDBC driver | 42.7.14 | BSD-2-Clause | Managed by Spring Boot 4.1.2 |

Local data images (unchanged from the data layer change): `postgres:18.6-alpine`, `valkey/valkey:9.1.2`, `rabbitmq:4.4.0-management`.

Python dependencies are locked with hashes in `orders/requirements.txt` (and `requirements-dev.txt`); `pip install --require-hashes` rejects anything else. Regenerate with `uv pip compile --python-version 3.14 --generate-hashes --no-header requirements.in -o requirements.txt` (details in the [orders README](orders/README.md#dependencies)). Go dependencies are locked by `go.sum`. Java uses the Spring Boot dependency management plus the Maven wrapper (`mvnw`, `.mvn/wrapper`).

### Container base images

| Stage | Image |
| --- | --- |
| Go build | `golang:1.27.3-alpine3.23` |
| Go runtime (gateway, notifier) | `gcr.io/distroless/static-debian13:nonroot` |
| Python build and runtime (orders) | `python:3.14.9-slim-trixie` |
| Java build | `maven:3.9.12-eclipse-temurin-25-noble` |
| Java runtime (payments) | `gcr.io/distroless/java25-debian13:nonroot` |

Images are pinned to specific version tags. The distroless `nonroot` tags move with security updates, so they are the least strict pin. **Digest pinning** (`image@sha256:...`) arrives with the CI image build change: the pipeline will resolve each tag to a digest, write it into the Dockerfiles, and let Renovate or a scheduled job propose digest updates, together with signing and SBOMs.

## Conventions shared by every service

- **Contract:** [`docs/api`](../docs/api) holds one OpenAPI file per service. Errors always use `{"error": {"code", "message", "request_id"}}`.
- **Endpoints:** `/healthz` (alive, process only), `/readyz` (ready; the gateway checks orders and payments; orders requires payments and, with PostgreSQL, the database, and reports the notifier, Valkey and RabbitMQ as degraded when they are down; payments requires its database; the notifier requires RabbitMQ when it consumes from it), `/metrics` (Prometheus).
- **Metrics:** `http_requests_total{service,method,route,status}`, `http_request_duration_seconds{service,method,route}` (buckets 0.005 to 10 seconds) and `http_requests_in_flight{service}`. The `route` label is the route template (for example `/orders/{order_id}`), never the raw path, and unmatched requests share the value `unmatched`.
- **Logs:** one JSON object per line on stdout with `timestamp`, `level`, `message`, `service`, `request_id`, `trace_id`, `method`, `route`, `status` and `duration_ms`. A request ID is generated when `X-Request-Id` is missing or invalid. `X-Request-Id` and the W3C `traceparent` header (same trace, new span) are sent on every outbound call. OpenTelemetry instrumentation comes later.
- **Resilience:** explicit timeouts on every outbound call, bounded request bodies (default 1 MiB), graceful shutdown on SIGTERM (fail `/readyz`, wait the drain period, then stop accepting and finish in-flight requests).
- **Configuration:** environment variables only, validated at startup with every problem reported together; a bad configuration exits with status 2. No config files. Secrets are read from `<NAME>` or `<NAME>_FILE` (a mounted secret), never from the repository, and are never logged.
- **Data layer series** (same names in every service that has the component): `db_pool_connections{state}`, `db_query_duration_seconds{operation}`, `cache_requests_total{result}`, `outbox_unpublished_events`, `outbox_oldest_unpublished_age_seconds`, `messages_published_total{result}`, `messages_consumed_total{result}` and `dead_letter_messages_total`. Label values are small fixed sets; the service READMEs list them. The request ID and `traceparent` appear in database-layer log lines and travel as message headers.
- **Fault injection** (off by default): `FAULT_INJECTION_ENABLED`, `FAULT_LATENCY_MS`, `FAULT_ERROR_RATE`. It never touches `/healthz`, `/readyz`, `/metrics` or `/version`, and a startup log line says when it is on.
- **Containers:** multi-stage builds, non-root numeric user, read-only root filesystem compatible (payments needs a writable `/tmp`), no `HEALTHCHECK` (Kubernetes uses the probes).

## Working with the code

```bash
make apps-test       # unit and handler tests (skips a service whose toolchain is missing)
make apps-lint       # go vet and gofmt, ruff, checkstyle
make apps-build      # container images sre-sample/<service>:local
docker compose -f apps/docker-compose.yml up --build -d
make smoke-test-stack  # start the stack, run the end-to-end checks, always stop it (logs on failure)
make smoke-test        # the same checks against a stack that is already running (client only)

cp apps/.env.example apps/.env   # local throwaway credentials, not tracked
make integration-test            # stack on PostgreSQL, Valkey and RabbitMQ: integration, smoke and chaos tests, always torn down
make smoke-test-integration      # only the smoke test with --integration
```

See the [local development runbook](../docs/runbooks/local-development.md). Deployment to Kubernetes is described in the [service deployment runbook](../docs/runbooks/service-deployment.md); the chart is in [`deploy/helm`](../deploy/helm).

## Not in this change

Publishing the images (the CI change; the chart's image tag is a placeholder until then); network policies, autoscaling and progressive delivery; backups of the data layer; CI image builds, vulnerability scanning, signing and SBOMs; OpenTelemetry instrumentation; authentication.
