"""Order storage behind an interface, with a thread-safe in-memory implementation."""

from __future__ import annotations

import threading
from abc import ABC, abstractmethod
from collections import OrderedDict
from datetime import UTC, datetime

from orders.models import IdempotencyMismatch, Order, OrderStatus, apply_transition


class OrderRepository(ABC):
    """What the service needs from storage. A database can implement this without touching handlers."""

    @abstractmethod
    def create_or_get(self, key: str, fingerprint: str, order: Order) -> tuple[Order, bool]:
        """Store order under the idempotency key unless the key was used before.

        Returns the stored order and whether it was just created. Raises IdempotencyMismatch if the
        key exists with a different fingerprint.
        """

    @abstractmethod
    def get(self, order_id: str) -> Order | None: ...

    @abstractmethod
    def list(self, limit: int, offset: int) -> tuple[list[Order], int]:
        """Return a page of orders, newest first, and the total count."""

    @abstractmethod
    def transition(
        self,
        order_id: str,
        new_status: OrderStatus,
        *,
        payment_id: str | None = None,
        failure_reason: str | None = None,
    ) -> tuple[Order, bool]:
        """Move an order to a new status; returns the order and whether it changed."""

    @abstractmethod
    def mark_payment_unavailable(self, order_id: str) -> Order:
        """Record that payment could not be reached while the order stays pending."""


class MemoryOrderRepository(OrderRepository):
    """Holds at most max_orders orders, dropping the oldest, so memory stays bounded."""

    def __init__(self, max_orders: int = 100_000) -> None:
        self._max = max_orders
        self._lock = threading.RLock()
        self._orders: OrderedDict[str, Order] = OrderedDict()
        self._keys: dict[str, tuple[str, str]] = {}  # key -> (fingerprint, order id)
        self._key_of: dict[str, str] = {}  # order id -> key

    def create_or_get(self, key: str, fingerprint: str, order: Order) -> tuple[Order, bool]:
        with self._lock:
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

    def get(self, order_id: str) -> Order | None:
        with self._lock:
            return self._orders.get(order_id)

    def list(self, limit: int, offset: int) -> tuple[list[Order], int]:
        with self._lock:
            newest_first = list(reversed(self._orders.values()))
            return newest_first[offset : offset + limit], len(newest_first)

    def transition(
        self,
        order_id: str,
        new_status: OrderStatus,
        *,
        payment_id: str | None = None,
        failure_reason: str | None = None,
    ) -> tuple[Order, bool]:
        with self._lock:
            order = self._orders[order_id]
            updated, changed = apply_transition(order, new_status, payment_id=payment_id, failure_reason=failure_reason)
            if changed:
                self._orders[order_id] = updated
            return updated, changed

    def mark_payment_unavailable(self, order_id: str) -> Order:
        with self._lock:
            order = self._orders[order_id]
            if order.status != OrderStatus.PENDING:
                return order
            updated = order.model_copy(
                update={"failure_reason": "payment_unavailable", "updated_at": datetime.now(UTC)}
            )
            self._orders[order_id] = updated
            return updated
