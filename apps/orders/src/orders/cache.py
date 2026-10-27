"""Cache-aside for orders. A cache problem is never a request problem: every error is a miss."""

from __future__ import annotations

import asyncio
import contextlib
from typing import Protocol

from orders.config import CacheConfig
from orders.metrics import CacheMetrics
from orders.models import Order
from orders.observability import JsonLogger, request_id_var

KEY_PREFIX = "order:"


class OrderCache(Protocol):
    async def get(self, order_id: str) -> Order | None: ...

    async def set(self, order: Order) -> None: ...

    async def invalidate(self, order_id: str) -> None: ...

    async def ready(self) -> None: ...

    async def close(self) -> None: ...


class NoCache:
    """CACHE=none: every lookup is a miss and nothing is stored (and nothing is counted)."""

    async def get(self, order_id: str) -> Order | None:
        return None

    async def set(self, order: Order) -> None:
        return None

    async def invalidate(self, order_id: str) -> None:
        return None

    async def ready(self) -> None:
        return None

    async def close(self) -> None:
        return None


class ValkeyCache:
    """Valkey through valkey-py (MIT). Authenticated, with a short timeout on every call."""

    def __init__(self, client, config: CacheConfig, metrics: CacheMetrics, logger: JsonLogger) -> None:
        self._client = client
        self._ttl = config.ttl_seconds
        self._timeout = config.timeout_s
        self._metrics = metrics
        self._logger = logger

    @classmethod
    def from_config(cls, config: CacheConfig, metrics: CacheMetrics, logger: JsonLogger) -> ValkeyCache:
        from valkey.asyncio import Valkey

        client = Valkey(
            host=config.host,
            port=config.port,
            password=config.password,
            socket_timeout=config.timeout_s,
            socket_connect_timeout=config.timeout_s,
            health_check_interval=0,
            decode_responses=False,
        )
        return cls(client, config, metrics, logger)

    def _failed(self, operation: str, exc: BaseException) -> None:
        self._metrics.requests.labels("error").inc()
        self._logger.warn(
            "cache unavailable, treating as a miss",
            operation=operation,
            error=type(exc).__name__,
            request_id=request_id_var.get(),
        )

    async def get(self, order_id: str) -> Order | None:
        try:
            raw = await asyncio.wait_for(self._client.get(KEY_PREFIX + order_id), timeout=self._timeout)
            if raw is None:
                self._metrics.requests.labels("miss").inc()
                return None
            order = Order.model_validate_json(raw)
        except Exception as exc:
            self._failed("get", exc)
            return None
        self._metrics.requests.labels("hit").inc()
        return order

    async def set(self, order: Order) -> None:
        try:
            await asyncio.wait_for(
                self._client.set(KEY_PREFIX + order.id, order.model_dump_json(), ex=self._ttl), timeout=self._timeout
            )
        except Exception as exc:
            self._failed("set", exc)

    async def invalidate(self, order_id: str) -> None:
        try:
            await asyncio.wait_for(self._client.delete(KEY_PREFIX + order_id), timeout=self._timeout)
        except Exception as exc:
            self._failed("delete", exc)

    async def ready(self) -> None:
        await asyncio.wait_for(self._client.ping(), timeout=self._timeout)

    async def close(self) -> None:
        # Closing a broken connection is best effort.
        with contextlib.suppress(Exception):
            await self._client.aclose()
