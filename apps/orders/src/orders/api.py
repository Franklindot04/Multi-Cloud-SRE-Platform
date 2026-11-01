"""HTTP layer: routes, error envelope, operational endpoints."""

from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from typing import Annotated, Any

import httpx
from fastapi import FastAPI, Header, Query, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from prometheus_client import CONTENT_TYPE_LATEST, CollectorRegistry, generate_latest
from starlette.exceptions import HTTPException as StarletteHTTPException

from orders.cache import NoCache, OrderCache, ValkeyCache
from orders.clients import HttpNotifierClient, HttpPaymentsClient, NotifierClient, PaymentsClient
from orders.config import Config
from orders.messaging import AmqpPublisher, EventPublisher
from orders.metrics import CacheMetrics, DbMetrics, OutboxMetrics
from orders.models import IDEMPOTENCY_KEY_PATTERN, CreateOrderRequest, IdempotencyMismatch
from orders.observability import (
    Drain,
    JsonLogger,
    Metrics,
    ObservabilityMiddleware,
    request_id_var,
)
from orders.outbox import OutboxRelay
from orders.postgres import PostgresOrderRepository, create_pool, pool_sizes
from orders.repository import MemoryOrderRepository, OrderRepository
from orders.service import OrderService
from orders.tracing import Tracing

SERVICE = "orders"

# No span for the operational endpoints: probes and scrapes arrive every few seconds and would drown the traces.
UNTRACED_URLS = "/healthz$,/readyz$,/metrics$,/version$"

_CODES = {
    400: "bad_request",
    404: "not_found",
    405: "method_not_allowed",
    413: "payload_too_large",
    422: "validation_error",
    503: "unavailable",
}


def error_response(status: int, code: str, message: str) -> JSONResponse:
    body = {"error": {"code": code, "message": message, "request_id": request_id_var.get()}}
    return JSONResponse(body, status_code=status)


