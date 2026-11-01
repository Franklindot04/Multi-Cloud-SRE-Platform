"""Request IDs, trace propagation, structured logs, Prometheus metrics, body limits and fault injection.

Implemented as a pure ASGI middleware so every response, including errors, is observed the same way.
"""

from __future__ import annotations

import asyncio
import json
import logging
import random
import re
import secrets
import sys
import time
import uuid
from contextvars import ContextVar
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any, ClassVar

from fastapi import HTTPException
from opentelemetry import trace
from prometheus_client import CollectorRegistry, Counter, Gauge, Histogram
from starlette.routing import Match
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from orders.config import FaultConfig
from orders.tracing import PROPAGATOR, current_trace

# Shared by every service so latency can be compared across them.
BUCKETS = (0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10)

OPERATIONAL_PATHS = frozenset({"/healthz", "/readyz", "/metrics", "/version"})

_REQUEST_ID = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
_TRACEPARENT = re.compile(r"^00-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})$")

request_id_var: ContextVar[str] = ContextVar("request_id", default="")
trace_var: ContextVar[tuple[str, str] | None] = ContextVar("trace", default=None)


def parse_traceparent(header: str) -> tuple[str, str] | None:
    """Return (trace id, flags) from a valid traceparent header, else None."""
    match = _TRACEPARENT.match(header)
    if match is None or set(match.group(1)) == {"0"} or set(match.group(2)) == {"0"}:
        return None
    return match.group(1), match.group(3)


def outbound_headers() -> dict[str, str]:
    """Headers to send on a call to another service: same request ID and trace, new span.

    With tracing on, the traceparent (and any tracestate and baggage) describes the active span. Without it, the
    trace of the request is kept and the span ID is new.
    """
    headers: dict[str, str] = {}
    if request_id := request_id_var.get():
        headers["X-Request-Id"] = request_id
    propagated: dict[str, str] = {}
    PROPAGATOR.inject(propagated)
    if "traceparent" in propagated:
        headers.update(propagated)
    elif trace_info := trace_var.get():
        headers["traceparent"] = f"00-{trace_info[0]}-{secrets.token_hex(8)}-{trace_info[1]}"
    return headers


class Metrics:
    """The HTTP metrics every service exposes under the same names."""

    def __init__(self, service: str, registry: CollectorRegistry) -> None:
        self.service = service
        self.requests = Counter(
            "http_requests_total",
            "Total HTTP requests handled.",
            ["service", "method", "route", "status"],
            registry=registry,
        )
        self.duration = Histogram(
            "http_request_duration_seconds",
            "HTTP request latency in seconds.",
            ["service", "method", "route"],
            buckets=BUCKETS,
            registry=registry,
        )
        self.in_flight = Gauge(
            "http_requests_in_flight",
            "HTTP requests currently being handled.",
            ["service"],
            registry=registry,
        ).labels(service)


class JsonLogger:
    """One JSON object per line on stdout."""

    LEVELS: ClassVar[dict[str, int]] = {"debug": 10, "info": 20, "warn": 30, "error": 40}

    def __init__(self, service: str, level: str = "info", stream: Any = None) -> None:
        self.service = service
        self.threshold = self.LEVELS.get(level, 20)
        self.stream = stream or sys.stdout

    def log(self, level: str, message: str, **fields: Any) -> None:
        if self.LEVELS[level] < self.threshold:
            return
        record = {
            "timestamp": datetime.now(UTC).isoformat(timespec="milliseconds"),
            "level": level,
            "message": message,
            "service": self.service,
        }
        # A line written inside a span carries its trace ID, in the same form as the request line.
        if (active := current_trace()) is not None:
            record["trace_id"] = active[0]
        record.update(fields)
        self.stream.write(json.dumps(record, default=str, separators=(",", ":")) + "\n")
        self.stream.flush()

    def info(self, message: str, **fields: Any) -> None:
        self.log("info", message, **fields)

    def warn(self, message: str, **fields: Any) -> None:
        self.log("warn", message, **fields)

    def error(self, message: str, **fields: Any) -> None:
        self.log("error", message, **fields)


@dataclass
class Drain:
    """Set when the process is asked to stop, so /readyz fails before the listener closes."""

    draining: bool = False

    def start(self) -> None:
        self.draining = True


