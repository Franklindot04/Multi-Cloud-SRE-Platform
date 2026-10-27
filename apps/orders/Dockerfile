# syntax=docker/dockerfile:1

# Build stage: install the hash-pinned dependencies into a virtual environment.
# Base image digests are pinned in a later change (see apps/README.md).
FROM python:3.14.9-slim-trixie AS build
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1
RUN python -m venv /opt/venv
COPY requirements.txt /tmp/requirements.txt
RUN /opt/venv/bin/pip install --require-hashes -r /tmp/requirements.txt

# Final stage: the slim Python image rather than distroless, because the Python version here is
# pinned to the one the dependencies were locked and tested with, and distroless ships a different
# interpreter. It runs as the non-root user 10001 and works with a read-only root filesystem
# (bytecode writing is off and nothing is written to disk). There is no HEALTHCHECK:
# Kubernetes uses /healthz and /readyz.
FROM python:3.14.9-slim-trixie
ENV PATH=/opt/venv/bin:$PATH PYTHONPATH=/app/src PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
RUN groupadd --gid 10001 app \
 && useradd --uid 10001 --gid 10001 --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin app
COPY --from=build /opt/venv /opt/venv
COPY src /app/src
USER 10001:10001
EXPOSE 8081
ENTRYPOINT ["python", "-m", "orders.main"]
