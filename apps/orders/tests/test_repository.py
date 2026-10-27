import threading
from datetime import UTC, datetime

import pytest

from orders.models import IdempotencyMismatch, Order, OrderItem, OrderStatus
from orders.repository import MemoryOrderRepository

NOW = datetime(2026, 1, 1, tzinfo=UTC)


def an_order(order_id: str) -> Order:
    return Order(
        id=order_id,
        customer_id="c",
        items=[OrderItem(sku="s", quantity=1, unit_price_minor=100)],
        currency="USD",
        total_minor=100,
        status=OrderStatus.PENDING,
        created_at=NOW,
        updated_at=NOW,
    )


def test_same_key_and_body_returns_the_original() -> None:
    repo = MemoryOrderRepository()
    first, created = repo.create_or_get("k", "fp", an_order("a"))
    second, created_again = repo.create_or_get("k", "fp", an_order("b"))
    assert created and not created_again
    assert second.id == first.id == "a"


def test_same_key_with_another_body_is_a_mismatch() -> None:
    repo = MemoryOrderRepository()
    repo.create_or_get("k", "fp-1", an_order("a"))
    with pytest.raises(IdempotencyMismatch):
        repo.create_or_get("k", "fp-2", an_order("b"))


def test_list_is_newest_first_with_paging() -> None:
    repo = MemoryOrderRepository()
    for i in range(5):
        repo.create_or_get(f"k{i}", "fp", an_order(f"o{i}"))
    page, total = repo.list(limit=2, offset=1)
    assert total == 5
    assert [o.id for o in page] == ["o3", "o2"]


def test_transition_updates_the_stored_order() -> None:
    repo = MemoryOrderRepository()
    repo.create_or_get("k", "fp", an_order("a"))
    updated, changed = repo.transition("a", OrderStatus.PAID, payment_id="p")
    assert changed and repo.get("a") == updated
    _, changed_again = repo.transition("a", OrderStatus.PAID, payment_id="p")
    assert not changed_again


def test_mark_payment_unavailable_only_touches_pending_orders() -> None:
    repo = MemoryOrderRepository()
    repo.create_or_get("k", "fp", an_order("a"))
    assert repo.mark_payment_unavailable("a").failure_reason == "payment_unavailable"
    repo.transition("a", OrderStatus.PAID, payment_id="p")
    assert repo.mark_payment_unavailable("a").failure_reason is None


def test_oldest_orders_and_their_keys_are_evicted() -> None:
    repo = MemoryOrderRepository(max_orders=2)
    for i in range(3):
        repo.create_or_get(f"k{i}", "fp", an_order(f"o{i}"))
    assert repo.get("o0") is None and repo.get("o2") is not None
    _, created = repo.create_or_get("k0", "fp", an_order("o0-again"))
    assert created  # the evicted order's key is free again


def test_concurrent_creates_with_one_key_store_one_order() -> None:
    repo = MemoryOrderRepository()
    created_flags: list[bool] = []

    def work(i: int) -> None:
        _, created = repo.create_or_get("same", "fp", an_order(f"o{i}"))
        created_flags.append(created)

    threads = [threading.Thread(target=work, args=(i,)) for i in range(20)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert created_flags.count(True) == 1
    assert repo.list(100, 0)[1] == 1


def test_get_unknown_is_none() -> None:
    assert MemoryOrderRepository().get("nope") is None
