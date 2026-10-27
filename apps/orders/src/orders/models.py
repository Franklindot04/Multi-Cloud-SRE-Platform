"""Order domain model and the rules for changing an order's status."""

from __future__ import annotations

import hashlib
import json
import re
from datetime import UTC, datetime
from enum import StrEnum

from pydantic import BaseModel, ConfigDict, Field

CURRENCY_PATTERN = r"^[A-Z]{3}$"
IDEMPOTENCY_KEY_PATTERN = re.compile(r"^[\x21-\x7e]{1,128}$")


class OrderStatus(StrEnum):
    PENDING = "pending"
    PAID = "paid"
    FAILED = "failed"


class InvalidTransition(Exception):
    """An order cannot move from its current status to the requested one."""


class IdempotencyMismatch(Exception):
    """The Idempotency-Key was already used with a different request body."""


class OrderItem(BaseModel):
    model_config = ConfigDict(extra="forbid")

    sku: str = Field(min_length=1, max_length=64)
    quantity: int = Field(ge=1, le=1000)
    unit_price_minor: int = Field(ge=0, le=1_000_000_000)


class CreateOrderRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    customer_id: str = Field(min_length=1, max_length=64)
    items: list[OrderItem] = Field(min_length=1, max_length=50)
    currency: str = Field(pattern=CURRENCY_PATTERN)

    def total_minor(self) -> int:
        return sum(item.quantity * item.unit_price_minor for item in self.items)

    def fingerprint(self) -> str:
        """Stable hash of the request, used to detect an idempotency key reused with another body."""
        canonical = json.dumps(self.model_dump(mode="json"), sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(canonical.encode()).hexdigest()


class Order(BaseModel):
    id: str
    customer_id: str
    items: list[OrderItem]
    currency: str
    total_minor: int
    status: OrderStatus
    payment_id: str | None = None
    failure_reason: str | None = None
    created_at: datetime
    updated_at: datetime


_ALLOWED = {
    OrderStatus.PENDING: {OrderStatus.PAID, OrderStatus.FAILED},
    OrderStatus.PAID: set(),
    OrderStatus.FAILED: set(),
}


def apply_transition(
    order: Order,
    new_status: OrderStatus,
    *,
    payment_id: str | None = None,
    failure_reason: str | None = None,
    now: datetime | None = None,
) -> tuple[Order, bool]:
    """Return the order after moving to new_status, and whether anything changed.

    pending can become paid or failed; paid and failed are final. Asking for the status an order
    already has is a no-op, which makes retries and concurrent requests safe.
    """
    if order.status == new_status:
        return order, False
    if new_status not in _ALLOWED[order.status]:
        raise InvalidTransition(f"cannot move an order from {order.status} to {new_status}")
    updated = order.model_copy(
        update={
            "status": new_status,
            "payment_id": payment_id,
            "failure_reason": failure_reason,
            "updated_at": now or datetime.now(UTC),
        }
    )
    return updated, True