def create_app(
    config: Config,
    *,
    repo: OrderRepository | None = None,
    payments: PaymentsClient | None = None,
    notifier: NotifierClient | None = None,
    cache: OrderCache | None = None,
    publisher: EventPublisher | None = None,
    drain: Drain | None = None,
    logger: JsonLogger | None = None,
    registry: CollectorRegistry | None = None,
    tracing: Tracing | None = None,
) -> FastAPI:
    logger = logger or JsonLogger(SERVICE, config.log_level)
    registry = registry or CollectorRegistry()
    metrics = Metrics(SERVICE, registry)
    db_metrics = DbMetrics(registry)
    cache_metrics = CacheMetrics(registry)
    outbox_metrics = OutboxMetrics(registry)
    drain = drain or Drain()
    tracing = tracing or Tracing()
    http_client = httpx.AsyncClient()
    payments = payments or HttpPaymentsClient(http_client, config.payments_url, config.payments_timeout_s, tracing)
    notifier = notifier or HttpNotifierClient(http_client, config.notifier_url, config.notifier_timeout_s, logger)
    if cache is None:
        cache = (
            ValkeyCache.from_config(config.cache_config, cache_metrics, logger)
            if config.cache == "valkey"
            else NoCache()
        )
    use_outbox = config.messaging == "rabbitmq"
    if use_outbox and publisher is None:
        publisher = AmqpPublisher(config.amqp, tracing, logger)

    # The service needs the repository, which for PostgreSQL needs the pool created at startup.
    ctx: dict[str, Any] = {"repo": repo, "pool": None, "relay_task": None}
    if repo is None and config.storage == "memory":
        ctx["repo"] = MemoryOrderRepository(config.max_orders)

    def build_service() -> OrderService:
        return OrderService(ctx["repo"], payments, notifier, cache, notify_over_http=not use_outbox)

    if ctx["repo"] is not None:
        ctx["service"] = build_service()

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        if config.fault.enabled:
            logger.warn(
                "fault injection is ENABLED",
                latency_ms=config.fault.latency_ms,
                error_rate=config.fault.error_rate,
            )
        stop = asyncio.Event()
        if ctx["repo"] is None:
            pool = await create_pool(config.db)
            ctx["pool"] = pool
            db_metrics.bind_pool(lambda: pool_sizes(pool))
            ctx["repo"] = PostgresOrderRepository(
                pool, db_metrics, logger, emit_events=use_outbox, tracer=tracing.tracer()
            )
            ctx["service"] = build_service()
            if use_outbox:
                assert publisher is not None
                relay = OutboxRelay(
                    pool,
                    publisher,
                    db_metrics,
                    outbox_metrics,
                    logger,
                    batch_size=config.outbox_batch_size,
                    poll_interval_s=config.outbox_poll_interval_s,
                    max_backoff_s=config.outbox_max_backoff_s,
                )
                ctx["relay_task"] = asyncio.create_task(relay.run(stop), name="outbox-relay")
        yield
        stop.set()
        task = ctx["relay_task"]
        if task is not None:
            try:
                await asyncio.wait_for(task, timeout=5)
            except Exception:
                task.cancel()
        if publisher is not None:
            await publisher.close()
        await cache.close()
        if ctx["pool"] is not None:
            await ctx["pool"].close()
        await http_client.aclose()

    app = FastAPI(title="orders", version="1.0.0", lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
    app.add_middleware(
        ObservabilityMiddleware,
        service=SERVICE,
        metrics=metrics,
        logger=logger,
        max_body=config.max_body_bytes,
        fault=config.fault,
        routes=lambda: app.router.routes,
    )
    if tracing.provider is not None:
        # Added last, so it is the outermost middleware and the server span is active in the one above. The span is
        # named "METHOD route template", never the raw path. The internal receive and send spans are left out.
        FastAPIInstrumentor.instrument_app(
            app, tracer_provider=tracing.provider, excluded_urls=UNTRACED_URLS, exclude_spans=["receive", "send"]
        )

    @app.exception_handler(RequestValidationError)
    async def validation_error(_: Request, exc: RequestValidationError) -> JSONResponse:
        errors = exc.errors()
        if any(e.get("type") == "json_invalid" for e in errors):
            return error_response(400, "invalid_json", "request body is not valid JSON")
        first = errors[0] if errors else {}
        location = ".".join(str(part) for part in first.get("loc", ()) if part != "body")
        return error_response(422, "validation_error", f"{location}: {first.get('msg', 'invalid request')}".strip(": "))

    @app.exception_handler(StarletteHTTPException)
    async def http_error(_: Request, exc: StarletteHTTPException) -> JSONResponse:
        return error_response(exc.status_code, _CODES.get(exc.status_code, "error"), str(exc.detail))

    # --- operational endpoints ---

    @app.get("/healthz")
    async def healthz() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/readyz")
    async def readyz() -> JSONResponse:
        if drain.draining:
            return JSONResponse({"status": "draining"}, status_code=503)

        async def _failed() -> str:
            return "fail: NotStarted"

        async def probe(client: Any) -> str:
            try:
                await asyncio.wait_for(client.ready(), timeout=config.readiness_timeout_s)
            except Exception as exc:
                return f"fail: {type(exc).__name__}"
            return "ok"

        names = ["payments"]
        probes = [probe(payments)]
        if config.storage == "postgres":
            names.append("postgres")
            probes.append(probe(ctx["repo"]) if ctx["repo"] is not None else _failed())
        # Dependencies below degrade the service but do not stop it taking orders.
        optional: dict[str, Any] = {}
        if config.messaging == "http":
            optional["notifier"] = notifier
        if config.cache == "valkey":
            optional["valkey"] = cache
        if config.messaging == "rabbitmq" and publisher is not None:
            optional["rabbitmq"] = publisher
        results = await asyncio.gather(*probes, *(probe(c) for c in optional.values()))
        checks = dict(zip(names, results[: len(names)], strict=True))
        for name, outcome in zip(optional, results[len(names) :], strict=True):
            checks[name] = outcome if outcome == "ok" else f"degraded: {outcome.removeprefix('fail: ')}"
        if any(checks[n] != "ok" for n in names):
            return JSONResponse({"status": "not_ready", "checks": checks}, status_code=503)
        return JSONResponse({"status": "ready", "checks": checks})

    @app.get("/metrics")
    async def metrics_endpoint() -> Response:
        return Response(generate_latest(registry), media_type=CONTENT_TYPE_LATEST)

    # --- business endpoints ---

    @app.post("/orders")
    async def create_order(
        body: CreateOrderRequest,
        idempotency_key: Annotated[str | None, Header(alias="Idempotency-Key")] = None,
    ) -> JSONResponse:
        if idempotency_key is None or not IDEMPOTENCY_KEY_PATTERN.match(idempotency_key):
            return error_response(
                400, "missing_idempotency_key", "Idempotency-Key header is required (1-128 printable characters)"
            )
        if body.total_minor() <= 0:
            return error_response(422, "validation_error", "the order total must be greater than zero")
        try:
            result = await ctx["service"].create(idempotency_key, body)
        except IdempotencyMismatch:
            return error_response(
                422, "idempotency_key_mismatch", "this Idempotency-Key was used with a different request body"
            )
        return JSONResponse(result.order.model_dump(mode="json"), status_code=result.http_status)

    @app.get("/orders")
    async def list_orders(
        limit: Annotated[int, Query(ge=1, le=200)] = 50,
        offset: Annotated[int, Query(ge=0)] = 0,
    ) -> dict[str, Any]:
        orders, total = await ctx["service"].list(limit, offset)
        return {"items": [o.model_dump(mode="json") for o in orders], "total": total, "limit": limit, "offset": offset}

    @app.get("/orders/{order_id}")
    async def get_order(order_id: str) -> JSONResponse:
        order = await ctx["service"].get(order_id)
        if order is None:
            return error_response(404, "not_found", "order not found")
        return JSONResponse(order.model_dump(mode="json"))

    app.state.drain = drain
    return app
