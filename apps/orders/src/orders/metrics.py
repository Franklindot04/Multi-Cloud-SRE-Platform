"""Metrics for the data layer. Names are shared with the other services where the same thing is measured."""

from __future__ import annotations

import time
from collections.abc import Callable
from contextlib import contextmanager

from prometheus_client import CollectorRegistry, Counter, Gauge, Histogram

DB_BUCKETS = (0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5)


class DbMetrics:
    """Pool state and query latency. The operation label is a fixed set of statement names."""

    def __init__(self, registry: CollectorRegistry) -> None:
        self._pool = Gauge("db_pool_connections", "Database pool connections by state.", ["state"], registry=registry)
        self.query_duration = Histogram(
            "db_query_duration_seconds",
            "Database query latency in seconds.",
            ["operation"],
            buckets=DB_BUCKETS,
            registry=registry,
        )

    def bind_pool(self, sizes: Callable[[], dict[str, int]]) -> None:
        for state in ("idle", "in_use", "max"):
            self._pool.labels(state).set_function(lambda s=state: sizes()[s])

    @contextmanager
    def timed(self, operation: str):
        start = time.perf_counter()
        try:
            yield
        finally:
            self.query_duration.labels(operation).observe(time.perf_counter() - start)


class CacheMetrics:
    def __init__(self, registry: CollectorRegistry) -> None:
        self.requests = Counter(
            "cache_requests_total", "Cache lookups and writes by result.", ["result"], registry=registry
        )
        for result in ("hit", "miss", "error"):
            self.requests.labels(result)


class OutboxMetrics:
    def __init__(self, registry: CollectorRegistry) -> None:
        self.unpublished = Gauge(
            "outbox_unpublished_events", "Outbox events not yet confirmed by the broker.", registry=registry
        )
        self.oldest_age = Gauge(
            "outbox_oldest_unpublished_age_seconds",
            "Age of the oldest unpublished outbox event, 0 when there is none.",
            registry=registry,
        )
        self.published = Counter(
            "messages_published_total", "Messages published to the broker by result.", ["result"], registry=registry
        )
        for result in ("ok", "error"):
            self.published.labels(result)
