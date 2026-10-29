from __future__ import annotations

import asyncio
import io
import json
import os
import uuid
from collections.abc import Callable
from datetime import UTC, datetime
from typing import Any

import aio_pika
import asyncpg
import httpx
import pytest
from prometheus_client import CollectorRegistry

from orders.cache import ValkeyCache
from orders.config import AmqpConfig, CacheConfig, Config
from orders.messaging import EXCHANGE, AmqpPublisher, OutboxEvent
from orders.metrics import CacheMetrics, DbMetrics, OutboxMetrics
from orders.migrate import MigrationError, discover, migrate
from orders.models import IdempotencyMismatch, InvalidTransition, Order, OrderItem, OrderStatus
from orders.observability import JsonLogger, request_id_var, trace_var
from orders.outbox import OutboxRelay
from orders.postgres import PostgresOrderRepository

pytestmark = pytest.mark.integration

NOW = datetime(2026, 1, 1, tzinfo=UTC)


def an_order() -> Order:
    return Order(
        id=str(uuid.uuid4()),
        customer_id="cust-it",
        items=[OrderItem(sku="sku-1", quantity=2, unit_price_minor=1250)],
        currency="USD",
        total_minor=2500,
        status=OrderStatus.PENDING,
        created_at=NOW,
        updated_at=NOW,
    )


async def count(pool: asyncpg.Pool, table: str, where: str = "true") -> int:
    return await pool.fetchval(f"SELECT count(*) FROM {table} WHERE {where}")


# --- migrations ---


async def test_migrations_apply_cleanly_twice(live_config: Config, schema: str) -> None:
    db = live_config.db
    conn = await asyncpg.connect(
        host=db.host,
        port=db.port,
        database=db.name,
        user=db.user,
        password=db.password,
        server_settings={"search_path": schema},
    )
    try:
        first = await migrate(conn, discover())
        second = await migrate(conn, discover())
        assert first == [v for v, _, _ in discover()] and second == []
        tables = {
            r["tablename"] for r in await conn.fetch("SELECT tablename FROM pg_tables WHERE schemaname = $1", schema)
        }
        assert {"orders", "order_items", "idempotency_keys", "outbox_events", "schema_migrations"} <= tables
    finally:
        await conn.close()


async def test_a_changed_migration_is_detected(live_config: Config, schema: str) -> None:
    db = live_config.db
    conn = await asyncpg.connect(
        host=db.host,
        port=db.port,
        database=db.name,
        user=db.user,
        password=db.password,
        server_settings={"search_path": schema},
    )
    try:
        migrations = discover()
        await migrate(conn, migrations)
        tampered = [(v, n, sql + "\n-- edited") for v, n, sql in migrations]
        with pytest.raises(MigrationError, match="changed"):
            await migrate(conn, tampered)
    finally:
        await conn.close()


async def test_constraints_reject_bad_rows(pool: asyncpg.Pool) -> None:
    order_id = uuid.uuid4()
    with pytest.raises(asyncpg.CheckViolationError):
        await pool.execute(
            "INSERT INTO orders (id, customer_id, currency, total_minor, status) VALUES ($1, 'c', 'USD', -1, 'pending')",
            order_id,
        )
    with pytest.raises(asyncpg.CheckViolationError):
        await pool.execute(
            "INSERT INTO orders (id, customer_id, currency, total_minor, status) VALUES ($1, 'c', 'USD', 1, 'shipped')",
            order_id,
        )


# --- idempotency and the replay path ---


async def test_parallel_requests_with_one_key_create_one_order(
    repository: PostgresOrderRepository, pool: asyncpg.Pool
) -> None:
    results = await asyncio.gather(*(repository.create_or_get("same-key", "hash", an_order()) for _ in range(30)))
    assert [created for _, created in results].count(True) == 1
    assert len({order.id for order, _ in results}) == 1
    assert await count(pool, "orders") == 1
    assert await count(pool, "order_items") == 1
    assert await count(pool, "idempotency_keys") == 1
    assert await count(pool, "outbox_events", "event_type = 'order.created'") == 1


