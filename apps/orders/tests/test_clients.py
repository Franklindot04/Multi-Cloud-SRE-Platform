import io

import httpx

from orders.clients import (
    HttpNotifierClient,
    HttpPaymentsClient,
    PaymentApproved,
    PaymentDeclined,
    PaymentRejected,
    PaymentUnavailable,
)
from orders.models import Order, OrderStatus
from orders.observability import JsonLogger, request_id_var, trace_var
from tests.test_models import an_order


def payments_client(handler, timeout: float = 1.0) -> HttpPaymentsClient:
    return HttpPaymentsClient(httpx.AsyncClient(transport=httpx.MockTransport(handler)), "http://payments", timeout)


def reply(status: int, body: dict | None = None):
    return lambda request: httpx.Response(status, json=body or {})


async def test_approved() -> None:
    client = payments_client(reply(201, {"id": "p1", "status": "approved"}))
    assert await client.authorize("o1", 100, "USD") == PaymentApproved("p1")


async def test_declined_carries_the_reason() -> None:
    client = payments_client(reply(201, {"id": "p1", "status": "declined", "decline_reason": "issuer_declined"}))
    assert await client.authorize("o1", 100, "USD") == PaymentDeclined("p1", "issuer_declined")


async def test_client_error_is_a_rejection() -> None:
    assert await payments_client(reply(422)).authorize("o1", 100, "USD") == PaymentRejected()


async def test_server_errors_and_throttling_are_unavailable() -> None:
    for status in (408, 429, 500, 503):
        result = await payments_client(reply(status)).authorize("o1", 100, "USD")
        assert isinstance(result, PaymentUnavailable), status


async def test_timeouts_and_connection_errors_are_unavailable() -> None:
    def slow(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("slow", request=request)

    def down(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("refused", request=request)

    assert isinstance(await payments_client(slow).authorize("o1", 1, "USD"), PaymentUnavailable)
    assert isinstance(await payments_client(down).authorize("o1", 1, "USD"), PaymentUnavailable)


async def test_malformed_success_body_is_unavailable() -> None:
    assert isinstance(
        await payments_client(reply(201, {"unexpected": True})).authorize("o1", 1, "USD"), PaymentUnavailable
    )


async def test_idempotency_key_and_trace_headers_are_sent() -> None:
    seen: dict[str, str] = {}

    def capture(request: httpx.Request) -> httpx.Response:
        seen.update(request.headers)
        return httpx.Response(201, json={"id": "p", "status": "approved"})

    request_id_var.set("rid-1")
    trace_var.set(("4bf92f3577b34da6a3ce929d0e0e4736", "01"))
    await payments_client(capture).authorize("order-77", 100, "USD")
    assert seen["idempotency-key"] == "order-order-77"
    assert seen["x-request-id"] == "rid-1"
    assert seen["traceparent"].startswith("00-4bf92f3577b34da6a3ce929d0e0e4736-") and seen["traceparent"].endswith(
        "-01"
    )


async def test_notifier_failures_never_raise() -> None:
    def down(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("refused", request=request)

    logs = io.StringIO()
    client = HttpNotifierClient(
        httpx.AsyncClient(transport=httpx.MockTransport(down)),
        "http://notifier",
        1.0,
        JsonLogger("orders", "info", logs),
    )
    order: Order = an_order(OrderStatus.PAID)
    await client.notify(order)
    assert "notifier unavailable" in logs.getvalue()


async def test_notifier_rejection_is_logged() -> None:
    logs = io.StringIO()
    client = HttpNotifierClient(
        httpx.AsyncClient(transport=httpx.MockTransport(reply(422))),
        "http://notifier",
        1.0,
        JsonLogger("orders", "info", logs),
    )
    await client.notify(an_order(OrderStatus.PAID))
    assert "notifier rejected" in logs.getvalue()
