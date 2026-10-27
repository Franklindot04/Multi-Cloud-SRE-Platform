import pytest

from orders.clients import PaymentApproved, PaymentDeclined, PaymentRejected, PaymentUnavailable
from orders.models import CreateOrderRequest, IdempotencyMismatch, OrderStatus
from orders.repository import MemoryOrderRepository
from orders.service import OrderService
from tests.conftest import VALID_ORDER, FakeNotifier, FakePayments


def build(payments: FakePayments, notifier: FakeNotifier) -> OrderService:
    return OrderService(MemoryOrderRepository(), payments, notifier)


def req(**overrides: object) -> CreateOrderRequest:
    return CreateOrderRequest.model_validate({**VALID_ORDER, **overrides})


async def test_approved_payment_marks_the_order_paid_and_notifies() -> None:
    payments, notifier = FakePayments(PaymentApproved("pay-9")), FakeNotifier()
    result = await build(payments, notifier).create("k1", req())
    assert result.http_status == 201
    assert result.order.status == OrderStatus.PAID and result.order.payment_id == "pay-9"
    assert payments.calls[0][1:] == (2500, "USD")
    assert [o.id for o in notifier.notified] == [result.order.id]


async def test_declined_payment_marks_the_order_failed_with_the_reason() -> None:
    payments, notifier = FakePayments(PaymentDeclined("pay-2", "amount_exceeds_limit")), FakeNotifier()
    result = await build(payments, notifier).create("k1", req())
    assert result.order.status == OrderStatus.FAILED
    assert result.order.failure_reason == "amount_exceeds_limit" and result.order.payment_id == "pay-2"
    assert len(notifier.notified) == 1


async def test_rejected_payment_fails_the_order() -> None:
    result = await build(FakePayments(PaymentRejected()), FakeNotifier()).create("k1", req())
    assert result.order.status == OrderStatus.FAILED and result.order.failure_reason == "payment_rejected"


async def test_unavailable_payments_keep_the_order_pending_and_do_not_notify() -> None:
    payments, notifier = FakePayments(PaymentUnavailable("timeout")), FakeNotifier()
    service = build(payments, notifier)
    result = await service.create("k1", req())
    assert result.http_status == 202
    assert result.order.status == OrderStatus.PENDING and result.order.failure_reason == "payment_unavailable"
    assert await service.get(result.order.id) is not None  # the order was not lost
    assert notifier.notified == []


async def test_retrying_after_unavailable_payments_completes_the_same_order() -> None:
    payments, notifier = FakePayments(PaymentUnavailable("timeout")), FakeNotifier()
    service = build(payments, notifier)
    first = await service.create("k1", req())
    payments.result = PaymentApproved("pay-5")
    second = await service.create("k1", req())
    assert second.order.id == first.order.id
    assert second.order.status == OrderStatus.PAID and second.http_status == 200
    assert len(notifier.notified) == 1
    assert {call[0] for call in payments.calls} == {first.order.id}  # payment is retried for the same order


async def test_replay_of_a_finished_order_does_not_call_payments_again() -> None:
    payments, notifier = FakePayments(), FakeNotifier()
    service = build(payments, notifier)
    first = await service.create("k1", req())
    again = await service.create("k1", req())
    assert again.http_status == 200 and again.order.id == first.order.id
    assert len(payments.calls) == 1 and len(notifier.notified) == 1


async def test_same_key_with_another_body_is_rejected() -> None:
    service = build(FakePayments(), FakeNotifier())
    await service.create("k1", req())
    with pytest.raises(IdempotencyMismatch):
        await service.create("k1", req(currency="EUR"))


async def test_different_keys_create_different_orders() -> None:
    payments = FakePayments()
    service = build(payments, FakeNotifier())
    a = await service.create("k1", req())
    b = await service.create("k2", req())
    assert a.order.id != b.order.id and len(payments.calls) == 2