async def test_the_same_key_with_another_body_is_a_mismatch(repository: PostgresOrderRepository) -> None:
    await repository.create_or_get("k", "hash-1", an_order())
    with pytest.raises(IdempotencyMismatch):
        await repository.create_or_get("k", "hash-2", an_order())


async def test_transitions_write_one_event_each_and_conflicts_are_rejected(
    repository: PostgresOrderRepository, pool: asyncpg.Pool
) -> None:
    order, _ = await repository.create_or_get("k", "h", an_order())
    paid, changed = await repository.transition(order.id, OrderStatus.PAID, payment_id="pay-1")
    again, changed_again = await repository.transition(order.id, OrderStatus.PAID, payment_id="pay-1")
    assert changed and not changed_again and paid.status == again.status == OrderStatus.PAID
    with pytest.raises(InvalidTransition):
        await repository.transition(order.id, OrderStatus.FAILED, failure_reason="x")
    types = sorted(r["event_type"] for r in await pool.fetch("SELECT event_type FROM outbox_events"))
    assert types == ["order.created", "order.paid"]
    listed, total = await repository.list(10, 0)
    assert total == 1 and listed[0].id == order.id and listed[0].items == order.items


async def test_a_pending_order_can_be_marked_unavailable_and_completed_later(
    repository: PostgresOrderRepository,
) -> None:
    order, _ = await repository.create_or_get("k", "h", an_order())
    marked = await repository.mark_payment_unavailable(order.id)
    assert marked.failure_reason == "payment_unavailable" and marked.status == OrderStatus.PENDING
    paid, changed = await repository.transition(order.id, OrderStatus.PAID, payment_id="p")
    assert changed and paid.failure_reason is None


async def test_the_http_api_creates_one_order_and_one_payment_under_concurrency() -> None:
    orders = os.environ.get("ORDERS_URL", "http://localhost:8081")
    payments = os.environ.get("PAYMENTS_URL", "http://localhost:8082")
    body = {
        "customer_id": "cust-race",
        "items": [{"sku": "s", "quantity": 1, "unit_price_minor": 4200}],
        "currency": "USD",
    }
    key = f"race-{uuid.uuid4()}"
    async with httpx.AsyncClient(timeout=20) as client:
        responses = await asyncio.gather(
            *(client.post(f"{orders}/orders", json=body, headers={"Idempotency-Key": key}) for _ in range(30))
        )
        assert all(r.status_code in (200, 201) for r in responses), [r.status_code for r in responses]
        assert [r.status_code for r in responses].count(201) == 1
        assert len({r.json()["id"] for r in responses}) == 1
        assert len({r.json()["payment_id"] for r in responses}) == 1
        order = responses[0].json()
        # Authorizing the order's payment key again returns the stored payment instead of creating another.
        replay = await client.post(
            f"{payments}/payments/authorize",
            json={"order_id": order["id"], "amount_minor": 4200, "currency": "USD"},
            headers={"Idempotency-Key": f"order-{order['id']}"},
        )
        assert replay.status_code == 200 and replay.json()["id"] == order["payment_id"]


# --- outbox ---


def amqp_config(live_config: Config, **overrides: object) -> AmqpConfig:
    return AmqpConfig(**{**live_config.amqp.__dict__, **overrides})


async def bound_queue(live_config: Config) -> tuple[aio_pika.abc.AbstractRobustConnection, aio_pika.abc.AbstractQueue]:
    amqp = live_config.amqp
    connection = await aio_pika.connect_robust(host=amqp.host, port=amqp.port, login=amqp.user, password=amqp.password)
    channel = await connection.channel()
    exchange = await channel.declare_exchange(EXCHANGE, aio_pika.ExchangeType.TOPIC, durable=True)
    queue = await channel.declare_queue(exclusive=True, auto_delete=True)
    await queue.bind(exchange, routing_key="order.*")
    return connection, queue


