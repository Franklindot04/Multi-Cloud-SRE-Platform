# ADR-0013: Sample application design

- Status: Accepted
- Date: 2026-10-26

## Context

The platform needs workloads to deploy, observe, break and recover. They should be small enough to read in an afternoon but shaped like real systems: several services, synchronous and asynchronous calls, a dependency that can fail, and a critical path with a clear success measure. The data layer (PostgreSQL, Redis, a broker), Helm charts, CI image builds, signing and OpenTelemetry arrive in later changes, so the first version has to be replaceable at those seams.

## Decision

Four services

- **gateway** is the only public entry point. It gives the platform an edge to measure (user-facing availability and latency) and a place where upstream failures become 502 and 504.
- **orders** owns the order lifecycle and orchestrates payment and notification. It is the service whose behaviour under dependency failure is most interesting.
- **payments** is the critical dependency: the one with the tightest SLO and the main target for latency and error injection. It is a **simulation**: no card data, no payment network, deterministic decisions.
- **notifier** is the non-critical, best-effort dependency. It shows how a failing optional dependency should degrade (logged, order unaffected, readiness degraded but not failed) and later becomes the queue consumer.

Languages

- Go for gateway and notifier, Python (FastAPI) for orders and Java (Spring Boot) for payments. Three runtimes make the platform prove that its conventions (metrics, logs, probes, shutdown, images) are language-independent rather than tied to one framework, and give the observability and reliability work realistic variety: a small static binary, an interpreter with a virtual environment, and a JVM with slower startup and a heap. The cost is three toolchains to maintain; the shared contract and conventions below keep that manageable.

In-memory storage behind interfaces

- Each service stores data behind a repository interface with a thread-safe in-memory implementation that is bounded (oldest entries are dropped). Handlers and domain logic depend on the interface only, so the next change swaps in PostgreSQL or Redis without touching them. Data does not survive a restart, which is acceptable until the data layer exists.

Shared conventions

- **One contract per service** in `docs/api` (OpenAPI 3.0), one error envelope, money as integers in minor units, request bodies bounded to 1 MiB, and every outbound call with an explicit timeout.
- **Metrics** use identical names and labels in every language: `http_requests_total{service,method,route,status}`, `http_request_duration_seconds{service,method,route}` and `http_requests_in_flight{service}`. The route label is always the route template, never the raw path, so cardinality stays bounded, and unmatched requests share one value. Identical names let one set of dashboards, SLO rules and alerts cover every service.
- **Logs** are one JSON object per line with the same fields in every service (`timestamp`, `level`, `message`, `service`, `request_id`, `trace_id`, `method`, `route`, `status`, `duration_ms`). A request ID is generated when missing and, with the W3C `traceparent` header, forwarded on every outbound call, so a single request can be followed across services before OpenTelemetry exists. Each hop keeps the trace ID and creates a new span ID.
- **Probes and shutdown:** `/healthz` means alive, `/readyz` means able to serve (and, for the gateway and orders, that required dependencies answer within a short timeout). On SIGTERM a service fails `/readyz`, waits a drain period so load balancers stop sending traffic, then stops accepting connections and finishes in-flight requests.

Idempotency

- Creating requests take an `Idempotency-Key`. The key is stored with a fingerprint of the request. The same key and body return the original result (200 instead of 201), and the same key with a different body is rejected (422), so a retry can never create a second order or charge twice.
- Orders derives the payment's key from the order ID, so a retry after a payments outage re-authorizes the same order idempotently. This is what makes the failure behaviour safe: when payments is unavailable the order is **kept** as `pending` (202) instead of being lost or failed, and repeating the request completes it. Creation in each repository is atomic, so concurrent requests with one key produce one order or payment.
- Order status moves only `pending` to `paid` or `failed`; the final states never change, and repeating a transition is a no-op. Only the request that settles an order notifies, so retries do not duplicate notifications.

Fault injection as a feature

- Latency and error rate can be injected into every service through three environment variables, off by default, logged loudly at startup, and never applied to health, readiness, metrics or version endpoints. Failures are a first-class input for the reliability phase: SLO burn-rate alerts, timeouts, retries, circuit breaking and rollbacks can only be demonstrated if failures can be produced on demand and safely. Because it is configuration, a chaos tool can later drive the same behaviour.

Containers

- Multi-stage builds with pinned version tags, non-root numeric users, distroless runtime images where a matching one exists (Go, Java), read-only root filesystem compatibility, and no `HEALTHCHECK` because Kubernetes probes replace it. Digest pinning, signing and SBOMs are deferred to the CI image change.

Deferred

- PostgreSQL, Redis and a message broker (the notifier becomes a consumer); Helm charts and Kubernetes manifests; CI builds, scanning, signing and SBOMs; OpenTelemetry instrumentation and exemplars; authentication and rate limiting at the gateway; a shared library for the cross-cutting code.

## Consequences

- Dashboards, SLOs and runbooks are written once against shared metric and log shapes.
- The cross-cutting code (middleware, metrics, config parsing) is duplicated per service, and the Go copy is duplicated between gateway and notifier. Services stay self-contained and independently buildable; a shared module can be introduced when the duplication costs more than the coupling.
- State is lost on restart and each replica has its own memory, so more than one replica gives inconsistent reads until the data layer arrives. The tests and the compose stack run one replica of each.
- Maintaining three languages costs more than one, in exchange for validating the platform conventions across runtimes.

## Alternatives considered

- One language for all services: simpler, but would hide runtime-specific issues (JVM warm-up and memory, interpreter packaging) that the platform should handle.
- Real databases and a broker from the start: more realistic, but it would delay the application and mix two large changes; the repository interfaces make the later swap cheap.
- A service mesh or API gateway product instead of a custom gateway: appropriate later, but a small gateway keeps the edge behaviour visible and testable.
- Autogenerated clients and servers from the OpenAPI files: the contract is kept in step by hand and checked by tests and the smoke test; generation can follow once the contract stabilises.
- Fault injection through an external tool only: more realistic network faults, but it needs a cluster; the built-in switch works everywhere, including local Compose.
