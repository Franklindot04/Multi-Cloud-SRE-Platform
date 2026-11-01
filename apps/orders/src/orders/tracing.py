"""OpenTelemetry tracing: setup from the standard OTEL_* variables, and the propagator the service uses.

Tracing is off unless OTEL_EXPORTER_OTLP_ENDPOINT or OTEL_EXPORTER_OTLP_TRACES_ENDPOINT is set, so local runs, tests
and CI need no Collector. OTEL_SDK_DISABLED=true and OTEL_TRACES_EXPORTER=none turn it off even when an endpoint is set.
The SDK reads the rest itself: the exporter reads OTEL_EXPORTER_OTLP_* (an endpoint that starts with http:// is a plain
connection, https:// uses TLS), the sampler reads OTEL_TRACES_SAMPLER and OTEL_TRACES_SAMPLER_ARG (parent-based, every
trace, when they are not set), and the resource reads OTEL_SERVICE_NAME and OTEL_RESOURCE_ATTRIBUTES.

Nothing here can fail a request or the process: setup problems turn tracing off, the exporter runs in the background and
drops spans it cannot deliver, and shutdown gives up after a short time.
"""

from __future__ import annotations

import logging
import os
import threading
import time
from collections.abc import Callable, Iterator, Mapping
from contextlib import contextmanager
from dataclasses import dataclass
from typing import TYPE_CHECKING
from urllib.parse import urlsplit

from opentelemetry import trace
from opentelemetry.baggage.propagation import W3CBaggagePropagator
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.propagators.composite import CompositePropagator
from opentelemetry.sdk.resources import SERVICE_NAME, SERVICE_VERSION, OTELResourceDetector, Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator

if TYPE_CHECKING:
    from orders.observability import JsonLogger

# W3C trace context plus baggage, the same as the Go services.
PROPAGATOR = CompositePropagator([TraceContextTextMapPropagator(), W3CBaggagePropagator()])

# How long shutdown waits for spans that are still queued. A Collector that does not answer must not hold up the exit.
FLUSH_TIMEOUT_S = 5.0

# The exporter reports every failed attempt; one line a minute is enough.
_LOG_INTERVAL_S = 60.0

TRACER_NAME = "orders"


def tracing_enabled(env: Mapping[str, str]) -> bool:
    def value(key: str) -> str:
        return env.get(key, "").strip()

    if value("OTEL_SDK_DISABLED").lower() == "true" or value("OTEL_TRACES_EXPORTER").lower() == "none":
        return False
    return bool(value("OTEL_EXPORTER_OTLP_ENDPOINT") or value("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"))


class _OneLinePerMinute(logging.Filter):
    def __init__(self, clock: Callable[[], float] = time.monotonic) -> None:
        super().__init__()
        self._clock = clock
        self._last = float("-inf")

    def filter(self, record: logging.LogRecord) -> bool:
        now = self._clock()
        if now - self._last < _LOG_INTERVAL_S:
            return False
        self._last = now
        return True


@dataclass
class Tracing:
    """The tracer provider of the process, or none when tracing is off."""

    provider: TracerProvider | None = None

    @property
    def enabled(self) -> bool:
        return self.provider is not None

    def tracer(self) -> trace.Tracer:
        if self.provider is None:
            return trace.NoOpTracer()
        return self.provider.get_tracer(TRACER_NAME)

    def shutdown(self, timeout_s: float = FLUSH_TIMEOUT_S) -> None:
        """Flush the queued spans and stop the exporter, giving up after timeout_s."""
        if self.provider is None:
            return
        worker = threading.Thread(target=self.provider.shutdown, name="tracing-shutdown", daemon=True)
        worker.start()
        worker.join(timeout_s)


def new_provider(service: str, version: str) -> TracerProvider:
    """A provider whose resource has service.name and service.version, overridable by the standard variables."""
    resource = Resource.create({SERVICE_NAME: service, SERVICE_VERSION: version}).merge(OTELResourceDetector().detect())
    return TracerProvider(resource=resource)


def setup_tracing(env: Mapping[str, str] | None, service: str, version: str, logger: JsonLogger) -> Tracing:
    """Build the provider with an OTLP/gRPC exporter and a batch processor, or return a disabled Tracing."""
    env = os.environ if env is None else env
    if not tracing_enabled(env):
        return Tracing()
    try:
        provider = new_provider(service, version)
        provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    except Exception as exc:
        logger.warn("tracing is disabled", error=type(exc).__name__)
        return Tracing()
    logging.getLogger("opentelemetry.exporter.otlp.proto.grpc").addFilter(_OneLinePerMinute())
    return Tracing(provider)


def current_trace() -> tuple[str, str] | None:
    """(trace id, flags) of the active span in the format of a traceparent header, or None without a valid span."""
    context = trace.get_current_span().get_span_context()
    if not context.is_valid:
        return None
    return format(context.trace_id, "032x"), format(int(context.trace_flags), "02x")


@contextmanager
def http_client_span(tracer: trace.Tracer, method: str, url: str) -> Iterator[trace.Span]:
    """A client span for one outgoing HTTP call, named "METHOD host:port" (a fixed set, never the path).

    Only the standard method, scheme, server address and port are recorded: no URL, no query, no headers and no
    bodies. The span is current inside the block, so the traceparent that outbound_headers() builds there names this
    span as the parent of the call.
    """
    parts = urlsplit(url)
    attributes: dict[str, str | int] = {"http.request.method": method, "url.scheme": parts.scheme}
    if parts.hostname:
        attributes["server.address"] = parts.hostname
    if port := parts.port:
        attributes["server.port"] = port
    with tracer.start_as_current_span(
        f"{method} {parts.netloc}",
        kind=trace.SpanKind.CLIENT,
        attributes=attributes,
        record_exception=False,
        set_status_on_exception=False,
    ) as span:
        yield span


def record_http_status(span: trace.Span, status_code: int) -> None:
    """Record the response status; a 5xx response is an error."""
    span.set_attribute("http.response.status_code", status_code)
    if status_code >= 500:
        span.set_attribute("error.type", str(status_code))
        span.set_status(trace.Status(trace.StatusCode.ERROR, "server error"))


def record_http_failure(span: trace.Span, exc: BaseException) -> None:
    """Record a call that got no response (connection error or timeout). Only the exception type is kept."""
    span.set_attribute("error.type", type(exc).__name__)
    span.add_event("exception", {"exception.type": type(exc).__name__})
    span.set_status(trace.Status(trace.StatusCode.ERROR, "request failed"))
