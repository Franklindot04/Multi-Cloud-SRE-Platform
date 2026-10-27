"""Configuration from environment variables, validated in one pass."""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass, field, replace


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

    def secret(self, key: str) -> str | None:
        """A secret from KEY, or from the file named by KEY_FILE (for example a mounted Kubernetes Secret)."""
        direct = self._raw(key)
        file_name = self._raw(f"{key}_FILE")
        if direct and file_name:
            self.errors.append(f"set only one of {key} and {key}_FILE")
            return None
        if file_name:
            try:
                with open(file_name, encoding="utf-8") as handle:
                    value = handle.read().strip()
            except OSError as exc:
                self.errors.append(f"{key}_FILE {file_name!r} cannot be read: {exc.strerror}")
                return None
            if not value:
                self.errors.append(f"{key}_FILE {file_name!r} is empty")
                return None
            return value
        return direct

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
class DbConfig:
    host: str
    port: int
    name: str
    user: str
    password: str = field(repr=False)
    pool_min: int = 1
    pool_max: int = 5
    max_inactive_lifetime_s: float = 300.0
    connect_timeout_s: float = 3.0
    statement_timeout_ms: int = 5000


@dataclass(frozen=True)
class CacheConfig:
    host: str
    port: int
    password: str = field(repr=False)
    ttl_seconds: int = 30
    timeout_s: float = 0.2


@dataclass(frozen=True)
class AmqpConfig:
    host: str
    port: int
    user: str
    password: str = field(repr=False)
    vhost: str = "/"
    connect_timeout_s: float = 3.0
    publish_timeout_s: float = 5.0


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
    storage: str = "memory"
    cache: str = "none"
    messaging: str = "http"
    db: DbConfig | None = None
    cache_config: CacheConfig | None = None
    amqp: AmqpConfig | None = None
    outbox_batch_size: int = 20
    outbox_poll_interval_s: float = 0.5
    outbox_max_backoff_s: float = 30.0

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
        storage = r.one_of("STORAGE", "memory", ("memory", "postgres"))
        cache = r.one_of("CACHE", "none", ("none", "valkey"))
        messaging = r.one_of("MESSAGING", "http", ("http", "rabbitmq"))

        db = cache_config = amqp = None
        if storage == "postgres":
            db_password = r.secret("DB_PASSWORD")
            if db_password is None:
                r.errors.append("STORAGE=postgres needs DB_PASSWORD or DB_PASSWORD_FILE")
            db = DbConfig(
                host=r.string("DB_HOST", "postgres"),
                port=r.integer("DB_PORT", 5432, 1, 65535),
                name=r.string("DB_NAME", "orders"),
                user=r.string("DB_USER", "orders"),
                password=db_password or "",
                pool_min=r.integer("DB_POOL_MIN", 1, 0, 100),
                pool_max=r.integer("DB_POOL_MAX", 5, 1, 100),
                max_inactive_lifetime_s=float(r.integer("DB_CONN_MAX_IDLE_SECONDS", 300, 10, 86400)),
                connect_timeout_s=r.integer("DB_CONNECT_TIMEOUT_MS", 3000, 100, 60000) / 1000,
                statement_timeout_ms=r.integer("DB_STATEMENT_TIMEOUT_MS", 5000, 100, 600000),
            )
            if db.pool_min > db.pool_max:
                r.errors.append("DB_POOL_MIN must not exceed DB_POOL_MAX")
        if cache == "valkey":
            cache_password = r.secret("CACHE_PASSWORD")
            if cache_password is None:
                r.errors.append("CACHE=valkey needs CACHE_PASSWORD or CACHE_PASSWORD_FILE")
            cache_config = CacheConfig(
                host=r.string("CACHE_HOST", "valkey"),
                port=r.integer("CACHE_PORT", 6379, 1, 65535),
                password=cache_password or "",
                ttl_seconds=r.integer("CACHE_TTL_SECONDS", 30, 1, 86400),
                timeout_s=r.integer("CACHE_TIMEOUT_MS", 200, 10, 5000) / 1000,
            )
        if messaging == "rabbitmq":
            if storage != "postgres":
                r.errors.append(
                    "MESSAGING=rabbitmq needs STORAGE=postgres: events are written to a transactional outbox"
                )
            amqp_password = r.secret("AMQP_PASSWORD")
            if amqp_password is None:
                r.errors.append("MESSAGING=rabbitmq needs AMQP_PASSWORD or AMQP_PASSWORD_FILE")
            amqp = AmqpConfig(
                host=r.string("AMQP_HOST", "rabbitmq"),
                port=r.integer("AMQP_PORT", 5672, 1, 65535),
                user=r.string("AMQP_USER", "platform"),
                password=amqp_password or "",
                vhost=r.string("AMQP_VHOST", "/"),
                connect_timeout_s=r.integer("AMQP_CONNECT_TIMEOUT_MS", 3000, 100, 60000) / 1000,
                publish_timeout_s=r.integer("AMQP_PUBLISH_TIMEOUT_MS", 5000, 100, 60000) / 1000,
            )
        config = replace(
            config,
            storage=storage,
            cache=cache,
            messaging=messaging,
            db=db,
            cache_config=cache_config,
            amqp=amqp,
            outbox_batch_size=r.integer("OUTBOX_BATCH_SIZE", 20, 1, 500),
            outbox_poll_interval_s=r.integer("OUTBOX_POLL_INTERVAL_MS", 500, 50, 60000) / 1000,
            outbox_max_backoff_s=float(r.integer("OUTBOX_MAX_BACKOFF_SECONDS", 30, 1, 600)),
        )
        if r.errors:
            raise ConfigError("\n".join(r.errors))
        return config
