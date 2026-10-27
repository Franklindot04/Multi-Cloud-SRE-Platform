from __future__ import annotations

import io
from collections.abc import AsyncIterator, Callable

import httpx
import pytest

from orders.api import create_app
from orders.clients import PaymentApproved, PaymentResult
from orders.config import Config, FaultConfig
from orders.models import Order
from orders.observability import Drain, JsonLogger


def make_config(**overrides: object) -> Config:
    base = Config.load({})
    values = {**base.__dict__, **overrides}
    return Config(**values)  # type: ignore[arg-type]


class FakePayments:
    def __init__(self, result: PaymentResult | Callable[[str], PaymentResult] | None = None) -> None:
        self.result = result or PaymentApproved("pay-1")
        self.calls: list[tuple[str, int, str]] = []
        self.ready_error: Exception | None = None

    async def authorize(self, order_id: str, amount_minor: int, currency: str) -> PaymentResult:
        self.calls.append((order_id, amount_minor, currency))
        return self.result(order_id) if callable(self.result) else self.result

    async def ready(self) -> None:
        if self.ready_error:
            raise self.ready_error


class FakeNotifier:
    def __init__(self) -> None:
        self.notified: list[Order] = []
        self.ready_error: Exception | None = None

    async def notify(self, order: Order) -> None:
        self.notified.append(order)

    async def ready(self) -> None:
        if self.ready_error:
            raise self.ready_error


@pytest.fixture
def payments() -> FakePayments:
    return FakePayments()


@pytest.fixture
def notifier() -> FakeNotifier:
    return FakeNotifier()


@pytest.fixture
def logs() -> io.StringIO:
    return io.StringIO()


@pytest.fixture
def drain() -> Drain:
    return Drain()


@pytest.fixture
def app_factory(payments: FakePayments, notifier: FakeNotifier, logs: io.StringIO, drain: Drain):
    def build(**overrides: object):
        fault = overrides.pop("fault", FaultConfig())
        return create_app(
            make_config(fault=fault, **overrides),
            payments=payments,
            notifier=notifier,
            drain=drain,
            logger=JsonLogger("orders", "info", logs),
        )

    return build


@pytest.fixture
async def client(app_factory) -> AsyncIterator[httpx.AsyncClient]:
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app_factory()), base_url="http://test") as c:
        yield c


VALID_ORDER = {
    "customer_id": "cust-1",
    "items": [{"sku": "sku-1", "quantity": 2, "unit_price_minor": 1250}],
    "currency": "USD",
}
