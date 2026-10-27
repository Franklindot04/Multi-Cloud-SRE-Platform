"""Integration tests run against the real PostgreSQL, Valkey and RabbitMQ of the local integration stack.

They are skipped unless INTEGRATION=1, so the plain unit-test run needs nothing. The connection settings come
from the same environment variables the service reads (DB_*, CACHE_*, AMQP_*); scripts/integration-test.sh
sets them from apps/.env. Database tests work in a scratch schema, so they never touch the data of the
running services.
"""

from __future__ import annotations

import io
import os
import uuid
from collections.abc import AsyncIterator

import asyncpg
import pytest
from prometheus_client import CollectorRegistry

from orders.config import Config
from orders.metrics import DbMetrics, OutboxMetrics
from orders.migrate import discover, migrate
from orders.observability import JsonLogger
from orders.postgres import PostgresOrderRepository


def pytest_collection_modifyitems(config: pytest.Config, items: list[pytest.Item]) -> None:
    if os.environ.get("INTEGRATION") == "1":
        return
    skip = pytest.mark.skip(reason="set INTEGRATION=1 and start the integration stack")
    for item in items:
        if "integration" in item.keywords:
            item.add_marker(skip)


@pytest.fixture(scope="session")
def live_config() -> Config:
    return Config.load(
        {
            **os.environ,
            "STORAGE": "postgres",
            "CACHE": "valkey",
            "MESSAGING": "rabbitmq",
            "DB_HOST": os.environ.get("DB_HOST", "localhost"),
        }
    )


@pytest.fixture
async def schema(live_config: Config) -> AsyncIterator[str]:
    db = live_config.db
    name = "it_" + uuid.uuid4().hex[:12]
    conn = await asyncpg.connect(host=db.host, port=db.port, database=db.name, user=db.user, password=db.password)
    try:
        await conn.execute(f'CREATE SCHEMA "{name}"')
        yield name
    finally:
        await conn.execute(f'DROP SCHEMA "{name}" CASCADE')
        await conn.close()


@pytest.fixture
async def pool(live_config: Config, schema: str) -> AsyncIterator[asyncpg.Pool]:
    db = live_config.db
    pool = await asyncpg.create_pool(
        host=db.host,
        port=db.port,
        database=db.name,
        user=db.user,
        password=db.password,
        min_size=1,
        max_size=20,
        server_settings={"search_path": schema},
    )
    async with pool.acquire() as conn:
        await migrate(conn, discover())
    try:
        yield pool
    finally:
        await pool.close()


@pytest.fixture
def logs() -> io.StringIO:
    return io.StringIO()


@pytest.fixture
def repository(pool: asyncpg.Pool, logs: io.StringIO) -> PostgresOrderRepository:
    return PostgresOrderRepository(
        pool, DbMetrics(CollectorRegistry()), JsonLogger("orders", "debug", logs), emit_events=True
    )


@pytest.fixture
def outbox_metrics() -> OutboxMetrics:
    return OutboxMetrics(CollectorRegistry())