async def next_matching(
    queue: aio_pika.abc.AbstractQueue, matches: Callable[[dict[str, Any]], bool], timeout_s: float = 10.0
) -> aio_pika.abc.AbstractIncomingMessage:
    """The first message whose decoded body satisfies `matches`.

    The queue is bound to the real exchange, which the running orders service also publishes to, so events of
    other orders can arrive here at any time. They are acknowledged and skipped.
    """
    deadline = asyncio.get_running_loop().time() + timeout_s
    while True:
        message = await queue.get(fail=False, timeout=timeout_s)
        if message is not None:
            await message.ack()
            if matches(json.loads(message.body)):
                return message
            continue
        if asyncio.get_running_loop().time() >= deadline:
            raise TimeoutError("no matching message arrived")
        await asyncio.sleep(0.05)


def relay_for(pool: asyncpg.Pool, publisher, metrics: OutboxMetrics, batch: int = 20) -> OutboxRelay:
    return OutboxRelay(
        pool, publisher, DbMetrics(CollectorRegistry()), metrics, JsonLogger("orders", "error", io.StringIO()),
        batch_size=batch, poll_interval_s=0.05, max_backoff_s=1,
    )  # fmt: skip


async def test_the_relay_publishes_persistent_messages_with_correlation_headers(
    live_config: Config, repository: PostgresOrderRepository, pool: asyncpg.Pool, outbox_metrics: OutboxMetrics
) -> None:
    request_id_var.set("req-integration-1")
    trace_var.set(("0af7651916cd43dd8448eb211c80319c", "01"))
    order, _ = await repository.create_or_get("k", "h", an_order())
    connection, queue = await bound_queue(live_config)
    publisher = AmqpPublisher(live_config.amqp)
    try:
        assert await relay_for(pool, publisher, outbox_metrics).publish_batch() == 1
        message = await next_matching(
            queue, lambda e: e["type"] == "order.created" and e["data"]["order_id"] == order.id
        )
        event = json.loads(message.body)
        assert event["schema_version"] == 1
        assert message.delivery_mode == aio_pika.DeliveryMode.PERSISTENT
        assert message.headers["event_id"] == event["event_id"] == message.message_id
        assert message.headers["event_type"] == "order.created" and message.headers["schema_version"] == 1
        assert message.headers["request_id"] == "req-integration-1"
        assert message.headers["traceparent"].startswith("00-0af7651916cd43dd8448eb211c80319c-")
        assert await count(pool, "outbox_events", "published_at IS NULL") == 0
    finally:
        await publisher.close()
        await connection.close()


async def test_events_survive_a_broker_outage_and_publish_afterwards(
    live_config: Config, repository: PostgresOrderRepository, pool: asyncpg.Pool, outbox_metrics: OutboxMetrics
) -> None:
    for i in range(3):
        await repository.create_or_get(f"k{i}", f"h{i}", an_order())
    unreachable = AmqpPublisher(amqp_config(live_config, port=1, connect_timeout_s=0.5))
    relay = relay_for(pool, unreachable, outbox_metrics)
    with pytest.raises(Exception):  # noqa: B017 - any broker failure
        await relay.publish_batch()
    assert await count(pool, "outbox_events", "published_at IS NULL") == 3  # nothing was lost
    assert await pool.fetchval("SELECT min(attempts) FROM outbox_events") == 0
    await relay.refresh_gauges()
    assert outbox_metrics.unpublished._value.get() == 3
    assert outbox_metrics.oldest_age._value.get() >= 0

    connection, queue = await bound_queue(live_config)
    working = AmqpPublisher(live_config.amqp)
    try:
        assert await relay_for(pool, working, outbox_metrics).publish_batch() == 3
        wanted = {str(r["id"]) for r in await pool.fetch("SELECT id FROM outbox_events")}
        assert len(wanted) == 3
        received: set[str] = set()
        while received != wanted:
            message = await next_matching(queue, lambda e: e["event_id"] in wanted - received)
            received.add(json.loads(message.body)["event_id"])
        assert await count(pool, "outbox_events", "published_at IS NULL") == 0
    finally:
        await working.close()
        await unreachable.close()
        await connection.close()


