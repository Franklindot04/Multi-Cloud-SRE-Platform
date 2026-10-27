from datetime import UTC, datetime

import pytest

from orders.models import CreateOrderRequest, InvalidTransition, Order, OrderItem, OrderStatus, apply_transition

NOW = datetime(2026, 1, 1, tzinfo=UTC)


def an_order(status: OrderStatus = OrderStatus.PENDING) -> Order:
    return Order(
        id="o-1",
        customer_id="c",
        items=[OrderItem(sku="s", quantity=1, unit_price_minor=100)],
        currency="USD",
        total_minor=100,
        status=status,
        created_at=NOW,
        updated_at=NOW,
    )


def request(**overrides: object) -> CreateOrderRequest:
    data = {"customer_id": "c", "items": [{"sku": "s", "quantity": 3, "unit_price_minor": 250}], "currency": "USD"}
    data.update(overrides)
    return CreateOrderRequest.model_validate(data)


def test_total_is_quantity_times_unit_price_summed() -> None:
    r = request(
        items=[
            {"sku": "a", "quantity": 2, "unit_price_minor": 100},
            {"sku": "b", "quantity": 1, "unit_price_minor": 50},
        ]
    )
    assert r.total_minor() == 250


def test_fingerprint_is_stable_and_sensitive_to_content() -> None:
    assert request().fingerprint() == request().fingerprint()
    assert request().fingerprint() != request(currency="EUR").fingerprint()


@pytest.mark.parametrize("target", [OrderStatus.PAID, OrderStatus.FAILED])
def test_pending_can_settle(target: OrderStatus) -> None:
    updated, changed = apply_transition(an_order(), target, payment_id="p", failure_reason=None, now=NOW)
    assert changed and updated.status == target and updated.payment_id == "p"


def test_same_status_is_a_noop() -> None:
    order = an_order(OrderStatus.PAID)
    updated, changed = apply_transition(order, OrderStatus.PAID)
    assert not changed and updated is order


@pytest.mark.parametrize(
    ("current", "target"),
    [
        (OrderStatus.PAID, OrderStatus.FAILED),
        (OrderStatus.FAILED, OrderStatus.PAID),
        (OrderStatus.PAID, OrderStatus.PENDING),
        (OrderStatus.FAILED, OrderStatus.PENDING),
    ],
)
def test_final_statuses_cannot_change(current: OrderStatus, target: OrderStatus) -> None:
    with pytest.raises(InvalidTransition):
        apply_transition(an_order(current), target)


@pytest.mark.parametrize(
    "bad",
    [
        {"currency": "usd"},
        {"currency": "US"},
        {"items": []},
        {"items": [{"sku": "s", "quantity": 0, "unit_price_minor": 1}]},
        {"items": [{"sku": "s", "quantity": 1, "unit_price_minor": -1}]},
        {"customer_id": ""},
        {"unexpected": 1},
    ],
)
def test_invalid_requests_are_rejected(bad: dict) -> None:
    with pytest.raises(ValueError):
        request(**bad)
