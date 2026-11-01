"""PostgreSQL implementation of the order repository, with a transactional outbox."""

from __future__ import annotations

import json
import time
import uuid
from contextlib import ExitStack
from datetime import UTC, datetime
from typing import Any

import asyncpg
from opentelemetry import trace

from orders.config import DbConfig
from orders.metrics import DbMetrics
from orders.models import IdempotencyMismatch, InvalidTransition, Order, OrderItem, OrderStatus
from orders.observability import JsonLogger, outbound_headers, request_id_var
from orders.repository import OrderRepository

SLOW_QUERY_SECONDS = 0.5
EVENT_SCHEMA_VERSION = 1


async def create_pool(config: DbConfig, application_name: str = "orders") -> asyncpg.Pool:
    """A bounded pool: connections are recycled after sitting idle, and every statement has a timeout."""
    return await asyncpg.create_pool(
        host=config.host,
        port=config.port,
        user=config.user,
        password=config.password,
        database=config.name,
        min_size=config.pool_min,
        max_size=config.pool_max,
        max_inactive_connection_lifetime=config.max_inactive_lifetime_s,
        max_queries=50_000,
        timeout=config.connect_timeout_s,
        command_timeout=config.statement_timeout_ms / 1000 + 1,
        server_settings={
            "application_name": application_name,
            "statement_timeout": str(config.statement_timeout_ms),
            "timezone": "UTC",
        },
    )


def pool_sizes(pool: asyncpg.Pool) -> dict[str, int]:
    size, idle = pool.get_size(), pool.get_idle_size()
    return {"idle": idle, "in_use": size - idle, "max": pool.get_max_size()}


def _order_from(row: asyncpg.Record, items: list[asyncpg.Record]) -> Order:
    return Order(
        id=str(row["id"]),
        customer_id=row["customer_id"],
        items=[OrderItem(sku=i["sku"], quantity=i["quantity"], unit_price_minor=i["unit_price_minor"]) for i in items],
        currency=row["currency"],
        total_minor=row["total_minor"],
        status=OrderStatus(row["status"]),
        payment_id=row["payment_id"],
        failure_reason=row["failure_reason"],
        created_at=row["created_at"].astimezone(UTC),
        updated_at=row["updated_at"].astimezone(UTC),
    )


