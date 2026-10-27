# ADR-0015: Service data integration

- Status: Accepted
- Date: 2026-10-27

## Context

[ADR-0013](0013-sample-application-design.md) put orders and payments behind repository interfaces with in-memory storage, and [ADR-0014](0014-data-layer.md) defined PostgreSQL, Valkey and RabbitMQ. This change connects the services to them. It does not change any HTTP contract in `docs/api`: the same requests, responses and error codes apply whichever storage is used.

## Decision

Modes, with the current behaviour as the default

- Three switches, read from the environment only: `STORAGE=memory|postgres` (orders, payments), `CACHE=none|valkey` (orders) and `MESSAGING=http|rabbitmq` (orders, notifier). The defaults are `memory`, `none` and `http`, so the existing local stack, the smoke test and every unit test run unchanged and need no database.
- **The memory mode stays** because it is the fastest feedback loop, it keeps CI and `make smoke-test-stack` free of containers beyond the services themselves, and it is the specification the PostgreSQL repositories are tested against. It is not a production mode: data is lost on restart and each replica has its own.
- Configuration is validated at startup and every problem is reported together. Passwords come from `<NAME>` or `<NAME>_FILE` (a mounted secret); setting both, or pointing at an unreadable or empty file, is an error, and no password appears in a log line, a `repr` or a configuration printout. `MESSAGING=rabbitmq` on orders requires `STORAGE=postgres`, because events are written by the outbox.

PostgreSQL is the source of truth

- Orders (`orders`, `order_items`, `idempotency_keys`, `outbox_events`) and payments (`payments`) live in their own database with their own role ([ADR-0014](0014-data-layer.md)). Money is an integer in minor units with `CHECK` constraints, identifiers are UUIDs and timestamps are `timestamptz` read and written in UTC. Constraints enforce what the code assumes: statuses, positive amounts, one idempotency key per request, a decision reason exactly when a payment is declined.
- **Idempotency is decided by a unique key, not by a lookup.** Orders claim the key with `INSERT ... ON CONFLICT DO NOTHING` first; if the row already exists the stored order is returned (or `idempotency_key_mismatch` if the request hash differs), so a unique violation takes the replay path and never becomes a 500. Payments insert with `ON CONFLICT (idempotency_key) DO NOTHING` and read the winner back. A test fires 30 parallel same-key requests at each layer and asserts one order, one payment and one `order.created` event.
- Connections are pooled with explicit limits, connect and statement timeouts, and `application_name` set; a request ID and trace ID travel into the database-layer log lines. A database outage returns 503 from payments (orders treats it like any payments failure and keeps the order pending, [ADR-0013](0013-sample-application-design.md)).

Migrations are forward-only SQL in a separate step

- Versioned SQL files, applied in order, each in its own transaction, under a PostgreSQL advisory lock so two runners cannot interleave, with the checksum of every applied file verified (a changed migration is an error). There are no down migrations: a mistake is corrected by a new migration, and destructive changes follow expand-then-contract across releases.
- **Why a separate step and not on service start:** with several replicas starting together, schema changes race, the service's runtime role would need DDL rights it should not have, a slow or failing migration would look like a crash loop, and a rollback of the application would be coupled to a schema that cannot roll back. A one-shot command (`python -m orders.migrate`, `java -jar payments.jar migrate`) runs as a Compose service now and as a Kubernetes Job or init container next ([the runbook](../runbooks/data-layer.md) shows the shape). Services never migrate; payments verifies the schema through its readiness query.

Transactional outbox for events

- The order row and its event row are written in the **same transaction**, so there is never an order without its event or an event without its order. A relay inside the orders process polls with `SELECT ... FOR UPDATE SKIP LOCKED` in small batches (so replicas share the work), publishes with publisher confirms, and sets `published_at` only after the broker confirmed. A failure commits what was already confirmed, leaves the rest unpublished and backs off exponentially, so an outage delays events but loses none. Messages are published `mandatory`, so an unroutable event fails and stays in the outbox.
- **Cost:** the relay is another thing to run and monitor (lag and count are metrics: `outbox_unpublished_events`, `outbox_oldest_unpublished_age_seconds`), the table grows and needs cleaning (a retention job is deferred), events reach consumers after a poll interval rather than instantly, and publishing is **at least once**: a crash between the broker's confirm and the commit republishes that event.
- **Consumers must therefore be idempotent**, and the contract says so: every event carries a stable `event_id` (the outbox row ID) in the body and in the message headers, with `event_type`, `schema_version` (1), `request_id` and a W3C `traceparent`. The alternative of publishing directly after the commit can lose an event if the process dies in between; a two-phase commit with the broker is not available.
- With `MESSAGING=http` the synchronous best-effort call to the notifier is kept exactly as before, and no outbox rows are written.

RabbitMQ topology and the notifier

- Declared idempotently by the consumer on every connection: a durable topic exchange `platform.events`, a durable quorum queue `notifier.orders` bound to `order.*`, a dead-letter exchange `platform.events.dlx` with queue `notifier.orders.dlq`, and a delay queue `notifier.orders.retry` whose message TTL dead-letters back into the main queue. This gives bounded retries without a plugin. Quorum queues match the HA profile of [ADR-0014](0014-data-layer.md).
- The consumer uses manual acknowledgements and a prefetch limit. A failing message is republished to the retry queue (with `x-attempts`) up to `CONSUMER_MAX_ATTEMPTS`; a message that can never succeed (invalid JSON, unknown type, unsupported schema version, invalid fields) goes straight to the dead-letter queue, and so does one that exhausts its attempts. Either way the copy carries `x-failure-reason`, and the original is acknowledged only after the broker confirmed the copy, otherwise it is requeued. Shutdown stops new deliveries and finishes the messages in flight; the connection is re-established with exponential backoff and jitter.
- **The handler is idempotent on the event ID.** The notification is stored under the event ID, and a bounded in-memory set of recently seen IDs acknowledges redeliveries without handling them again. This is a deliberate small design: the notifier has no database and records notifications instead of delivering them, so a restart that forgets the set re-records an event under the same ID (an overwrite, not a duplicate). **Once real delivery exists the set must become a durable unique constraint**, or a restart could send a message twice.
- RabbitMQ is a **required** dependency of the notifier when `MESSAGING=rabbitmq` (`/readyz` fails without it) and a **degraded** one for orders, which keeps taking orders because the outbox holds the events.

