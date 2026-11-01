from __future__ import annotations

import io
import json
import logging
import re
import time
from collections.abc import Iterator

import httpx
import pytest
from opentelemetry import trace
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from prometheus_client import CollectorRegistry

from orders.api import create_app
from orders.clients import HttpPaymentsClient, PaymentApproved, PaymentResult, PaymentUnavailable
from orders.config import AmqpConfig, Config
from orders.messaging import EXCHANGE, AmqpPublisher, OutboxEvent
from orders.metrics import DbMetrics
from orders.observability import JsonLogger, outbound_headers, trace_var
from orders.postgres import _Timed
from orders.tracing import FLUSH_TIMEOUT_S, Tracing, _OneLinePerMinute, new_provider, setup_tracing, tracing_enabled
from tests.conftest import VALID_ORDER, FakeNotifier, FakePayments, make_config

REMOTE_TRACE = "4bf92f3577b34da6a3ce929d0e0e4736"
REMOTE_SPAN = "00f067aa0ba902b7"
TRACEPARENT = f"00-{REMOTE_TRACE}-{REMOTE_SPAN}-01"
HEX32 = re.compile(r"^[0-9a-f]{32}$")


@pytest.fixture
def exporter() -> InMemorySpanExporter:
    return InMemorySpanExporter()


@pytest.fixture
def tracing(exporter: InMemorySpanExporter) -> Iterator[Tracing]:
    provider = new_provider("orders", "1.0.0")
    provider.add_span_processor(SimpleSpanProcessor(exporter))
    yield Tracing(provider)
    provider.shutdown()


def build(tracing: Tracing, logs: io.StringIO, payments: FakePayments | None = None):
    return create_app(
        make_config(),
        payments=payments or FakePayments(),
        notifier=FakeNotifier(),
        logger=JsonLogger("orders", "info", logs),
        tracing=tracing,
    )


def client_for(app) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test")


def log_lines(logs: io.StringIO) -> list[dict]:
    return [json.loads(line) for line in logs.getvalue().splitlines()]


async def test_a_request_produces_a_server_span_named_after_the_route(tracing, exporter) -> None:
    async with client_for(build(tracing, io.StringIO())) as c:
        created = await c.post("/orders", json=VALID_ORDER, headers={"Idempotency-Key": "k-1"})
        await c.get(f"/orders/{created.json()['id']}")

    names = {s.name for s in exporter.get_finished_spans() if s.kind == trace.SpanKind.SERVER}
    assert names == {"POST /orders", "GET /orders/{order_id}"}
    for span in exporter.get_finished_spans():
        assert created.json()["id"] not in span.name


async def test_the_server_span_continues_the_incoming_trace(tracing, exporter) -> None:
    async with client_for(build(tracing, io.StringIO())) as c:
        await c.get("/orders", headers={"traceparent": TRACEPARENT})

    (span,) = [s for s in exporter.get_finished_spans() if s.kind == trace.SpanKind.SERVER]
    assert format(span.context.trace_id, "032x") == REMOTE_TRACE
    assert format(span.parent.span_id, "016x") == REMOTE_SPAN


@pytest.mark.parametrize("path", ["/healthz", "/readyz", "/metrics", "/version"])
async def test_operational_endpoints_create_no_spans(tracing, exporter, path) -> None:
    async with client_for(build(tracing, io.StringIO())) as c:
        await c.get(path)
    assert exporter.get_finished_spans() == ()


async def test_the_logged_trace_id_is_the_spans_trace_id(tracing, exporter) -> None:
    logs = io.StringIO()
    async with client_for(build(tracing, logs)) as c:
        await c.get("/orders")

    (span,) = exporter.get_finished_spans()
    (line,) = [entry for entry in log_lines(logs) if entry["message"] == "request"]
    assert line["trace_id"] == format(span.context.trace_id, "032x")
    assert HEX32.match(line["trace_id"])
    assert '"trace_id":"' + line["trace_id"] + '"' in logs.getvalue()  # compact JSON, as the Loki regex expects


async def test_an_unhandled_exception_sets_the_status_without_the_message(tracing, exporter) -> None:
    def boom(_order_id: str) -> PaymentResult:
        raise RuntimeError("card 4111 secret")

    async with client_for(build(tracing, io.StringIO(), FakePayments(boom))) as c:
        response = await c.post("/orders", json=VALID_ORDER, headers={"Idempotency-Key": "k-2"})

    assert response.status_code == 500
    (span,) = exporter.get_finished_spans()
    assert span.status.status_code == trace.StatusCode.ERROR
    assert "secret" not in json.dumps([dict(e.attributes) for e in span.events] + [span.status.description])


