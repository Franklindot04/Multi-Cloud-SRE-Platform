#!/usr/bin/env bash
# Test, build or lint the sample application services.
#
#   scripts/apps.sh test    unit and handler tests for every service
#   scripts/apps.sh lint    go vet and gofmt, ruff, checkstyle, shellcheck (as CI runs it)
#   scripts/apps.sh build   container images, tagged sre-sample/<service>:local
#   scripts/apps.sh integration
#                           integration tests against the running integration stack (started by
#                           scripts/integration-test.sh, which also exports the credentials from apps/.env)
#
# Each service is skipped with a message when its toolchain is missing. Nothing is pushed anywhere.
#
# Environment:
#   JAVA_IMAGE  Maven image used for payments when no local JDK 25 exists
#               (default maven:3.9.12-eclipse-temurin-25-noble)
#   APPS_SERVICES  space-separated services to act on (gateway notifier orders payments); default all.
#               The shell script lint step runs only when this is unset. CI uses it for per-service jobs.
#   INTEGRATION_NETWORK  compose network of the integration stack (default sre-sample-integration_default);
#               the payments tests run in a container on it, so they need no JDK 25 and no published port
set -euo pipefail

usage() {
  echo "Usage: $0 test|lint|build|integration"
}

case "${1:-}" in
  test | lint | build | integration) action="$1" ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

cd "$(dirname "${BASH_SOURCE[0]}")/.."
apps="apps"
java_image="${JAVA_IMAGE:-maven:3.9.12-eclipse-temurin-25-noble}"
status=0
ran=0
skipped=0

have() { command -v "$1" > /dev/null 2>&1; }

# wanted SERVICE: true when APPS_SERVICES is unset or lists the service.
wanted() {
  [ -z "${APPS_SERVICES:-}" ] && return 0
  case " $APPS_SERVICES " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

skip() {
  skipped=$((skipped + 1))
  echo "    skipped: $1"
}

# run_step LABEL COMMAND...: runs a command and records a failure without stopping the others.
run_step() {
  local label="$1"
  shift
  ran=$((ran + 1))
  echo "==> $label"
  if ! "$@"; then
    echo "    FAILED: $label" >&2
    status=1
  fi
}

docker_ready() { have docker && docker info > /dev/null 2>&1; }

# Major version of the local JDK, or 0 when there is none.
java_major() {
  have java || {
    echo 0
    return
  }
  java -version 2>&1 | sed -n 's/.*version "\([0-9]*\).*/\1/p' | head -n 1
}

# --- Go services ---

go_check() {
  local svc="$1"
  (
    cd "$apps/$svc"
    case "$action" in
      test) go test -race ./... ;;
      integration)
        AMQP_HOST=localhost AMQP_USER="${RABBITMQ_DEFAULT_USER:?}" AMQP_PASSWORD="${RABBITMQ_DEFAULT_PASS:?}" \
          go test -tags integration -race -count=1 ./...
        ;;
      lint)
        go vet ./...
        unformatted="$(gofmt -l .)"
        if [ -n "$unformatted" ]; then
          echo "gofmt needed on:" >&2
          echo "$unformatted" >&2
          exit 1
        fi
        ;;
    esac
  )
}

# --- Python service ---

python_check() {
  local dir="$apps/orders" py="$apps/orders/.venv/bin/python"
  if [ ! -x "$py" ]; then
    if have uv; then
      echo "    creating $dir/.venv with uv (Python 3.14, hash-checked dependencies)"
      uv venv --python 3.14 "$dir/.venv" -q
      uv pip install --python "$py" --require-hashes -r "$dir/requirements-dev.txt" -q
    else
      return 3
    fi
  fi
  (
    cd "$dir"
    case "$action" in
      test) .venv/bin/python -m pytest -q ;;
      integration)
        INTEGRATION=1 DB_HOST=localhost DB_NAME=orders DB_USER=orders DB_PASSWORD="${ORDERS_DB_PASSWORD:?}" \
          CACHE_HOST=localhost CACHE_PASSWORD="${VALKEY_PASSWORD:?}" \
          AMQP_HOST=localhost AMQP_USER="${RABBITMQ_DEFAULT_USER:?}" AMQP_PASSWORD="${RABBITMQ_DEFAULT_PASS:?}" \
          .venv/bin/python -m pytest -q tests/integration
        ;;
      lint)
        .venv/bin/ruff check .
        .venv/bin/ruff format --check .
        ;;
    esac
  )
}

