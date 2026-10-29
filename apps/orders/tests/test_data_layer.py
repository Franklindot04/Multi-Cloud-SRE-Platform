"""Unit tests for the data-layer switches: configuration, cache failure behaviour, readiness and migrations."""

from __future__ import annotations

import asyncio
import io
import json
from datetime import UTC, datetime
from pathlib import Path

import httpx
import pytest
from prometheus_client import CollectorRegistry

from orders.api import create_app
from orders.cache import ValkeyCache
from orders.config import CacheConfig, Config, ConfigError
from orders.metrics import CacheMetrics
from orders.migrate import MigrationError, checksum, discover
from orders.models import CreateOrderRequest, Order, OrderItem, OrderStatus
from orders.observability import JsonLogger
from orders.repository import MemoryOrderRepository
from orders.service import OrderService
from tests.conftest import FakeNotifier, FakePayments, make_config

NOW = datetime(2026, 1, 1, tzinfo=UTC)
POSTGRES = {"STORAGE": "postgres", "DB_PASSWORD": "x"}


# --- configuration ---


def test_defaults_keep_the_in_memory_http_setup() -> None:
    config = Config.load({})
    assert (config.storage, config.cache, config.messaging) == ("memory", "none", "http")


def test_switches_are_validated() -> None:
    for name, value in (("STORAGE", "mysql"), ("CACHE", "redis"), ("MESSAGING", "kafka")):
        with pytest.raises(ConfigError, match=name):
            Config.load({name: value})


def test_rabbitmq_needs_postgres_for_the_outbox() -> None:
    with pytest.raises(ConfigError, match="STORAGE=postgres"):
        Config.load({"MESSAGING": "rabbitmq", "AMQP_PASSWORD": "x"})


def test_required_passwords_are_reported_together() -> None:
    with pytest.raises(ConfigError) as err:
        Config.load({"STORAGE": "postgres", "CACHE": "valkey", "MESSAGING": "rabbitmq"})
    text = str(err.value)
    assert "DB_PASSWORD" in text and "CACHE_PASSWORD" in text and "AMQP_PASSWORD" in text


def test_password_can_come_from_a_mounted_file(tmp_path: Path) -> None:
    secret = tmp_path / "db-password"
    secret.write_text("from-file\n")
    config = Config.load({"STORAGE": "postgres", "DB_PASSWORD_FILE": str(secret)})
    assert config.db.password == "from-file"


def test_password_value_and_file_together_are_rejected(tmp_path: Path) -> None:
    secret = tmp_path / "db-password"
    secret.write_text("x")
    with pytest.raises(ConfigError, match="DB_PASSWORD"):
        Config.load({"STORAGE": "postgres", "DB_PASSWORD": "y", "DB_PASSWORD_FILE": str(secret)})


def test_unreadable_or_empty_password_file_is_rejected(tmp_path: Path) -> None:
    empty = tmp_path / "empty"
    empty.write_text("\n")
    for path in (empty, tmp_path / "missing"):
        with pytest.raises(ConfigError, match="DB_PASSWORD_FILE"):
            Config.load({"STORAGE": "postgres", "DB_PASSWORD_FILE": str(path)})


def test_pool_bounds_are_validated() -> None:
    with pytest.raises(ConfigError, match="DB_POOL"):
        Config.load({**POSTGRES, "DB_POOL_MIN": "6", "DB_POOL_MAX": "5"})


def test_passwords_do_not_appear_in_repr() -> None:
    config = Config.load({**POSTGRES, "DB_PASSWORD": "super-secret-value"})
    assert "super-secret-value" not in repr(config)


# --- cache: every failure is a miss ---