Cache-aside with Valkey

- `GET /orders/{id}` reads the cache (`order:<id>`, short TTL, default 30 s) and falls back to PostgreSQL; every state change deletes the key. Valkey was chosen over Redis for licensing ([ADR-0014](0014-data-layer.md)); the client is valkey-py (MIT).
- **Failure behaviour:** every call has a short timeout (default 200 ms). Any cache error, a timeout, an authentication failure or a corrupt entry is logged at `warn`, counted as `cache_requests_total{result="error"}` and treated as a miss; the request is served from PostgreSQL. A test proves requests succeed with the cache down. Readiness only reports the cache as degraded.
- **Known race:** a read that misses just before a write can store the old order after the write invalidated the key, so a stale entry can live up to the TTL. The short TTL bounds it; a version check or write-through would remove it and is not worth the complexity for an order that changes at most twice.

Readiness

- Orders: PostgreSQL and payments are required; Valkey, RabbitMQ (and the notifier in `http` mode) are degraded when down. Payments: PostgreSQL is required. Notifier: RabbitMQ is required in `rabbitmq` mode. `healthz` stays process-only everywhere.

Library choices (checked on 2026-10-27)

| Service | Purpose | Library | Version | Licence |
| --- | --- | --- | --- | --- |
| orders | PostgreSQL driver and pool | asyncpg | 0.32.0 | Apache-2.0 |
| orders | Valkey client | valkey-py | 6.2.0 | MIT |
| orders | AMQP client | aio-pika | 10.2.1 | Apache-2.0 |
| notifier | AMQP client | amqp091-go | 1.16.0 | BSD-2-Clause |
| payments | Migrations | Flyway Community | 12.4.0 (managed by Spring Boot 4.1.2) | Apache-2.0 |
| payments | Connection pool | HikariCP | 7.0.2 (managed) | Apache-2.0 |
| payments | PostgreSQL driver | PostgreSQL JDBC | 42.7.14 (managed) | BSD-2-Clause |

- **asyncpg**: the maintained native async PostgreSQL driver, fast, with a built-in pool and explicit transactions, and it fits the async FastAPI service without a thread pool. `psycopg` 3 was rejected because it is LGPL-3.0. SQLAlchemy and Alembic were not used: the schema is small, and a hundred-line runner with checksums and an advisory lock is easier to audit than an ORM and its migration framework.
- **valkey-py** is the Valkey project's own client and is MIT licensed, with an asyncio API. `redis-py` (MIT) would also work against Valkey; the Valkey client keeps the dependency aligned with the server chosen in [ADR-0014](0014-data-layer.md).
- **aio-pika** is the maintained asyncio client for RabbitMQ (Apache-2.0), with robust reconnection and publisher confirms.
- **amqp091-go** is the RabbitMQ team's maintained Go client (the original `streadway/amqp` is archived). The notifier needs no database or cache client.
- **Flyway** gives versioned, checksummed, lock-protected migrations from plain SQL, with the lock taken through a PostgreSQL advisory lock. Version 12.4.0 is the one Spring Boot 4.1.2 manages; the newer 13.x line is outside that management and was not adopted. Boot's JDBC and Flyway auto-configuration is **not** used (HikariCP, the driver and Flyway are plain dependencies), so the service cannot migrate at startup. Liquibase was not chosen: its changelog formats add a layer the project does not need. `golang-migrate`, `goose` and `pgx` were evaluated for Go and not needed.

Deferred

- Backups, restores and point-in-time recovery (the disaster recovery change); schema-evolution rules beyond expand-then-contract and a CI check that a migration is backward compatible with the running release; an outbox retention job; a durable idempotency store for the notifier; the Kubernetes migration Jobs and the secret wiring (next change); TLS to the data components; connection pooling in front of PostgreSQL; alerts on the new metrics (with the observability work).

## Consequences

- The services can run with no infrastructure (memory) or with the full data layer from the same images and the same code paths, selected by environment.
- Events are never lost between PostgreSQL and the broker, at the price of at-least-once delivery, an outbox table and a relay.
- Operating the schema is a deliberate act (a Job), which is safer and slightly slower to roll out.
- The notifier's in-memory deduplication is honest but temporary; the limit is documented where it matters.
- The orders cache can briefly serve a stale order in a rare race; the TTL bounds it.

## Alternatives considered

- Migrate on application start: simpler, but races between replicas and ties the schema to the application lifecycle.
- Publish to the broker directly after the commit (or before): loses or invents events on a crash; the outbox is the standard remedy.
- Change data capture (for example Debezium) instead of a polling relay: lower latency and no relay code, but a connector platform to run and a heavier dependency than this workload warrants.
- A shared database for all services: cheaper, rejected for the same isolation reasons as in [ADR-0014](0014-data-layer.md).
- An ORM for the Python service: less SQL to write, but hides the statements whose constraints and locking this design depends on.
