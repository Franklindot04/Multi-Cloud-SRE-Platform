"""Outbound HTTP calls to payments and the notifier, each with an explicit timeout."""

from __future__ import annotations

import asyncio
from dataclasses import dataclass
from typing import Protocol

import httpx

from orders.models import Order
from orders.observability import JsonLogger, outbound_headers


@dataclass(frozen=True)
class PaymentApproved:
    payment_id: str


@dataclass(frozen=True)
class PaymentDeclined:
    payment_id: str | None
    reason: str


@dataclass(frozen=True)
class PaymentRejected:
    """Payments refused the request itself (a client error), so retrying will not help."""

    reason: str = "payment_rejected"


@dataclass(frozen=True)
class PaymentUnavailable:
    """Payments could not be reached or failed; the order must be kept and retried later."""

    detail: str


PaymentResult = PaymentApproved | PaymentDeclined | PaymentRejected | PaymentUnavailable


class PaymentsClient(Protocol):
    async def authorize(self, order_id: str, amount_minor: int, currency: str) -> PaymentResult: ...

    async def ready(self) -> None: ...


class NotifierClient(Protocol):
    async def notify(self, order: Order) -> None: ...

    async def ready(self) -> None: ...


class HttpPaymentsClient:
    def __init__(self, client: httpx.AsyncClient, base_url: str, timeout_s: float) -> None:
        self._client = client
        self._base = base_url
        self._timeout = timeout_s

    async def authorize(self, order_id: str, amount_minor: int, currency: str) -> PaymentResult:
        # The payment key is derived from the order, so retrying the same order can never charge twice.
        headers = {"Idempotency-Key": f"order-{order_id}", **outbound_headers()}
        try:
            response = await asyncio.wait_for(
                self._client.post(
                    f"{self._base}/payments/authorize",
                    json={"order_id": order_id, "amount_minor": amount_minor, "currency": currency},
                    headers=headers,
                    timeout=self._timeout,
                ),
                timeout=self._timeout,
            )
        except (httpx.HTTPError, TimeoutError) as exc:
            return PaymentUnavailable(type(exc).__name__)

        if response.status_code in (200, 201):
            try:
                body = response.json()
                if body["status"] == "approved":
                    return PaymentApproved(str(body["id"]))
                return PaymentDeclined(str(body["id"]), str(body.get("decline_reason") or "payment_declined"))
            except ValueError, KeyError, TypeError:
                return PaymentUnavailable("malformed response from payments")
        if response.status_code in (408, 429) or response.status_code >= 500:
            return PaymentUnavailable(f"payments returned {response.status_code}")
        return PaymentRejected()

    async def ready(self) -> None:
        response = await self._client.get(f"{self._base}/readyz", timeout=self._timeout)
        response.raise_for_status()


class HttpNotifierClient:
    def __init__(self, client: httpx.AsyncClient, base_url: str, timeout_s: float, logger: JsonLogger) -> None:
        self._client = client
        self._base = base_url
        self._timeout = timeout_s
        self._logger = logger

    async def notify(self, order: Order) -> None:
        """Ask the notifier to record a notification. Failures are logged, never raised."""
        try:
            response = await asyncio.wait_for(
                self._client.post(
                    f"{self._base}/notifications",
                    json={
                        "order_id": order.id,
                        "channel": "email",
                        "message": f"Order {order.id} is {order.status.value}",
                    },
                    headers=outbound_headers(),
                    timeout=self._timeout,
                ),
                timeout=self._timeout,
            )
            if response.status_code != 201:
                self._logger.warn("notifier rejected the notification", order_id=order.id, status=response.status_code)
        except (httpx.HTTPError, TimeoutError) as exc:
            self._logger.warn("notifier unavailable", order_id=order.id, error=type(exc).__name__)

    async def ready(self) -> None:
        response = await self._client.get(f"{self._base}/readyz", timeout=self._timeout)
        response.raise_for_status()