# --- Java service ---

java_check() {
  local goal
  case "$action" in
    test) goal="test" ;;
    lint) goal="checkstyle:check" ;;
    integration) goal="test -Dtest=PostgresPaymentRepositoryTest" ;;
  esac
  if [ "$action" = "integration" ]; then
    docker_ready || return 3
    # shellcheck disable=SC2086 # the goal is a fixed string that must split into Maven arguments
    docker run --rm --network "${INTEGRATION_NETWORK:-sre-sample-integration_default}" \
      -e INTEGRATION=1 -e DB_HOST=postgres -e DB_NAME=payments -e DB_USER=payments -e DB_PASSWORD="${PAYMENTS_DB_PASSWORD:?}" \
      -v "$PWD/$apps/payments":/work -v sre-sample-m2:/root/.m2 -w /work "$java_image" mvn -B -ntp $goal
  elif [ "$(java_major)" -ge 25 ]; then
    (cd "$apps/payments" && ./mvnw -B -ntp "$goal")
  elif docker_ready; then
    echo "    no JDK 25 locally; using $java_image"
    docker run --rm -v "$PWD/$apps/payments":/work -v sre-sample-m2:/root/.m2 -w /work "$java_image" mvn -B -ntp "$goal"
  else
    return 3
  fi
}

if [ "$action" = "build" ]; then
  if docker_ready; then
    for svc in gateway orders payments notifier; do
      wanted "$svc" || continue
      run_step "build $svc image" docker build -q -t "sre-sample/$svc:local" "$apps/$svc"
    done
  else
    for svc in gateway orders payments notifier; do
      wanted "$svc" || continue
      echo "==> $svc"
      skip "Docker is not available"
    done
  fi
else
  for svc in gateway notifier; do
    wanted "$svc" || continue
    if [ "$action" = "integration" ] && [ "$svc" = "gateway" ]; then
      continue # the gateway has no data layer
    fi
    echo "==> $action $svc"
    if have go; then
      ran=$((ran + 1))
      go_check "$svc" || {
        echo "    FAILED: $action $svc" >&2
        status=1
      }
    else
      skip "go is not installed"
    fi
  done

  if wanted orders; then
    echo "==> $action orders"
    ran=$((ran + 1))
    rc=0
    python_check || rc=$?
    if [ "$rc" -eq 3 ]; then
      ran=$((ran - 1))
      skip "no apps/orders/.venv and uv is not installed (uv venv --python 3.14 apps/orders/.venv, then uv pip install --require-hashes -r apps/orders/requirements-dev.txt)"
    elif [ "$rc" -ne 0 ]; then
      echo "    FAILED: $action orders" >&2
      status=1
    fi
  fi

  if wanted payments; then
    echo "==> $action payments"
    ran=$((ran + 1))
    rc=0
    java_check || rc=$?
    if [ "$rc" -eq 3 ]; then
      ran=$((ran - 1))
      skip "neither a JDK 25 nor a running Docker daemon is available"
    elif [ "$rc" -ne 0 ]; then
      echo "    FAILED: $action payments" >&2
      status=1
    fi
  fi
fi

if [ "$action" = "lint" ] && [ -z "${APPS_SERVICES:-}" ]; then
  # The scripts that run and test the services are linted with the same flags and version as CI.
  echo "==> lint shell scripts"
  ran=$((ran + 1))
  ./scripts/shellcheck.sh || {
    echo "    FAILED: lint shell scripts" >&2
    status=1
  }
fi

echo
echo "apps $action: $ran run, $skipped skipped"
exit "$status"
