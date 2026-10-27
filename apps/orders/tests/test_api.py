import asyncio
import json
import time

import httpx

from orders.clients import PaymentApproved, PaymentDeclined, PaymentUnavailable
from orders.config import FaultConfig
from tests.conftest import VALID_ORDER, FakePayments

KEY = {"Idempotency-Key": "key-1"}


async def test_create_order_happy_path(client: httpx.AsyncClient, notifier) -> None:
    response = await client.post("/orders", json=VALID_ORDER, headers=KEY)
    assert response.status_code == 201
    body = response.json()
    assert body["status"] == "paid" and body["total_minor"] == 2500 and body["payment_id"] == "pay-1"
    assert body["failure_reason"] is None and body["id"]
    assert len(notifier.notified) == 1


async def test_declined_payment_returns_a_failed_order(app_factory, payments: FakePayments) -> None:
    payments.result = PaymentDeclined("pay-x", "amount_exceeds_limit")
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app_factory()), base_url="http://t") as c:
        response = await c.post("/orders", json=VALID_ORDER, headers=KEY)
    assert response.status_code == 201
    assert response.json()["status"] == "failed" and response.json()["failure_reason"] == "amount_exceeds_limit"


async def test_payments_down_keeps_the_order_and_returns_202(app_factory, payments: FakePayments) -> None:
    payments.result = PaymentUnavailable("timeout")
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app_factory()), base_url="http://t") as c:
        first = await c.post("/orders", json=VALID_ORDER, headers=KEY)
        assert first.status_code == 202 and first.json()["status"] == "pending"
        assert (await c.get(f"/orders/{first.json()['id']}")).json()["failure_reason"] == "payment_unavailable"

        payments.result = PaymentApproved("pay-2")
        retry = await c.post("/orders", json=VALID_ORDER, headers=KEY)
    assert retry.status_code == 200
    assert retry.json()["id"] == first.json()["id"] and retry.json()["status"] == "paid"


async def test_replay_returns_200_and_the_same_order(client: httpx.AsyncClient) -> None:
    first = await client.post("/orders", json=VALID_ORDER, headers=KEY)
    second = await client.post("/orders", json=VALID_ORDER, headers=KEY)
    assert (first.status_code, second.status_code) == (201, 200)
    assert first.json() == second.json()


async def test_same_key_with_another_body_is_422(client: httpx.AsyncClient) -> None:
    await client.post("/orders", json=VALID_ORDER, headers=KEY)
    response = await client.post("/orders", json={**VALID_ORDER, "currency": "EUR"}, headers=KEY)
    assert response.status_code == 422 and response.json()["error"]["code"] == "idempotency_key_mismatch"


async def test_missing_or_invalid_idempotency_key_is_400(client: httpx.AsyncClient) -> None:
    for headers in ({}, {"Idempotency-Key": "x" * 129}, {"Idempotency-Key": "has space"}):
        response = await client.post("/orders", json=VALID_ORDER, headers=headers)
        assert response.status_code == 400, headers
        assert response.json()["error"]["code"] == "missing_idempotency_key"


async def test_invalid_json_is_400(client: httpx.AsyncClient) -> None:
    response = await client.post("/orders", content=b"{nope", headers={**KEY, "Content-Type": "application/json"})
    assert response.status_code == 400 and response.json()["error"]["code"] == "invalid_json"


async def test_validation_errors_are_422_with_the_error_envelope(client: httpx.AsyncClient) -> None:
    bad_bodies = [
        {**VALID_ORDER, "currency": "usd"},
        {**VALID_ORDER, "items": []},
        {**VALID_ORDER, "items": [{"sku": "s", "quantity": 0, "unit_price_minor": 1}]},
        {**VALID_ORDER, "extra": True},
        {"customer_id": "c"},
    ]
    for body in bad_bodies:
        response = await client.post("/orders", json=body, headers=KEY)
        assert response.status_code == 422, body
        error = response.json()["error"]
        assert error["code"] == "validation_error" and error["request_id"] and error["message"]


async def test_zero_total_is_rejected(client: httpx.AsyncClient) -> None:
    free = {**VALID_ORDER, "items": [{"sku": "s", "quantity": 1, "unit_price_minor": 0}]}
    response = await client.post("/orders", json=free, headers=KEY)
    assert response.status_code == 422


async def test_get_and_list(client: httpx.AsyncClient) -> None:
    ids = []
    for i in range(3):
        created = await client.post("/orders", json=VALID_ORDER, headers={"Idempotency-Key": f"k{i}"})
        ids.append(created.json()["id"])
    assert (await client.get(f"/orders/{ids[1]}")).json()["id"] == ids[1]
    page = (await client.get("/orders", params={"limit": 2, "offset": 1})).json()
    assert page["total"] == 3 and [o["id"] for o in page["items"]] == [ids[1], ids[0]]
    assert (page["limit"], page["offset"]) == (2, 1)


async def test_get_unknown_order_is_404(client: httpx.AsyncClient) -> None:
    response = await client.get("/orders/does-not-exist")
    assert response.status_code == 404 and response.json()["error"]["code"] == "not_found"


async def test_list_parameters_are_validated(client: httpx.AsyncClient) -> None:
    for params in ({"limit": 0}, {"limit": 201}, {"offset": -1}, {"limit": "x"}):
        assert (await client.get("/orders", params=params)).status_code == 422, params


async def test_unknown_route_and_wrong_method_use_the_envelope(client: httpx.AsyncClient) -> None:
    missing = await client.get("/nope")
    assert missing.status_code == 404 and missing.json()["error"]["code"] == "not_found"
    wrong = await client.delete("/orders")
    assert wrong.status_code == 405 and wrong.json()["error"]["code"] == "method_not_allowed"