def event(traceparent: str | None) -> OutboxEvent:
    return OutboxEvent(
        id="6f1d7a52-3a48-4c8e-9a53-0f4f7a8e1d11",
        event_type="order.paid",
        aggregate_id="o-1",
        payload='{"data":{"customer_id":"cust-1"}}',
        request_id="req-1",
        traceparent=traceparent,
    )


class FakeExchange:
    def __init__(self) -> None:
        self.sent: list[tuple[object, str]] = []

    async def publish(self, message, routing_key: str, **_kwargs) -> None:
        self.sent.append((message, routing_key))


def publisher_with(tracing: Tracing | None, logs: io.StringIO) -> tuple[AmqpPublisher, FakeExchange]:
    publisher = AmqpPublisher(
        AmqpConfig(host="rabbitmq", port=5672, user="u", password="p"), tracing, JsonLogger("orders", "debug", logs)
    )
    exchange = FakeExchange()

    async def ensure() -> FakeExchange:
        return exchange

    publisher._ensure = ensure  # type: ignore[method-assign]
    return publisher, exchange


async def test_publishing_adds_a_producer_span_and_a_traceparent_header(tracing, exporter) -> None:
    logs = io.StringIO()
    publisher, exchange = publisher_with(tracing, logs)
    await publisher.publish(event(TRACEPARENT))

    (span,) = exporter.get_finished_spans()
    assert span.name == f"{EXCHANGE} publish" and span.kind == trace.SpanKind.PRODUCER
    attributes = dict(span.attributes)
    assert attributes == {
        "messaging.system": "rabbitmq",
        "messaging.operation.type": "send",
        "messaging.destination.name": EXCHANGE,
        "messaging.rabbitmq.destination.routing_key": "order.paid",
        "messaging.message.body.size": len(event(None).payload),
    }
    # The producer span continues the trace of the request that stored the event.
    assert format(span.context.trace_id, "032x") == REMOTE_TRACE
    assert format(span.parent.span_id, "016x") == REMOTE_SPAN

    ((message, routing_key),) = exchange.sent
    assert routing_key == "order.paid"
    header = message.headers["traceparent"]
    assert isinstance(header, str)
    flags = format(int(span.context.trace_flags), "02x")
    assert header == f"00-{REMOTE_TRACE}-{format(span.context.span_id, '016x')}-{flags}"
    assert message.headers["event_id"] == event(None).id and message.headers["request_id"] == "req-1"
    assert "cust-1" not in json.dumps({k: str(v) for k, v in attributes.items()})


async def test_log_lines_written_while_publishing_carry_the_trace_id(tracing, exporter) -> None:
    logs = io.StringIO()
    publisher, _ = publisher_with(tracing, logs)
    await publisher.publish(event(TRACEPARENT))

    (span,) = exporter.get_finished_spans()
    (line,) = log_lines(logs)
    assert line["message"] == "event published"
    assert line["trace_id"] == format(span.context.trace_id, "032x")


async def test_a_failed_publish_marks_the_span_and_logs_with_the_trace_id(tracing, exporter) -> None:
    logs = io.StringIO()
    publisher, _ = publisher_with(tracing, logs)

    async def broken() -> FakeExchange:
        raise ConnectionError("amqp://user:secret@host")

    publisher._ensure = broken  # type: ignore[method-assign]
    with pytest.raises(ConnectionError):
        await publisher.publish(event(TRACEPARENT))

    (span,) = exporter.get_finished_spans()
    assert span.status.status_code == trace.StatusCode.ERROR
    assert "secret" not in json.dumps([dict(e.attributes) for e in span.events])
    (line,) = log_lines(logs)
    assert line["message"] == "event not published" and line["trace_id"] == REMOTE_TRACE
    assert "secret" not in logs.getvalue()


async def test_without_tracing_the_stored_traceparent_is_sent_unchanged() -> None:
    logs = io.StringIO()
    publisher, exchange = publisher_with(None, logs)
    await publisher.publish(event(TRACEPARENT))
    await publisher.publish(event(None))

    (first, _), (second, _) = exchange.sent
    assert first.headers["traceparent"] == TRACEPARENT
    assert "traceparent" not in second.headers
    # Lines for the first event carry the trace of its stored traceparent; the second event has none.
    first_line, second_line = log_lines(logs)
    assert first_line["trace_id"] == REMOTE_TRACE and "trace_id" not in second_line


