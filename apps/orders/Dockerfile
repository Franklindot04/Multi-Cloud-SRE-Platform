# syntax=docker/dockerfile:1

# Build stage: install the hash-pinned dependencies into a virtual environment.
# Base image digests are pinned in a later change (see apps/README.md).
FROM python:3.14.9-slim-trixie AS build
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1
# The venv is created without pip. The pip of this stage installs into it from outside, so the final image
# gets the dependencies and no installer (pip carries its own copies of other libraries, which show up in
# vulnerability scans as if the application used them).
RUN python -m venv --without-pip /opt/venv
COPY requirements.txt /tmp/requirements.txt
RUN pip --python /opt/venv/bin/python install --require-hashes -r /tmp/requirements.txt

# Final stage: the slim Python image rather than distroless, because the Python version here is
# pinned to the one the dependencies were locked and tested with, and distroless ships a different
# interpreter. It runs as the non-root user 10001 and works with a read-only root filesystem
# (bytecode writing is off and nothing is written to disk). There is no HEALTHCHECK:
# Kubernetes uses /healthz and /readyz.
FROM python:3.14.9-slim-trixie
ENV PATH=/opt/venv/bin:$PATH PYTHONPATH=/app/src PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
RUN groupadd --gid 10001 app \
 && useradd --uid 10001 --gid 10001 --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin app
# Nothing installs packages at run time, so pip is removed from the base image too: its files, its commands and
# the wheel that ensurepip would install it from. The last command fails the build if pip is still reachable
# (for example after a base image change that puts it somewhere else).
RUN rm -rf /usr/local/bin/pip /usr/local/bin/pip3 /usr/local/bin/pip3.* \
      /usr/local/lib/python3.*/site-packages/pip /usr/local/lib/python3.*/site-packages/pip-*.dist-info \
      /usr/local/lib/python3.*/ensurepip/_bundled \
 && ! command -v pip \
 && ! python -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('pip') else 1)"
COPY --from=build /opt/venv /opt/venv
COPY src /app/src
USER 10001:10001
EXPOSE 8081
ENTRYPOINT ["python", "-m", "orders.main"]