class FakeValkey:
    def __init__(self) -> None:
        self.store: dict[str, bytes] = {}
        self.error: Exception | None = None
        self.delay = 0.0

    async def _maybe_fail(self) -> None:
        if self.delay:
            await asyncio.sleep(self.delay)
        if self.error:
            raise self.error

    async def get(self, key: str) -> bytes | None:
        await self._maybe_fail()
        return self.store.get(key)

    async def set(self, key: str, value: str, ex: int) -> None:
        await self._maybe_fail()
        self.store[key] = value.encode()

    async def delete(self, key: str) -> None:
        await self._maybe_fail()
        self.store.pop(key, None)

    async def ping(self) -> None:
        await self._maybe_fail()

    async def aclose(self) -> None:
        return None


def an_order(order_id: str = "o1") -> Order:
    return Order(
        id=order_id,
        customer_id="c",
        items=[OrderItem(sku="s", quantity=1, unit_price_minor=100)],
        currency="USD",
        total_minor=100,
        status=OrderStatus.PENDING,
        created_at=NOW,
        updated_at=NOW,
    )


def make_cache(client: FakeValkey, logs: io.StringIO | None = None, timeout_s: float = 0.05):
    registry = CollectorRegistry()
    metrics = CacheMetrics(registry)
    config = CacheConfig(host="h", port=6379, password="x", ttl_seconds=30, timeout_s=timeout_s)
    cache = ValkeyCache(client, config, metrics, JsonLogger("orders", "info", logs or io.StringIO()))
    return cache, registry


def count(registry: CollectorRegistry, result: str) -> float:
    return registry.get_sample_value("cache_requests_total", {"result": result}) or 0.0


async def test_cache_hit_and_miss_are_counted() -> None:
    cache, registry = make_cache(FakeValkey())
    assert await cache.get("o1") is None
    await cache.set(an_order())
    assert (await cache.get("o1")) == an_order()
    assert (count(registry, "miss"), count(registry, "hit"), count(registry, "error")) == (1, 1, 0)


async def test_invalidate_removes_the_entry() -> None:
    cache, _ = make_cache(FakeValkey())
    await cache.set(an_order())
    await cache.invalidate("o1")
    assert await cache.get("o1") is None


async def test_errors_are_misses_that_are_counted_and_logged_at_warn() -> None:
    client, logs = FakeValkey(), io.StringIO()
    cache, registry = make_cache(client, logs)
    client.error = ConnectionError("down")
    assert await cache.get("o1") is None
    await cache.set(an_order())
    await cache.invalidate("o1")
    assert count(registry, "error") == 3
    entries = [json.loads(line) for line in logs.getvalue().splitlines()]
    assert {e["level"] for e in entries} == {"warn"} and len(entries) == 3


async def test_a_slow_cache_times_out_as_a_miss() -> None:
    client = FakeValkey()
    cache, registry = make_cache(client, timeout_s=0.02)
    await cache.set(an_order())
    client.delay = 1.0
    assert await cache.get("o1") is None
    assert count(registry, "error") == 1


async def test_a_corrupt_entry_is_a_miss() -> None:
    client = FakeValkey()
    client.store["order:o1"] = b"not json"
    cache, registry = make_cache(client)
    assert await cache.get("o1") is None
    assert count(registry, "error") == 1


async def test_orders_can_be_created_and_read_while_the_cache_is_down() -> None:
    client = FakeValkey()
    client.error = ConnectionError("down")
    cache, _ = make_cache(client)
    service = OrderService(MemoryOrderRepository(), FakePayments(), FakeNotifier(), cache)
    request = CreateOrderRequest(
        customer_id="c", items=[OrderItem(sku="s", quantity=1, unit_price_minor=100)], currency="USD"
    )
    result = await service.create("k1", request)
    assert result.http_status == 201 and result.order.status == OrderStatus.PAID
    assert (await service.get(result.order.id)) == result.order