async def test_oversized_body_is_413(app_factory) -> None:
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app_factory(max_body_bytes=200)), base_url="http://t"
    ) as c:
        big = {
            **VALID_ORDER,
            "customer_id": "c" * 64,
            "items": [{"sku": "s" * 60, "quantity": 1, "unit_price_minor": 1}] * 10,
        }
        response = await c.post("/orders", json=big, headers=KEY)
        assert response.status_code == 413 and response.json()["error"]["code"] == "payload_too_large"

        async def chunks():
            yield b'{"customer_id": "'
            yield b"x" * 500
            yield b'"}'

        streamed = await c.post("/orders", content=chunks(), headers=KEY)
    assert streamed.status_code == 413


async def test_request_id_is_generated_echoed_and_logged(client: httpx.AsyncClient, logs) -> None:
    generated = await client.get("/healthz")
    assert len(generated.headers["x-request-id"]) == 36
    echoed = await client.get("/healthz", headers={"X-Request-Id": "abc-123"})
    assert echoed.headers["x-request-id"] == "abc-123"
    replaced = await client.get("/healthz", headers={"X-Request-Id": "bad id!"})
    assert replaced.headers["x-request-id"] != "bad id!"

    lines = [json.loads(line) for line in logs.getvalue().splitlines()]
    entry = next(line for line in lines if line.get("request_id") == "abc-123")
    for field in ("timestamp", "level", "message", "service", "method", "route", "status", "duration_ms", "trace_id"):
        assert field in entry
    assert entry["service"] == "orders" and entry["route"] == "/healthz" and entry["status"] == 200


async def test_error_responses_carry_the_request_id(client: httpx.AsyncClient) -> None:
    response = await client.get("/orders/x", headers={"X-Request-Id": "trace-me"})
    assert response.json()["error"]["request_id"] == "trace-me"


async def test_metrics_use_route_templates_and_shared_names(client: httpx.AsyncClient) -> None:
    await client.get("/orders/aaa")
    await client.get("/orders/bbb")
    await client.get("/something/else")
    text = (await client.get("/metrics")).text
    assert 'http_requests_total{method="GET",route="/orders/{order_id}",service="orders",status="404"} 2.0' in text
    assert 'route="unmatched"' in text
    assert "/orders/aaa" not in text
    assert (
        'http_request_duration_seconds_bucket{le="0.005",method="GET",route="/orders/{order_id}",service="orders"}'
        in text
    )
    assert 'http_requests_in_flight{service="orders"}' in text


async def test_healthz_is_always_ok(client: httpx.AsyncClient) -> None:
    assert (await client.get("/healthz")).json() == {"status": "ok"}


async def test_readyz_depends_on_payments_but_not_on_the_notifier(app_factory, payments, notifier) -> None:
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app_factory()), base_url="http://t") as c:
        ok = await c.get("/readyz")
        assert ok.status_code == 200 and ok.json()["checks"]["payments"] == "ok"

        notifier.ready_error = RuntimeError("down")
        degraded = await c.get("/readyz")
        assert degraded.status_code == 200 and degraded.json()["checks"]["notifier"].startswith("degraded")

        payments.ready_error = RuntimeError("down")
        not_ready = await c.get("/readyz")
    assert not_ready.status_code == 503 and not_ready.json()["status"] == "not_ready"


async def test_readyz_times_out_on_a_hung_dependency(app_factory, payments) -> None:
    async def hang() -> None:
        await asyncio.sleep(5)

    payments.ready = hang  # type: ignore[method-assign]
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app_factory(readiness_timeout_s=0.1)), base_url="http://t"
    ) as c:
        start = time.monotonic()
        response = await c.get("/readyz")
    assert response.status_code == 503 and time.monotonic() - start < 2


async def test_readyz_reports_draining_while_healthz_stays_ok(client: httpx.AsyncClient, drain) -> None:
    drain.start()
    assert (await client.get("/readyz")).status_code == 503
    assert (await client.get("/readyz")).json()["status"] == "draining"
    assert (await client.get("/healthz")).status_code == 200


async def test_fault_injection_is_off_by_default(client: httpx.AsyncClient) -> None:
    assert (await client.get("/orders")).status_code == 200


async def test_fault_injection_errors_spare_operational_endpoints(app_factory) -> None:
    fault = FaultConfig(enabled=True, error_rate=1.0)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app_factory(fault=fault)), base_url="http://t") as c:
        injected = await c.get("/orders")
        assert injected.status_code == 503 and injected.json()["error"]["code"] == "fault_injected"
        for path in ("/healthz", "/readyz", "/metrics"):
            assert (await c.get(path)).status_code == 200, path
        assert 'route="/orders"' in (await c.get("/metrics")).text  # injected failures are still measured


async def test_fault_injection_adds_latency_only_to_business_endpoints(app_factory) -> None:
    fault = FaultConfig(enabled=True, latency_ms=150)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app_factory(fault=fault)), base_url="http://t") as c:
        start = time.monotonic()
        await c.get("/orders")
        assert time.monotonic() - start >= 0.15
        start = time.monotonic()
        await c.get("/healthz")
        assert time.monotonic() - start < 0.1


async def test_fault_injection_disabled_ignores_the_other_settings(app_factory) -> None:
    fault = FaultConfig(enabled=False, latency_ms=500, error_rate=1.0)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app_factory(fault=fault)), base_url="http://t") as c:
        start = time.monotonic()
        response = await c.get("/orders")
    assert response.status_code == 200 and time.monotonic() - start < 0.3