def test_database_spans_carry_the_operation_and_no_statement_or_error_text(tracing, exporter) -> None:
    timed = _Timed(
        DbMetrics(CollectorRegistry()), JsonLogger("orders", "info", io.StringIO()), tracing.tracer(), "create_order"
    )
    with timed:
        pass
    with (
        pytest.raises(ValueError, match="Key"),
        _Timed(
            DbMetrics(CollectorRegistry()), JsonLogger("orders", "info", io.StringIO()), tracing.tracer(), "get_order"
        ),
    ):
        raise ValueError("Key (customer_id)=(cust-1) already exists")

    ok, failed = exporter.get_finished_spans()
    assert ok.name == "db create_order" and ok.kind == trace.SpanKind.CLIENT
    assert dict(ok.attributes) == {"db.system.name": "postgresql", "db.operation.name": "create_order"}
    assert failed.status.status_code == trace.StatusCode.ERROR
    assert "cust-1" not in json.dumps([dict(e.attributes) for e in failed.events] + [failed.status.description])
    assert [dict(e.attributes) for e in failed.events] == [{"exception.type": "ValueError"}]


def test_outbound_headers_and_logs_inside_a_span_use_the_spans_context(tracing) -> None:
    logs = io.StringIO()
    logger = JsonLogger("orders", "info", logs)
    with tracing.tracer().start_as_current_span("work") as span:
        headers = outbound_headers()
        logger.info("inside")
    logger.info("outside")

    trace_id = format(span.get_span_context().trace_id, "032x")
    span_id = format(span.get_span_context().span_id, "016x")
    flags = format(int(span.get_span_context().trace_flags), "02x")
    assert headers["traceparent"] == f"00-{trace_id}-{span_id}-{flags}"
    inside, outside = log_lines(logs)
    assert inside["trace_id"] == trace_id and "trace_id" not in outside


@pytest.mark.parametrize(
    ("env", "expected"),
    [
        ({}, False),
        ({"OTEL_EXPORTER_OTLP_ENDPOINT": "  "}, False),
        ({"OTEL_EXPORTER_OTLP_ENDPOINT": "http://collector:4317"}, True),
        ({"OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": "http://collector:4317"}, True),
        ({"OTEL_EXPORTER_OTLP_ENDPOINT": "http://collector:4317", "OTEL_SDK_DISABLED": "true"}, False),
        ({"OTEL_EXPORTER_OTLP_ENDPOINT": "http://collector:4317", "OTEL_TRACES_EXPORTER": "none"}, False),
    ],
)
def test_tracing_is_on_only_with_an_endpoint(env, expected) -> None:
    assert tracing_enabled(env) is expected


async def test_tracing_is_off_by_default_and_the_service_works() -> None:
    logs = io.StringIO()
    tracing = setup_tracing({}, "orders", "1.0.0", JsonLogger("orders", "info", logs))
    assert tracing.provider is None and not tracing.enabled
    tracing.shutdown()  # nothing to stop, and no error

    async with client_for(build(tracing, logs)) as c:
        response = await c.post(
            "/orders", json=VALID_ORDER, headers={"Idempotency-Key": "k-3", "traceparent": TRACEPARENT}
        )
    assert response.status_code == 201
    (line,) = [entry for entry in log_lines(logs) if entry["message"] == "request"]
    assert line["trace_id"] == REMOTE_TRACE  # the trace of the header, as before


def test_resource_has_service_name_version_and_namespace(monkeypatch, exporter) -> None:
    monkeypatch.setenv("OTEL_RESOURCE_ATTRIBUTES", "service.namespace=shop")
    provider = new_provider("orders", "1.2.3")
    provider.add_span_processor(SimpleSpanProcessor(exporter))
    with provider.get_tracer("t").start_as_current_span("x"):
        pass
    attributes = dict(exporter.get_finished_spans()[0].resource.attributes)
    assert attributes["service.name"] == "orders" and attributes["service.version"] == "1.2.3"
    assert attributes["service.namespace"] == "shop"

    monkeypatch.setenv("OTEL_SERVICE_NAME", "renamed")
    assert dict(new_provider("orders", "1.2.3").resource.attributes)["service.name"] == "renamed"


async def test_an_unreachable_collector_blocks_neither_startup_requests_nor_shutdown(monkeypatch) -> None:
    monkeypatch.setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:1")  # nothing listens here
    logs = io.StringIO()
    started = time.monotonic()
    tracing = setup_tracing(None, "orders", "1.0.0", JsonLogger("orders", "info", logs))
    assert tracing.enabled

    async with client_for(build(tracing, logs)) as c:
        response = await c.get("/orders")
    assert response.status_code == 200

    tracing.shutdown(timeout_s=2)
    assert time.monotonic() - started < FLUSH_TIMEOUT_S


