"""Publishing events to RabbitMQ.

Topology shared with the notifier (which declares the queues): a durable topic exchange "platform.events"; routing
keys are the event types (order.created, order.paid, order.failed). Messages are persistent and carry the event ID,
type, schema version, request ID and W3C traceparent as headers. Publishing uses publisher confirms and the
mandatory flag, so an event that no queue accepts is reported as a failure and stays in the outbox.
"""

from __future__ import annotations

import asyncio
import contextlib
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Protocol

import aio_pika

from orders.config import AmqpConfig

EXCHANGE = "platform.events"
SCHEMA_VERSION = 1


@dataclass(frozen=True)
class OutboxEvent:
    id: str
    event_type: str
    aggregate_id: str
    payload: str
    request_id: str | None
    traceparent: str | None


class EventPublisher(Protocol):
    async def publish(self, event: OutboxEvent) -> None: ...

    async def ready(self) -> None: ...

    async def close(self) -> None: ...


class AmqpPublisher:
    def __init__(self, config: AmqpConfig) -> None:
        self._config = config
        self._connection: aio_pika.abc.AbstractRobustConnection | None = None
        self._channel: aio_pika.abc.AbstractChannel | None = None
        self._exchange: aio_pika.abc.AbstractExchange | None = None
        self._lock = asyncio.Lock()

    async def _ensure(self) -> aio_pika.abc.AbstractExchange:
        async with self._lock:
            if self._connection is None or self._connection.is_closed:
                self._connection = await aio_pika.connect_robust(
                    host=self._config.host,
                    port=self._config.port,
                    login=self._config.user,
                    password=self._config.password,
                    virtualhost=self._config.vhost,
                    timeout=self._config.connect_timeout_s,
                )
                self._channel = None
            if self._channel is None or self._channel.is_closed:
                self._channel = await self._connection.channel(publisher_confirms=True)
                self._exchange = await self._channel.declare_exchange(
                    EXCHANGE, aio_pika.ExchangeType.TOPIC, durable=True
                )
            assert self._exchange is not None
            return self._exchange

    async def _reset(self) -> None:
        connection, self._connection, self._channel, self._exchange = self._connection, None, None, None
        if connection is not None:
            # The connection is usually already broken here.
            with contextlib.suppress(Exception):
                await asyncio.wait_for(connection.close(), timeout=2)

    async def publish(self, event: OutboxEvent) -> None:
        headers: dict[str, str | int] = {
            "event_id": event.id,
            "event_type": event.event_type,
            "schema_version": SCHEMA_VERSION,
        }
        if event.request_id:
            headers["request_id"] = event.request_id
        if event.traceparent:
            headers["traceparent"] = event.traceparent
        message = aio_pika.Message(
            body=event.payload.encode(),
            content_type="application/json",
            delivery_mode=aio_pika.DeliveryMode.PERSISTENT,
            message_id=event.id,
            type=event.event_type,
            timestamp=datetime.now(UTC),
            headers=headers,
        )
        try:
            exchange = await asyncio.wait_for(self._ensure(), timeout=self._config.connect_timeout_s + 1)
            await exchange.publish(
                message, routing_key=event.event_type, mandatory=True, timeout=self._config.publish_timeout_s
            )
        except Exception:
            await self._reset()
            raise

    async def ready(self) -> None:
        await asyncio.wait_for(self._ensure(), timeout=self._config.connect_timeout_s + 1)

    async def close(self) -> None:
        await self._reset()
