# Applications

A small order-processing system that gives the platform realistic workloads to operate, measure and break. It is sample code: the payments service is a simulation and no real payment data or money is involved. Design rationale is in [ADR-0013](../docs/adr/0013-sample-application-design.md); the API contracts are in [`docs/api`](../docs/api).

| Service | Language | Port | Role |
| --- | --- | --- | --- |
| [`gateway`](gateway) | Go | 8080 | Public entry point; proxies `/api/orders` and `/api/payments/{id}` |
| [`orders`](orders) | Python (FastAPI) | 8081 | Order lifecycle; calls payments, then the notifier |
| [`payments`](payments) | Java (Spring Boot) | 8082 | **Simulated** payment authorization with strict idempotency |
| [`notifier`](notifier) | Go | 8083 | Records the notifications that would be sent; delivers nothing |

Storage is in memory behind a repository interface in every service, so real storage replaces the implementation without touching handlers. Data is lost on restart. The data layer (PostgreSQL, a Valkey cache and RabbitMQ) is defined in [`platform/data`](../platform/data) and can be run locally with `make data-up` (see the [data layer runbook](../docs/runbooks/data-layer.md)); the services are wired to it in the next change.

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

Python dependencies are locked with hashes in `orders/requirements.txt` (and `requirements-dev.txt`); `pip install --require-hashes` rejects anything else. Regenerate with `uv pip compile --python-version 3.14 --generate-hashes requirements.in -o requirements.txt`. Go dependencies are locked by `go.sum`. Java uses the Spring Boot dependency management plus the Maven wrapper (`mvnw`, `.mvn/wrapper`).

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
- **Endpoints:** `/healthz` (alive), `/readyz` (ready; the gateway checks orders and payments, orders checks payments and reports the notifier as optional), `/metrics` (Prometheus).
- **Metrics:** `http_requests_total{service,method,route,status}`, `http_request_duration_seconds{service,method,route}` (buckets 0.005 to 10 seconds) and `http_requests_in_flight{service}`. The `route` label is the route template (for example `/orders/{order_id}`), never the raw path, and unmatched requests share the value `unmatched`.
- **Logs:** one JSON object per line on stdout with `timestamp`, `level`, `message`, `service`, `request_id`, `trace_id`, `method`, `route`, `status` and `duration_ms`. A request ID is generated when `X-Request-Id` is missing or invalid. `X-Request-Id` and the W3C `traceparent` header (same trace, new span) are sent on every outbound call. OpenTelemetry instrumentation comes later.
- **Resilience:** explicit timeouts on every outbound call, bounded request bodies (default 1 MiB), graceful shutdown on SIGTERM (fail `/readyz`, wait the drain period, then stop accepting and finish in-flight requests).
- **Configuration:** environment variables only, validated at startup with every problem reported together; a bad configuration exits with status 2. No secrets and no config files.
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
```

See the [local development runbook](../docs/runbooks/local-development.md).

## Not in this change

PostgreSQL, Redis and a message broker; Helm charts and deployment; CI image builds, vulnerability scanning, signing and SBOMs; OpenTelemetry instrumentation; authentication.
