"""Publishing events to RabbitMQ.

Topology shared with the notifier (which declares the queues): a durable topic exchange "platform.events"; routing
keys are the event types (order.created, order.paid, order.failed). Messages are persistent and carry the event ID,
type, schema version, request ID and W3C trace context (traceparent, and tracestate when there is one) as headers.
Publishing uses publisher confirms and the mandatory flag, so an event that no queue accepts is reported as a failure
and stays in the outbox.

Each publish runs in a producer span. Its parent is the span that was active when the order changed, which the outbox
row kept as a traceparent, so the notifier's span joins the trace of the request. The headers carry the context of the
producer span.
"""

from __future__ import annotations

import asyncio
import contextlib
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Protocol

import aio_pika
from opentelemetry import trace

from orders.config import AmqpConfig
from orders.observability import JsonLogger
from orders.tracing import PROPAGATOR, Tracing

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
    def __init__(self, config: AmqpConfig, tracing: Tracing | None = None, logger: JsonLogger | None = None) -> None:
        self._config = config
        self._tracer = (tracing or Tracing()).tracer()
        self._logger = logger
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
        context = PROPAGATOR.extract({"traceparent": event.traceparent}) if event.traceparent else None
        attributes = {
            "messaging.system": "rabbitmq",
            "messaging.operation.type": "send",
            "messaging.destination.name": EXCHANGE,
            "messaging.rabbitmq.destination.routing_key": event.event_type,
            "messaging.message.body.size": len(event.payload.encode()),
        }
        with self._tracer.start_as_current_span(
            f"{EXCHANGE} publish",
            context=context,
            kind=trace.SpanKind.PRODUCER,
            attributes=attributes,
            record_exception=False,
            set_status_on_exception=False,
        ) as span:
            headers: dict[str, str | int] = {
                "event_id": event.id,
                "event_type": event.event_type,
                "schema_version": SCHEMA_VERSION,
            }
            if event.request_id:
                headers["request_id"] = event.request_id
            # The context of the producer span, as text headers (the notifier reads strings or bytes). Without
            # tracing nothing is injected and the traceparent stored with the event is sent unchanged.
            propagated: dict[str, str] = {}
            PROPAGATOR.inject(propagated)
            if "traceparent" not in propagated and event.traceparent:
                propagated["traceparent"] = event.traceparent
            headers.update(propagated)
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
            except Exception as exc:
                span.add_event("exception", {"exception.type": type(exc).__name__})
                span.set_status(trace.Status(trace.StatusCode.ERROR, "publish failed"))
                if self._logger is not None:
                    self._logger.warn(
                        "event not published", event_id=event.id, event_type=event.event_type, error=type(exc).__name__
                    )
                await self._reset()
                raise
            if self._logger is not None:
                self._logger.log("debug", "event published", event_id=event.id, event_type=event.event_type)

    async def ready(self) -> None:
        await asyncio.wait_for(self._ensure(), timeout=self._config.connect_timeout_s + 1)

    async def close(self) -> None:
        await self._reset()
