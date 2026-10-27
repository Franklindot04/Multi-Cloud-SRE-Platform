"""Order creation: store the order, authorize payment, settle the order, notify."""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import UTC, datetime

from orders.cache import NoCache, OrderCache
from orders.clients import (
    NotifierClient,
    PaymentApproved,
    PaymentDeclined,
    PaymentRejected,
    PaymentsClient,
    PaymentUnavailable,
)
from orders.models import CreateOrderRequest, Order, OrderStatus
from orders.repository import OrderRepository


@dataclass(frozen=True)
class CreateResult:
    order: Order
    http_status: int


class OrderService:
    def __init__(
        self,
        repo: OrderRepository,
        payments: PaymentsClient,
        notifier: NotifierClient,
        cache: OrderCache | None = None,
        *,
        notify_over_http: bool = True,
    ) -> None:
        self._repo = repo
        self._payments = payments
        self._notifier = notifier
        self._cache = cache or NoCache()
        # With MESSAGING=rabbitmq the notification is an outbox event written with the order change, so the
        # synchronous call to the notifier is skipped.
        self._notify_over_http = notify_over_http

    async def create(self, idempotency_key: str, request: CreateOrderRequest) -> CreateResult:
        now = datetime.now(UTC)
        candidate = Order(
            id=str(uuid.uuid4()),
            customer_id=request.customer_id,
            items=request.items,
            currency=request.currency,
            total_minor=request.total_minor(),
            status=OrderStatus.PENDING,
            created_at=now,
            updated_at=now,
        )
        order, created = await self._repo.create_or_get(idempotency_key, request.fingerprint(), candidate)

        if order.status != OrderStatus.PENDING:
            # A replay of a request that already finished: return the stored result.
            return CreateResult(order, 200)

        result = await self._payments.authorize(order.id, order.total_minor, order.currency)

        if isinstance(result, PaymentUnavailable):
            # Keep the order. Repeating the request with the same key retries the authorization.
            order = await self._repo.mark_payment_unavailable(order.id)
            await self._cache.invalidate(order.id)
            return CreateResult(order, 202)

        if isinstance(result, PaymentApproved):
            order, changed = await self._repo.transition(order.id, OrderStatus.PAID, payment_id=result.payment_id)
        elif isinstance(result, PaymentDeclined):
            order, changed = await self._repo.transition(
                order.id, OrderStatus.FAILED, payment_id=result.payment_id, failure_reason=result.reason
            )
        else:
            assert isinstance(result, PaymentRejected)
            order, changed = await self._repo.transition(order.id, OrderStatus.FAILED, failure_reason=result.reason)

        if changed:
            await self._cache.invalidate(order.id)
            if self._notify_over_http:
                # Only the request that settled the order notifies, so retries do not send duplicates.
                await self._notifier.notify(order)
        return CreateResult(order, 201 if created else 200)

    async def get(self, order_id: str) -> Order | None:
        cached = await self._cache.get(order_id)
        if cached is not None:
            return cached
        order = await self._repo.get(order_id)
        if order is not None:
            await self._cache.set(order)
        return order

    async def list(self, limit: int, offset: int) -> tuple[list[Order], int]:
        return await self._repo.list(limit, offset)