class ObservabilityMiddleware:
    def __init__(
        self,
        app: ASGIApp,
        *,
        service: str,
        metrics: Metrics,
        logger: JsonLogger,
        max_body: int,
        fault: FaultConfig,
        routes: Any,
    ) -> None:
        self.app = app
        self.service = service
        self.metrics = metrics
        self.logger = logger
        self.max_body = max_body
        self.fault = fault
        self.routes = routes  # callable returning the router's routes

    def _route_template(self, scope: Scope) -> str:
        for route in self.routes():
            match, _ = route.matches(scope)
            if match == Match.FULL:
                return str(route.path)
        return "unmatched"

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        start = time.perf_counter()
        headers = {k.decode("latin-1").lower(): v.decode("latin-1") for k, v in scope["headers"]}
        request_id = headers.get("x-request-id", "")
        if not _REQUEST_ID.match(request_id):
            request_id = str(uuid.uuid4())
        # The server span's trace when there is one; otherwise (tracing off, or an operational endpoint) the trace of
        # the traceparent header, or a new one.
        parsed = current_trace() or parse_traceparent(headers.get("traceparent", ""))
        trace_info = parsed or (secrets.token_hex(16), "01")
        request_id_var.set(request_id)
        trace_var.set(trace_info)

        method = scope["method"]
        path = scope["path"]
        route = self._route_template(scope)
        status = 500
        started = False

        async def send_wrapper(message: Message) -> None:
            nonlocal status, started
            if message["type"] == "http.response.start":
                started = True
                status = message["status"]
                raw = [h for h in message.get("headers", []) if h[0].lower() != b"x-request-id"]
                raw.append((b"x-request-id", request_id.encode()))
                message = {**message, "headers": raw}
            await send(message)

        async def reject(code: int, error: str, text: str) -> None:
            body = json.dumps({"error": {"code": error, "message": text, "request_id": request_id}}).encode()
            await send_wrapper(
                {
                    "type": "http.response.start",
                    "status": code,
                    "headers": [(b"content-type", b"application/json"), (b"content-length", str(len(body)).encode())],
                }
            )
            await send_wrapper({"type": "http.response.body", "body": body})

        received = 0

        async def limited_receive() -> Message:
            nonlocal received
            message = await receive()
            if message["type"] == "http.request":
                received += len(message.get("body", b""))
                if received > self.max_body:
                    raise HTTPException(status_code=413, detail="request body is too large")
            return message

        self.metrics.in_flight.inc()
        try:
            declared = headers.get("content-length", "")
            if declared.isdigit() and int(declared) > self.max_body:
                await reject(413, "payload_too_large", "request body is too large")
            elif await self._inject_fault(path, reject):
                pass
            else:
                await self.app(scope, limited_receive, send_wrapper)
        except Exception as exc:
            self.logger.error("unhandled error", request_id=request_id, error=type(exc).__name__, detail=str(exc))
            span = trace.get_current_span()
            span.add_event("exception", {"exception.type": type(exc).__name__})  # not the message: it may hold data
            span.set_status(trace.Status(trace.StatusCode.ERROR, "unhandled error"))
            if not started:
                await reject(500, "internal_error", "internal error")
        finally:
            self.metrics.in_flight.dec()
            elapsed = time.perf_counter() - start
            self.metrics.requests.labels(self.service, method, route, str(status)).inc()
            self.metrics.duration.labels(self.service, method, route).observe(elapsed)
            self.logger.info(
                "request",
                request_id=request_id,
                trace_id=trace_info[0],
                method=method,
                route=route,
                status=status,
                duration_ms=round(elapsed * 1000, 3),
            )

    async def _inject_fault(self, path: str, reject: Any) -> bool:
        """Delay and fail requests when fault injection is on. Returns True if it answered."""
        if not self.fault.enabled or path in OPERATIONAL_PATHS:
            return False
        if self.fault.latency_ms > 0:
            await asyncio.sleep(self.fault.latency_ms / 1000)
        if self.fault.error_rate > 0 and random.random() < self.fault.error_rate:  # noqa: S311 - not security
            await reject(503, "fault_injected", "failure injected for testing")
            return True
        return False


def configure_stdlib_logging(level: str) -> None:
    """Keep library logging quiet and on stderr so stdout stays one JSON object per line."""
    logging.basicConfig(stream=sys.stderr, level=logging.WARNING if level != "debug" else logging.DEBUG)