async def test_a_read_is_served_from_the_cache_and_a_change_invalidates_it() -> None:
    client = FakeValkey()
    cache, registry = make_cache(client)
    repo = MemoryOrderRepository()
    payments = FakePayments()
    service = OrderService(repo, payments, FakeNotifier(), cache)
    request = CreateOrderRequest(
        customer_id="c", items=[OrderItem(sku="s", quantity=1, unit_price_minor=100)], currency="USD"
    )
    result = await service.create("k1", request)
    await service.get(result.order.id)  # miss, then stored
    await service.get(result.order.id)  # hit
    assert (count(registry, "miss"), count(registry, "hit")) == (1, 1)
    await cache.invalidate(result.order.id)
    assert "order:" + result.order.id not in client.store


# --- readiness per dependency ---


class FailingReady(MemoryOrderRepository):
    async def ready(self) -> None:
        raise ConnectionError("db down")


class FakeDependency:
    def __init__(self) -> None:
        self.error: Exception | None = None

    async def ready(self) -> None:
        if self.error:
            raise self.error

    async def close(self) -> None:
        return None

    async def get(self, order_id: str) -> None:
        return None

    async def set(self, order: Order) -> None:
        return None

    async def invalidate(self, order_id: str) -> None:
        return None

    async def publish(self, event) -> None:
        return None


async def ready(app) -> httpx.Response:
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        return await c.get("/readyz")


def app_with(**kwargs):
    return create_app(
        make_config(),
        payments=FakePayments(),
        notifier=FakeNotifier(),
        logger=JsonLogger("orders", "info", io.StringIO()),
        **kwargs,
    )


async def test_readiness_fails_when_postgres_is_down() -> None:
    config = make_config(storage="postgres")
    app = create_app(config, repo=FailingReady(), payments=FakePayments(), notifier=FakeNotifier())
    response = await ready(app)
    assert response.status_code == 503 and response.json()["checks"]["postgres"] == "fail: ConnectionError"


async def test_readiness_reports_postgres_when_it_is_up() -> None:
    config = make_config(storage="postgres")
    app = create_app(config, repo=MemoryOrderRepository(), payments=FakePayments(), notifier=FakeNotifier())
    response = await ready(app)
    assert response.status_code == 200 and response.json()["checks"]["postgres"] == "ok"


async def test_valkey_down_is_degraded_not_unready() -> None:
    cache = FakeDependency()
    cache.error = ConnectionError("down")
    app = create_app(make_config(cache="valkey"), cache=cache, payments=FakePayments(), notifier=FakeNotifier())
    response = await ready(app)
    assert response.status_code == 200 and response.json()["checks"]["valkey"] == "degraded: ConnectionError"


async def test_rabbitmq_down_is_degraded_not_unready() -> None:
    publisher = FakeDependency()
    publisher.error = ConnectionError("down")
    app = create_app(
        make_config(storage="postgres", messaging="rabbitmq"),
        repo=MemoryOrderRepository(),
        publisher=publisher,
        payments=FakePayments(),
        notifier=FakeNotifier(),
    )
    response = await ready(app)
    body = response.json()
    assert response.status_code == 200 and body["checks"]["rabbitmq"] == "degraded: ConnectionError"
    assert "notifier" not in body["checks"]  # events go through the outbox in this mode


async def test_the_http_notifier_is_not_called_when_events_go_through_the_outbox() -> None:
    notifier = FakeNotifier()
    service = OrderService(MemoryOrderRepository(), FakePayments(), notifier, notify_over_http=False)
    request = CreateOrderRequest(
        customer_id="c", items=[OrderItem(sku="s", quantity=1, unit_price_minor=100)], currency="USD"
    )
    await service.create("k1", request)
    assert notifier.notified == []


# --- migrations ---


def test_migrations_are_numbered_and_checksummed() -> None:
    found = discover()
    versions = [v for v, _, _ in found]
    assert versions == sorted(versions) and versions[0] == "0001"
    assert all(len(checksum(sql)) == 64 for _, _, sql in found)


def test_migrations_do_not_contain_destructive_statements() -> None:
    # Forward-only: a migration never drops or rewrites existing data.
    for _, name, sql in discover():
        upper = sql.upper()
        assert "DROP TABLE" not in upper and "TRUNCATE" not in upper, name