class PostgresOrderRepository(OrderRepository):
    def __init__(
        self,
        pool: asyncpg.Pool,
        metrics: DbMetrics,
        logger: JsonLogger,
        *,
        emit_events: bool,
        tracer: trace.Tracer | None = None,
    ) -> None:
        self._pool = pool
        self._tracer = tracer or trace.NoOpTracer()
        self._metrics = metrics
        self._logger = logger
        self._emit = emit_events

    # --- helpers ---

    async def _load(self, conn: asyncpg.Connection, order_id: uuid.UUID) -> Order | None:
        row = await conn.fetchrow("SELECT * FROM orders WHERE id = $1", order_id)
        if row is None:
            return None
        items = await conn.fetch("SELECT * FROM order_items WHERE order_id = $1 ORDER BY position", order_id)
        return _order_from(row, items)

    async def _insert_event(self, conn: asyncpg.Connection, event_type: str, order: Order) -> None:
        """Write an outbox event in the caller's transaction, tagged with the request ID and trace."""
        if not self._emit:
            return
        event_id = uuid.uuid4()
        headers = outbound_headers()
        payload: dict[str, Any] = {
            "event_id": str(event_id),
            "type": event_type,
            "schema_version": EVENT_SCHEMA_VERSION,
            "occurred_at": datetime.now(UTC).isoformat(timespec="milliseconds"),
            "aggregate_id": order.id,
            "data": {
                "order_id": order.id,
                "customer_id": order.customer_id,
                "status": order.status.value,
                "total_minor": order.total_minor,
                "currency": order.currency,
                "payment_id": order.payment_id,
                "failure_reason": order.failure_reason,
            },
        }
        await conn.execute(
            "INSERT INTO outbox_events (id, event_type, aggregate_id, payload, request_id, traceparent) "
            "VALUES ($1, $2, $3, $4::jsonb, $5, $6)",
            event_id,
            event_type,
            uuid.UUID(order.id),
            json.dumps(payload),
            headers.get("X-Request-Id"),
            headers.get("traceparent"),
        )

    def _timed(self, operation: str):
        return _Timed(self._metrics, self._logger, self._tracer, operation)

    # --- OrderRepository ---

    async def create_or_get(self, key: str, fingerprint: str, order: Order) -> tuple[Order, bool]:
        order_id = uuid.UUID(order.id)
        with self._timed("create_order"):
            try:
                return await self._create_or_get(key, fingerprint, order, order_id)
            except asyncpg.UniqueViolationError:
                # A concurrent request claimed the key between our statements: this is a replay, not an error.
                async with self._pool.acquire() as conn:
                    return await self._existing(conn, key, fingerprint), False

    async def _existing(self, conn: asyncpg.Connection, key: str, fingerprint: str) -> Order:
        existing = await conn.fetchrow("SELECT request_hash, order_id FROM idempotency_keys WHERE key = $1", key)
        if existing is None:
            raise RuntimeError("idempotency key vanished while resolving a replay")
        if existing["request_hash"] != fingerprint:
            raise IdempotencyMismatch(key)
        order = await self._load(conn, existing["order_id"])
        if order is None:
            raise RuntimeError("idempotency key refers to a missing order")
        return order

    async def _create_or_get(self, key: str, fingerprint: str, order: Order, order_id: uuid.UUID) -> tuple[Order, bool]:
        async with self._pool.acquire() as conn, conn.transaction():
            # Claiming the key first makes concurrent requests with the same key wait here until the first
            # one commits; the loser then sees the committed row and returns it.
            claimed = await conn.fetchrow(
                "INSERT INTO idempotency_keys (key, request_hash, order_id) VALUES ($1, $2, $3) "
                "ON CONFLICT (key) DO NOTHING RETURNING order_id",
                key,
                fingerprint,
                order_id,
            )
            if claimed is None:
                return await self._existing(conn, key, fingerprint), False
            await conn.execute(
                "INSERT INTO orders (id, customer_id, currency, total_minor, status, created_at, updated_at) "
                "VALUES ($1, $2, $3, $4, $5, $6, $6)",
                order_id,
                order.customer_id,
                order.currency,
                order.total_minor,
                order.status.value,
                order.created_at,
            )
            await conn.executemany(
                "INSERT INTO order_items (order_id, position, sku, quantity, unit_price_minor) "
                "VALUES ($1, $2, $3, $4, $5)",
                [(order_id, i, it.sku, it.quantity, it.unit_price_minor) for i, it in enumerate(order.items)],
            )
            await self._insert_event(conn, "order.created", order)
            return order, True

    async def get(self, order_id: str) -> Order | None:
        try:
            oid = uuid.UUID(order_id)
        except ValueError:
            return None
        with self._timed("get_order"):
            async with self._pool.acquire() as conn:
                return await self._load(conn, oid)

    async def list(self, limit: int, offset: int) -> tuple[list[Order], int]:
        with self._timed("list_orders"):
            async with self._pool.acquire() as conn:
                rows = await conn.fetch(
                    "SELECT * FROM orders ORDER BY created_at DESC, id DESC LIMIT $1 OFFSET $2", limit, offset
                )
                total = await conn.fetchval("SELECT count(*) FROM orders")
                items = await conn.fetch(
                    "SELECT * FROM order_items WHERE order_id = ANY($1::uuid[]) ORDER BY order_id, position",
                    [r["id"] for r in rows],
                )
            by_order: dict[uuid.UUID, list[asyncpg.Record]] = {}
            for item in items:
                by_order.setdefault(item["order_id"], []).append(item)
            return [_order_from(r, by_order.get(r["id"], [])) for r in rows], int(total)

    async def transition(
        self,
        order_id: str,
        new_status: OrderStatus,
        *,
        payment_id: str | None = None,
        failure_reason: str | None = None,
    ) -> tuple[Order, bool]:
        oid = uuid.UUID(order_id)
        with self._timed("transition_order"):
            async with self._pool.acquire() as conn, conn.transaction():
                # Only a pending order can move; the WHERE clause makes concurrent settlements safe.
                row = await conn.fetchrow(
                    "UPDATE orders SET status = $2, payment_id = $3, failure_reason = $4, updated_at = now() "
                    "WHERE id = $1 AND status = 'pending' RETURNING id",
                    oid,
                    new_status.value,
                    payment_id,
                    failure_reason,
                )
                order = await self._load(conn, oid)
                if order is None:
                    raise KeyError(order_id)
                if row is not None:
                    await self._insert_event(conn, f"order.{new_status.value}", order)
                    return order, True
                if order.status == new_status:
                    return order, False
                raise InvalidTransition(f"cannot move an order from {order.status} to {new_status}")

    async def mark_payment_unavailable(self, order_id: str) -> Order:
        oid = uuid.UUID(order_id)
        with self._timed("mark_payment_unavailable"):
            async with self._pool.acquire() as conn:
                await conn.execute(
                    "UPDATE orders SET failure_reason = 'payment_unavailable', updated_at = now() "
                    "WHERE id = $1 AND status = 'pending'",
                    oid,
                )
                order = await self._load(conn, oid)
        if order is None:
            raise KeyError(order_id)
        return order

    async def ready(self) -> None:
        async with self._pool.acquire() as conn:
            await conn.fetchval("SELECT 1")


class _Timed:
    """Times one repository operation for the metrics, wraps it in a span and logs a slow query with the request ID.

    The span is named after the operation ("db create_order"), a fixed set of names. It carries no SQL text and no
    parameters, and a failure records the type of the error, not its message, because a database error message can
    contain the values of the statement.
    """

    def __init__(self, metrics: DbMetrics, logger: JsonLogger, tracer: trace.Tracer, operation: str) -> None:
        self._cm = metrics.timed(operation)
        self._logger = logger
        self._tracer = tracer
        self._operation = operation
        self._stack = ExitStack()

    def __enter__(self) -> None:
        self._start = time.perf_counter()
        self._cm.__enter__()
        self._span = self._stack.enter_context(
            self._tracer.start_as_current_span(
                f"db {self._operation}",
                kind=trace.SpanKind.CLIENT,
                attributes={"db.system.name": "postgresql", "db.operation.name": self._operation},
                record_exception=False,
                set_status_on_exception=False,
            )
        )

    def __exit__(self, exc_type: type[BaseException] | None, exc: BaseException | None, tb: object) -> None:
        if exc_type is not None:
            self._span.add_event("exception", {"exception.type": exc_type.__name__})
            self._span.set_status(trace.Status(trace.StatusCode.ERROR, "database operation failed"))
        self._stack.close()
        self._cm.__exit__(exc_type, exc, tb)
        elapsed = time.perf_counter() - self._start
        if elapsed > SLOW_QUERY_SECONDS:
            self._logger.warn(
                "slow database operation",
                operation=self._operation,
                duration_ms=round(elapsed * 1000, 1),
                request_id=request_id_var.get(),
            )
