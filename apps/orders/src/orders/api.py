"""HTTP layer: routes, error envelope, operational endpoints."""

from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from typing import Annotated, Any

import httpx
from fastapi import FastAPI, Header, Query, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from prometheus_client import CONTENT_TYPE_LATEST, CollectorRegistry, generate_latest
from starlette.exceptions import HTTPException as StarletteHTTPException

from orders.clients import HttpNotifierClient, HttpPaymentsClient, NotifierClient, PaymentsClient
from orders.config import Config
from orders.models import IDEMPOTENCY_KEY_PATTERN, CreateOrderRequest, IdempotencyMismatch
from orders.observability import (
    Drain,
    JsonLogger,
    Metrics,
    ObservabilityMiddleware,
    request_id_var,
)
from orders.repository import MemoryOrderRepository, OrderRepository
from orders.service import OrderService

SERVICE = "orders"

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
    drain: Drain | None = None,
    logger: JsonLogger | None = None,
    registry: CollectorRegistry | None = None,
) -> FastAPI:
    logger = logger or JsonLogger(SERVICE, config.log_level)
    registry = registry or CollectorRegistry()
    metrics = Metrics(SERVICE, registry)
    drain = drain or Drain()
    repo = repo or MemoryOrderRepository(config.max_orders)
    http_client = httpx.AsyncClient()
    payments = payments or HttpPaymentsClient(http_client, config.payments_url, config.payments_timeout_s)
    notifier = notifier or HttpNotifierClient(http_client, config.notifier_url, config.notifier_timeout_s, logger)
    service = OrderService(repo, payments, notifier)

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        if config.fault.enabled:
            logger.warn(
                "fault injection is ENABLED",
                latency_ms=config.fault.latency_ms,
                error_rate=config.fault.error_rate,
            )
        yield
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

        async def probe(client: Any) -> str:
            try:
                await asyncio.wait_for(client.ready(), timeout=config.readiness_timeout_s)
            except Exception as exc:
                return f"fail: {type(exc).__name__}"
            return "ok"

        pay, note = await asyncio.gather(probe(payments), probe(notifier))
        checks = {"payments": pay, "notifier": note if note == "ok" else f"degraded: {note.removeprefix('fail: ')}"}
        if pay != "ok":
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
            result = await service.create(idempotency_key, body)
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
        orders, total = service.list(limit, offset)
        return {"items": [o.model_dump(mode="json") for o in orders], "total": total, "limit": limit, "offset": offset}

    @app.get("/orders/{order_id}")
    async def get_order(order_id: str) -> JSONResponse:
        order = service.get(order_id)
        if order is None:
            return error_response(404, "not_found", "order not found")
        return JSONResponse(order.model_dump(mode="json"))

    app.state.drain = drain
    return app