def test_duplicate_or_misnamed_migrations_are_rejected(tmp_path: Path) -> None:
    (tmp_path / "0001_a.sql").write_text("SELECT 1;")
    (tmp_path / "0001_b.sql").write_text("SELECT 1;")
    with pytest.raises(MigrationError):
        discover(tmp_path)


# --- migrate: waiting for a database that is not ready yet ---


class FakeClock:
    def __init__(self) -> None:
        self.now = 0.0
        self.slept: list[float] = []

    def __call__(self) -> float:
        return self.now

    async def sleep(self, seconds: float) -> None:
        self.slept.append(seconds)
        self.now += seconds


def a_db():
    from orders.config import DbConfig

    return DbConfig(
        host="h", port=5432, name="orders", user="orders", password="x", pool_min=1, pool_max=2,
        max_inactive_lifetime_s=1, connect_timeout_s=1, statement_timeout_ms=1000,
    )  # fmt: skip


async def test_migrate_waits_while_the_database_is_not_ready_then_connects() -> None:
    import asyncpg

    from orders.migrate import connect_when_ready

    clock, messages, calls = FakeClock(), [], []

    async def connect(**_kwargs):
        calls.append(1)
        if len(calls) == 1:
            raise ConnectionRefusedError("refused")
        if len(calls) == 2:
            raise asyncpg.InvalidPasswordError("password authentication failed")
        return "connection"

    result = await connect_when_ready(
        a_db(), 60, 5, connect=connect, sleep=clock.sleep, clock=clock, log=messages.append
    )
    assert result == "connection" and clock.slept == [5, 5]
    assert len(messages) == 2 and "retrying in 5s" in messages[0] and "InvalidPasswordError" in messages[1]


async def test_migrate_gives_up_at_the_deadline_and_default_does_not_wait() -> None:
    import asyncpg
    import pytest

    from orders.migrate import connect_when_ready

    clock = FakeClock()

    async def never_ready(**_kwargs):
        raise asyncpg.InvalidCatalogNameError('database "orders" does not exist')

    with pytest.raises(asyncpg.InvalidCatalogNameError):
        await connect_when_ready(
            a_db(), 12, 5, connect=never_ready, sleep=clock.sleep, clock=clock, log=lambda _m: None
        )
    assert clock.slept == [5, 5]  # two waits fit in 12 seconds, the third would not

    clock = FakeClock()
    with pytest.raises(asyncpg.InvalidCatalogNameError):
        await connect_when_ready(a_db(), 0, 5, connect=never_ready, sleep=clock.sleep, clock=clock, log=lambda _m: None)
    assert clock.slept == []


async def test_migrate_does_not_retry_errors_that_are_not_about_readiness() -> None:
    import pytest

    from orders.migrate import connect_when_ready

    calls = []

    async def broken(**_kwargs):
        calls.append(1)
        raise ValueError("bad argument")

    with pytest.raises(ValueError, match="bad argument"):
        await connect_when_ready(a_db(), 60, 5, connect=broken, sleep=FakeClock().sleep, log=lambda _m: None)
    assert calls == [1]


def test_migrate_wait_settings_are_validated(monkeypatch) -> None:
    import pytest

    from orders.migrate import _wait_settings

    monkeypatch.delenv("MIGRATE_WAIT_SECONDS", raising=False)
    assert _wait_settings() == (0, 5.0)
    monkeypatch.setenv("MIGRATE_WAIT_SECONDS", "600")
    assert _wait_settings() == (600, 5.0)
    monkeypatch.setenv("MIGRATE_WAIT_SECONDS", "99999")
    with pytest.raises(ConfigError):
        _wait_settings()
    monkeypatch.setenv("MIGRATE_WAIT_SECONDS", "soon")
    with pytest.raises(ConfigError):
        _wait_settings()