async def test_a_partial_failure_commits_what_was_confirmed(
    repository: PostgresOrderRepository, pool: asyncpg.Pool, outbox_metrics: OutboxMetrics
) -> None:
    for i in range(4):
        await repository.create_or_get(f"k{i}", f"h{i}", an_order())

    class FailsOnThird:
        def __init__(self) -> None:
            self.sent: list[str] = []

        async def publish(self, event: OutboxEvent) -> None:
            if len(self.sent) == 2:
                raise ConnectionError("broker went away")
            self.sent.append(event.id)

    publisher = FailsOnThird()
    with pytest.raises(ConnectionError):
        await relay_for(pool, publisher, outbox_metrics).publish_batch()  # type: ignore[arg-type]
    assert await count(pool, "outbox_events", "published_at IS NOT NULL") == 2
    assert await count(pool, "outbox_events", "published_at IS NULL") == 2


async def test_two_relays_never_publish_the_same_event(
    repository: PostgresOrderRepository, pool: asyncpg.Pool, outbox_metrics: OutboxMetrics
) -> None:
    for i in range(12):
        await repository.create_or_get(f"k{i}", f"h{i}", an_order())

    class Recording:
        def __init__(self) -> None:
            self.sent: list[str] = []

        async def publish(self, event: OutboxEvent) -> None:
            await asyncio.sleep(0.02)
            self.sent.append(event.id)

    a, b = Recording(), Recording()
    await asyncio.gather(
        relay_for(pool, a, outbox_metrics, batch=6).publish_batch(),  # type: ignore[arg-type]
        relay_for(pool, b, outbox_metrics, batch=6).publish_batch(),  # type: ignore[arg-type]
    )
    assert len(a.sent) + len(b.sent) == 12 and not set(a.sent) & set(b.sent)


# --- cache ---


def cache_for(live_config: Config, **overrides: object) -> tuple[ValkeyCache, CollectorRegistry]:
    registry = CollectorRegistry()
    config = CacheConfig(**{**live_config.cache_config.__dict__, "timeout_s": 0.5, **overrides})
    return ValkeyCache.from_config(
        config, CacheMetrics(registry), JsonLogger("orders", "error", io.StringIO())
    ), registry


def results(registry: CollectorRegistry) -> dict[str, float]:
    return {
        r: registry.get_sample_value("cache_requests_total", {"result": r}) or 0.0 for r in ("hit", "miss", "error")
    }


async def test_valkey_round_trip_and_invalidation(live_config: Config) -> None:
    cache, registry = cache_for(live_config)
    order = an_order()
    try:
        await cache.ready()
        assert await cache.get(order.id) is None
        await cache.set(order)
        assert await cache.get(order.id) == order
        await cache.invalidate(order.id)
        assert await cache.get(order.id) is None
        assert results(registry) == {"hit": 1, "miss": 2, "error": 0}
    finally:
        await cache.close()


async def test_a_cache_with_the_wrong_password_or_no_server_is_only_ever_a_miss(live_config: Config) -> None:
    for overrides in ({"password": "definitely-wrong"}, {"port": 1}):
        cache, registry = cache_for(live_config, **overrides)
        try:
            assert await cache.get("anything") is None
            await cache.set(an_order())
            await cache.invalidate("anything")
            assert results(registry)["error"] == 3
            with pytest.raises(Exception):  # noqa: B017
                await cache.ready()
        finally:
            await cache.close()
