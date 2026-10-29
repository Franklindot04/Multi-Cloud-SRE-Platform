"""Forward-only SQL migrations, run as a separate step (a one-shot command or a Kubernetes Job).

    python -m orders.migrate

Migrations are the numbered .sql files in the migrations directory. The runner takes a session-level PostgreSQL
advisory lock, so two copies running at once (for example two replicas starting together) take turns instead of
racing; applies each pending file in its own transaction and records it in schema_migrations with a checksum;
and refuses to continue if an applied file was edited. Running it again applies nothing. There are no down
migrations: a mistake is fixed by a new migration.

If the database is not ready yet (not reachable, the role or its password not reconciled, the database not created),
the command waits and retries for MIGRATE_WAIT_SECONDS (default 0: fail at once) with a message on every attempt,
instead of exiting. Waiting happens inside the process, so a Kubernetes Job's retry budget is not used up while the
database comes up. Errors that are not about readiness (a bad migration, a changed checksum) fail at once.
"""

from __future__ import annotations

import asyncio
import hashlib
import os
import sys
import time
from collections.abc import Awaitable, Callable
from pathlib import Path

import asyncpg

from orders.config import Config, ConfigError, DbConfig

MIGRATIONS_DIR = Path(__file__).parent / "migrations"
# Arbitrary constant identifying this service's migration lock.
ADVISORY_LOCK_ID = 7_244_001


class MigrationError(Exception):
    pass


def discover(directory: Path = MIGRATIONS_DIR) -> list[tuple[str, str, str]]:
    """Return (version, name, sql) for every migration file, in order."""
    found = []
    for path in sorted(directory.glob("*.sql")):
        version, _, name = path.stem.partition("_")
        if not version.isdigit():
            raise MigrationError(f"migration file {path.name} must start with a number")
        found.append((version, name, path.read_text(encoding="utf-8")))
    versions = [v for v, _, _ in found]
    if len(set(versions)) != len(versions):
        raise MigrationError("two migration files share a version number")
    return found


def checksum(sql: str) -> str:
    return hashlib.sha256(sql.encode()).hexdigest()


async def migrate(conn: asyncpg.Connection, migrations: list[tuple[str, str, str]]) -> list[str]:
    """Apply pending migrations on conn and return the versions that were applied."""
    await conn.execute("SELECT pg_advisory_lock($1)", ADVISORY_LOCK_ID)
    try:
        await conn.execute(
            "CREATE TABLE IF NOT EXISTS schema_migrations ("
            "version text PRIMARY KEY, name text NOT NULL, checksum text NOT NULL, "
            "applied_at timestamptz NOT NULL DEFAULT now())"
        )
        applied = {
            r["version"]: r["checksum"] for r in await conn.fetch("SELECT version, checksum FROM schema_migrations")
        }
        known = {v for v, _, _ in migrations}
        unknown = set(applied) - known
        if unknown:
            raise MigrationError(f"the database has migrations this build does not know: {sorted(unknown)}")
        done: list[str] = []
        for version, name, sql in migrations:
            digest = checksum(sql)
            if version in applied:
                if applied[version] != digest:
                    raise MigrationError(f"migration {version}_{name} was changed after it was applied")
                continue
            async with conn.transaction():
                await conn.execute(sql)
                await conn.execute(
                    "INSERT INTO schema_migrations (version, name, checksum) VALUES ($1, $2, $3)", version, name, digest
                )
            done.append(version)
        return done
    finally:
        await conn.execute("SELECT pg_advisory_unlock($1)", ADVISORY_LOCK_ID)


# Errors that mean "the database or its role is not ready yet": the server is unreachable or starting, the role
# does not exist (or its password is not set) yet, or the database has not been created.
NOT_READY = (
    OSError,
    asyncpg.PostgresConnectionError,
    asyncpg.CannotConnectNowError,
    asyncpg.InvalidPasswordError,
    asyncpg.InvalidAuthorizationSpecificationError,
    asyncpg.InvalidCatalogNameError,
)


async def connect_when_ready(
    db: DbConfig,
    wait_s: int,
    interval_s: float = 5.0,
    *,
    connect: Callable[..., Awaitable[asyncpg.Connection]] = asyncpg.connect,
    sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
    clock: Callable[[], float] = time.monotonic,
    log: Callable[[str], None] = print,
) -> asyncpg.Connection:
    """Connect, retrying while the database is not ready, for at most wait_s seconds."""
    start = clock()
    attempt = 0
    while True:
        attempt += 1
        try:
            return await connect(
                host=db.host,
                port=db.port,
                user=db.user,
                password=db.password,
                database=db.name,
                timeout=db.connect_timeout_s,
            )
        except NOT_READY as exc:
            waited = clock() - start
            if waited + interval_s > wait_s:
                raise
            log(
                f"database not ready (attempt {attempt}: {type(exc).__name__}: {exc}); "
                f"retrying in {interval_s:g}s ({waited:.0f}s of {wait_s}s)"
            )
            await sleep(interval_s)


async def run(db: DbConfig, wait_s: int = 0, interval_s: float = 5.0) -> list[str]:
    conn = await connect_when_ready(db, wait_s, interval_s)
    try:
        return await migrate(conn, discover())
    finally:
        await conn.close()


def _wait_settings() -> tuple[int, float]:
    try:
        wait_s = int(os.environ.get("MIGRATE_WAIT_SECONDS", "0"))
        interval_s = float(os.environ.get("MIGRATE_RETRY_INTERVAL_SECONDS", "5"))
    except ValueError as exc:
        raise ConfigError(f"MIGRATE_WAIT_SECONDS and MIGRATE_RETRY_INTERVAL_SECONDS must be numbers: {exc}") from exc
    if not 0 <= wait_s <= 3600 or not 0.1 <= interval_s <= 60:
        raise ConfigError("MIGRATE_WAIT_SECONDS must be 0-3600 and MIGRATE_RETRY_INTERVAL_SECONDS 0.1-60")
    return wait_s, interval_s


def main() -> int:
    try:
        config = Config.load()
        wait_s, interval_s = _wait_settings()
    except ConfigError as exc:
        print(f"invalid configuration:\n{exc}", file=sys.stderr)
        return 2
    if config.db is None:
        print("nothing to migrate: STORAGE is not postgres", file=sys.stderr)
        return 2
    try:
        applied = asyncio.run(run(config.db, wait_s, interval_s))
    except (MigrationError, OSError, asyncpg.PostgresError) as exc:
        print(f"migration failed: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1
    print(f"applied {len(applied)} migration(s): {', '.join(applied) or 'none, already up to date'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
