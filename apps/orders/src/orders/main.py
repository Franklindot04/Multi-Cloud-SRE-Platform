"""Process entry point: configuration, logging, and graceful shutdown."""

from __future__ import annotations

import signal
import sys
import threading
from types import FrameType

import uvicorn

from orders.api import SERVICE, create_app
from orders.config import Config, ConfigError
from orders.observability import Drain, JsonLogger, configure_stdlib_logging


class DrainingServer(uvicorn.Server):
    """On SIGTERM, fail /readyz first, wait for the drain period, then stop accepting connections."""

    def __init__(self, config: uvicorn.Config, drain: Drain, drain_seconds: int, logger: JsonLogger) -> None:
        super().__init__(config)
        self._drain = drain
        self._drain_seconds = drain_seconds
        self._logger = logger
        self._signalled = False

    def handle_exit(self, sig: int, frame: FrameType | None) -> None:
        if self._signalled:
            super().handle_exit(sig, frame)  # a second signal exits straight away
            return
        self._signalled = True
        self._logger.info("shutdown requested", signal=signal.Signals(sig).name, drain_seconds=self._drain_seconds)
        self._drain.start()
        threading.Timer(self._drain_seconds, super().handle_exit, args=(sig, frame)).start()


def main() -> int:
    try:
        config = Config.load()
    except ConfigError as exc:
        print(f"invalid configuration:\n{exc}", file=sys.stderr)
        return 2

    configure_stdlib_logging(config.log_level)
    logger = JsonLogger(SERVICE, config.log_level)
    drain = Drain()
    app = create_app(config, drain=drain, logger=logger)

    server = DrainingServer(
        uvicorn.Config(
            app,
            host="0.0.0.0",  # noqa: S104 - listens in a container
            port=config.port,
            log_config=None,
            access_log=False,
            timeout_graceful_shutdown=config.shutdown_timeout_seconds,
            server_header=False,
        ),
        drain,
        config.drain_seconds,
        logger,
    )
    logger.info("listening", port=config.port)
    server.run()
    logger.info("stopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
