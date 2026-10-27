"""Order storage behind an interface, with a thread-safe in-memory implementation.

The interface is asynchronous so that a database implementation (see postgres.py) can use it without
blocking the event loop; the in-memory implementation completes immediately.
"""

from __future__ import annotations

import asyncio
from abc import ABC, abstractmethod
from collections import OrderedDict
from datetime import UTC, datetime

from orders.models import IdempotencyMismatch, Order, OrderStatus, apply_transition


class OrderRepository(ABC):
    """What the service needs from storage. A database implements this without touching handlers."""

    @abstractmethod
    async def create_or_get(self, key: str, fingerprint: str, order: Order) -> tuple[Order, bool]:
        """Store order under the idempotency key unless the key was used before.

        Returns the stored order and whether it was just created. Raises IdempotencyMismatch if the
        key exists with a different fingerprint.
        """

    @abstractmethod
    async def get(self, order_id: str) -> Order | None: ...

    @abstractmethod
    async def list(self, limit: int, offset: int) -> tuple[list[Order], int]:
        """Return a page of orders, newest first, and the total count."""

    @abstractmethod
    async def transition(
        self,
        order_id: str,
        new_status: OrderStatus,
        *,
        payment_id: str | None = None,
        failure_reason: str | None = None,
    ) -> tuple[Order, bool]:
        """Move an order to a new status; returns the order and whether it changed."""

    @abstractmethod
    async def mark_payment_unavailable(self, order_id: str) -> Order:
        """Record that payment could not be reached while the order stays pending."""

    async def ready(self) -> None:
        """Raise if the storage cannot serve requests. In-memory storage always can."""
        return None


class MemoryOrderRepository(OrderRepository):
    """Holds at most max_orders orders, dropping the oldest, so memory stays bounded."""

    def __init__(self, max_orders: int = 100_000) -> None:
        self._max = max_orders
        self._lock = asyncio.Lock()
        self._orders: OrderedDict[str, Order] = OrderedDict()
        self._keys: dict[str, tuple[str, str]] = {}  # key -> (fingerprint, order id)
        self._key_of: dict[str, str] = {}  # order id -> key

    async def create_or_get(self, key: str, fingerprint: str, order: Order) -> tuple[Order, bool]:
        async with self._lock:
            existing = self._keys.get(key)
            if existing is not None:
                known_fingerprint, order_id = existing
                if known_fingerprint != fingerprint:
                    raise IdempotencyMismatch(key)
                return self._orders[order_id], False
            self._orders[order.id] = order
            self._keys[key] = (fingerprint, order.id)
            self._key_of[order.id] = key
            while len(self._orders) > self._max:
                old_id, _ = self._orders.popitem(last=False)
                self._keys.pop(self._key_of.pop(old_id), None)
            return order, True

    async def get(self, order_id: str) -> Order | None:
        async with self._lock:
            return self._orders.get(order_id)

    async def list(self, limit: int, offset: int) -> tuple[list[Order], int]:
        async with self._lock:
            newest_first = list(reversed(self._orders.values()))
            return newest_first[offset : offset + limit], len(newest_first)

    async def transition(
        self,
        order_id: str,
        new_status: OrderStatus,
        *,
        payment_id: str | None = None,
        failure_reason: str | None = None,
    ) -> tuple[Order, bool]:
        async with self._lock:
            order = self._orders[order_id]
            updated, changed = apply_transition(order, new_status, payment_id=payment_id, failure_reason=failure_reason)
            if changed:
                self._orders[order_id] = updated
            return updated, changed

    async def mark_payment_unavailable(self, order_id: str) -> Order:
        async with self._lock:
            order = self._orders[order_id]
            if order.status != OrderStatus.PENDING:
                return order
            updated = order.model_copy(
                update={"failure_reason": "payment_unavailable", "updated_at": datetime.now(UTC)}
            )
            self._orders[order_id] = updated
            return updated
