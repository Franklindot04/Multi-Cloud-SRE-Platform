"""The outbox relay: publishes events that were written in the same transaction as the order change.

Each cycle locks a small batch of unpublished rows with FOR UPDATE SKIP LOCKED (so several replicas share the work
without publishing the same row twice at once), publishes them to the broker with publisher confirms, and marks a
row published only after the broker confirmed it. A failure commits what was already confirmed, leaves the rest
unpublished and backs off, so no event is lost; a crash between a confirm and the commit republishes that event,
which is why delivery is at least once and consumers must be idempotent.
"""

from __future__ import annotations

import asyncio
import contextlib
import uuid

import asyncpg

from orders.messaging import EventPublisher, OutboxEvent
from orders.metrics import DbMetrics, OutboxMetrics
from orders.observability import JsonLogger


class OutboxRelay:
    def __init__(
        self,
        pool: asyncpg.Pool,
        publisher: EventPublisher,
        db_metrics: DbMetrics,
        metrics: OutboxMetrics,
        logger: JsonLogger,
        *,
        batch_size: int,
        poll_interval_s: float,
        max_backoff_s: float,
    ) -> None:
        self._pool = pool
        self._publisher = publisher
        self._db = db_metrics
        self._metrics = metrics
        self._logger = logger
        self._batch = batch_size
        self._poll = poll_interval_s
        self._max_backoff = max_backoff_s

    async def publish_batch(self) -> int:
        """Publish one batch. Returns how many events were confirmed; raises after committing if one failed."""
        failure: Exception | None = None
        confirmed = 0
        with self._db.timed("outbox_relay"):
            async with self._pool.acquire() as conn, conn.transaction():
                rows = await conn.fetch(
                    "SELECT id, event_type, aggregate_id, payload::text AS payload, request_id, traceparent "
                    "FROM outbox_events WHERE published_at IS NULL ORDER BY created_at, id "
                    "LIMIT $1 FOR UPDATE SKIP LOCKED",
                    self._batch,
                )
                for row in rows:
                    event = OutboxEvent(
                        id=str(row["id"]),
                        event_type=row["event_type"],
                        aggregate_id=str(row["aggregate_id"]),
                        payload=row["payload"],
                        request_id=row["request_id"],
                        traceparent=row["traceparent"],
                    )
                    try:
                        await self._publisher.publish(event)
                    except Exception as exc:
                        failure = exc
                        self._metrics.published.labels("error").inc()
                        await conn.execute("UPDATE outbox_events SET attempts = attempts + 1 WHERE id = $1", row["id"])
                        break
                    await conn.execute(
                        "UPDATE outbox_events SET published_at = now(), attempts = attempts + 1 WHERE id = $1",
                        row["id"],
                    )
                    self._metrics.published.labels("ok").inc()
                    confirmed += 1
        if failure is not None:
            raise failure
        return confirmed

    async def refresh_gauges(self) -> None:
        async with self._pool.acquire() as conn:
            row = await conn.fetchrow(
                "SELECT count(*) AS n, COALESCE(EXTRACT(EPOCH FROM now() - min(created_at)), 0) AS age "
                "FROM outbox_events WHERE published_at IS NULL"
            )
        self._metrics.unpublished.set(row["n"])
        self._metrics.oldest_age.set(float(row["age"]))

    async def run(self, stop: asyncio.Event) -> None:
        backoff = 0.0
        while not stop.is_set():
            delay = self._poll
            try:
                confirmed = await self.publish_batch()
                backoff = 0.0
                if confirmed >= self._batch:
                    delay = 0.0
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                backoff = min(self._max_backoff, backoff * 2 if backoff else 1.0)
                delay = backoff
                self._logger.warn("outbox publish failed, will retry", error=type(exc).__name__, retry_in_s=backoff)
            try:
                await self.refresh_gauges()
            except Exception as exc:
                self._logger.warn("outbox gauges not refreshed", error=type(exc).__name__)
            with contextlib.suppress(TimeoutError):
                await asyncio.wait_for(stop.wait(), timeout=delay)


def new_event_id() -> str:
    return str(uuid.uuid4())