def test_the_default_config_needs_no_tracing_settings() -> None:
    assert isinstance(Config.load({}), Config)


def payments_for(handler, tracing: Tracing | None = None) -> HttpPaymentsClient:
    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    return HttpPaymentsClient(client, "http://payments:8082", 1.0, tracing)


def approved(request: httpx.Request) -> httpx.Response:
    return httpx.Response(201, json={"id": "pay-1", "status": "approved"})


async def test_the_payments_call_has_a_client_span_and_sends_its_context(tracing, exporter) -> None:
    sent: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        sent.append(request)
        return approved(request)

    with tracing.tracer().start_as_current_span("parent") as parent:
        result = await payments_for(handler, tracing).authorize("o-1", 2500, "USD")

    assert result == PaymentApproved("pay-1")
    client = next(s for s in exporter.get_finished_spans() if s.kind == trace.SpanKind.CLIENT)
    assert client.name == "POST payments:8082"
    assert client.parent.span_id == parent.get_span_context().span_id
    assert dict(client.attributes) == {
        "http.request.method": "POST",
        "url.scheme": "http",
        "server.address": "payments",
        "server.port": 8082,
        "http.response.status_code": 201,
    }
    assert client.status.status_code == trace.StatusCode.UNSET

    # The header names the client span, not its parent.
    flags = format(int(client.context.trace_flags), "02x")
    expected = f"00-{format(client.context.trace_id, '032x')}-{format(client.context.span_id, '016x')}-{flags}"
    assert sent[0].headers["traceparent"] == expected
    assert format(client.context.span_id, "016x") != format(parent.get_span_context().span_id, "016x")


async def test_a_5xx_answer_and_a_connection_error_mark_the_client_span(tracing, exporter) -> None:
    result = await payments_for(lambda _r: httpx.Response(503, text="card 4111 secret"), tracing).authorize(
        "o-1", 1, "USD"
    )
    assert isinstance(result, PaymentUnavailable)

    def refuse(_r: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("could not reach payments with secret")

    result = await payments_for(refuse, tracing).authorize("o-2", 1, "USD")
    assert isinstance(result, PaymentUnavailable)

    server_error, failed = exporter.get_finished_spans()
    assert (
        server_error.status.status_code == trace.StatusCode.ERROR and server_error.status.description == "server error"
    )
    assert dict(server_error.attributes)["http.response.status_code"] == 503
    assert failed.status.status_code == trace.StatusCode.ERROR and failed.status.description == "request failed"
    assert [dict(e.attributes) for e in failed.events] == [{"exception.type": "ConnectError"}]
    assert "secret" not in json.dumps([dict(s.attributes) for s in (server_error, failed)])


async def test_a_client_error_answer_is_not_marked_as_an_error(tracing, exporter) -> None:
    await payments_for(lambda _r: httpx.Response(422, json={}), tracing).authorize("o-1", 1, "USD")
    (span,) = exporter.get_finished_spans()
    assert span.status.status_code == trace.StatusCode.UNSET


async def test_without_tracing_the_payments_call_is_unchanged() -> None:
    sent: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        sent.append(request)
        return approved(request)

    token = trace_var.set((REMOTE_TRACE, "01"))
    try:
        result = await payments_for(handler).authorize("o-1", 2500, "USD")
    finally:
        trace_var.reset(token)

    assert result == PaymentApproved("pay-1")
    match = re.fullmatch(rf"00-{REMOTE_TRACE}-[0-9a-f]{{16}}-01", sent[0].headers["traceparent"])
    assert match is not None  # the trace of the request, a new span ID, as before


def test_the_exporter_log_filter_lets_one_message_through_a_minute() -> None:
    now = [1000.0]
    log_filter = _OneLinePerMinute(clock=lambda: now[0])
    record = logging.LogRecord("opentelemetry.exporter", logging.WARNING, __file__, 1, "export failed", None, None)

    assert log_filter.filter(record) is True  # the first failure
    for offset in (1, 10, 59.9):
        now[0] = 1000.0 + offset
        assert log_filter.filter(record) is False  # more failures inside the window
    now[0] = 1060.0
    assert log_filter.filter(record) is True  # the window is over
    now[0] = 1061.0
    assert log_filter.filter(record) is False  # and a new window has started
