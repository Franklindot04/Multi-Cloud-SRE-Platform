"""Configuration from environment variables, validated in one pass."""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass


class ConfigError(Exception):
    """Raised with every configuration problem found, not just the first."""


class _Reader:
    def __init__(self, env: Mapping[str, str]) -> None:
        self._env = env
        self.errors: list[str] = []

    def _raw(self, key: str) -> str | None:
        value = self._env.get(key)
        if value is None or value.strip() == "":
            return None
        return value.strip()

    def string(self, key: str, default: str) -> str:
        return self._raw(key) or default

    def integer(self, key: str, default: int, low: int, high: int) -> int:
        raw = self._raw(key)
        if raw is None:
            return default
        try:
            value = int(raw)
        except ValueError:
            value = low - 1
        if not low <= value <= high:
            self.errors.append(f"{key} must be an integer between {low} and {high}, got {raw!r}")
            return default
        return value

    def number(self, key: str, default: float, low: float, high: float) -> float:
        raw = self._raw(key)
        if raw is None:
            return default
        try:
            value = float(raw)
        except ValueError:
            value = low - 1
        if not low <= value <= high:
            self.errors.append(f"{key} must be a number between {low:g} and {high:g}, got {raw!r}")
            return default
        return value

    def boolean(self, key: str, default: bool) -> bool:
        raw = self._raw(key)
        if raw is None:
            return default
        if raw.lower() in {"true", "false"}:
            return raw.lower() == "true"
        self.errors.append(f"{key} must be true or false, got {raw!r}")
        return default

    def url(self, key: str, default: str) -> str:
        value = self.string(key, default).rstrip("/")
        if not value.startswith(("http://", "https://")):
            self.errors.append(f"{key} must start with http:// or https://, got {value!r}")
        return value

    def one_of(self, key: str, default: str, allowed: tuple[str, ...]) -> str:
        value = self.string(key, default)
        if value not in allowed:
            self.errors.append(f"{key} must be one of {', '.join(allowed)}, got {value!r}")
            return default
        return value


@dataclass(frozen=True)
class FaultConfig:
    enabled: bool = False
    latency_ms: int = 0
    error_rate: float = 0.0


@dataclass(frozen=True)
class Config:
    port: int
    log_level: str
    max_body_bytes: int
    max_orders: int
    payments_url: str
    notifier_url: str
    payments_timeout_s: float
    notifier_timeout_s: float
    readiness_timeout_s: float
    drain_seconds: int
    shutdown_timeout_seconds: int
    fault: FaultConfig

    @classmethod
    def load(cls, env: Mapping[str, str] | None = None) -> Config:
        r = _Reader(os.environ if env is None else env)
        config = cls(
            port=r.integer("PORT", 8081, 1, 65535),
            log_level=r.one_of("LOG_LEVEL", "info", ("debug", "info", "warn", "error")),
            max_body_bytes=r.integer("MAX_BODY_BYTES", 1 << 20, 1, 64 << 20),
            max_orders=r.integer("MAX_ORDERS", 100_000, 1, 10_000_000),
            payments_url=r.url("PAYMENTS_URL", "http://payments:8082"),
            notifier_url=r.url("NOTIFIER_URL", "http://notifier:8083"),
            payments_timeout_s=r.integer("PAYMENTS_TIMEOUT_MS", 2000, 100, 60000) / 1000,
            notifier_timeout_s=r.integer("NOTIFIER_TIMEOUT_MS", 1000, 100, 60000) / 1000,
            readiness_timeout_s=r.integer("READINESS_TIMEOUT_MS", 500, 50, 10000) / 1000,
            drain_seconds=r.integer("SHUTDOWN_DRAIN_SECONDS", 5, 0, 300),
            shutdown_timeout_seconds=r.integer("SHUTDOWN_TIMEOUT_SECONDS", 20, 1, 600),
            fault=FaultConfig(
                enabled=r.boolean("FAULT_INJECTION_ENABLED", False),
                latency_ms=r.integer("FAULT_LATENCY_MS", 0, 0, 60000),
                error_rate=r.number("FAULT_ERROR_RATE", 0.0, 0.0, 1.0),
            ),
        )
        if r.errors:
            raise ConfigError("\n".join(r.errors))
        return config
