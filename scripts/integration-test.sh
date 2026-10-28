#!/usr/bin/env bash
# Integration tests for the sample services against the real data layer (PostgreSQL, Valkey, RabbitMQ).
#
#   scripts/integration-test.sh           start the stack, run the integration suites, the smoke test and the
#                                         chaos checks, then tear everything down
#   scripts/integration-test.sh --smoke   start the stack, run only 'smoke-test.sh --integration', tear down
#
# The stack is the normal compose file plus the data layer plus apps/docker-compose.integration.yml, in its
# own compose project (sre-sample-integration), so it never touches the volumes of 'make data-up'. Credentials
# come only from apps/.env (not tracked): cp apps/.env.example apps/.env first. The stack and its volumes are
# always removed on exit, and the container logs are printed when anything failed.
#
# The chaos checks stop and start containers of that project:
#   RabbitMQ down  -> orders are still created, the outbox fills, and drains after RabbitMQ returns
#   Valkey down    -> orders are still created and read, the cache reports errors, readiness only degrades
#   PostgreSQL down -> orders and payments are not ready, and recover when it returns
#
# Environment:
#   INTEGRATION_LOG_DIR  when set and anything failed, the container logs are also written to
#                        $INTEGRATION_LOG_DIR/compose.log (CI uploads that directory as an artifact)
#   READY_SECONDS  how long to wait for the stack (default 240)
set -euo pipefail

usage() {
  echo "Usage: $0 [--smoke]   (see the header of this script)"
}

smoke_only=0
case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  --smoke) smoke_only=1 ;;
  "") ;;
  *)
    usage >&2
    exit 2
    ;;
esac

cd "$(dirname "${BASH_SOURCE[0]}")/.."
project="sre-sample-integration"
env_file="apps/.env"
ready_seconds="${READY_SECONDS:-240}"

if ! command -v docker > /dev/null 2>&1 || ! docker info > /dev/null 2>&1; then
  echo "error: Docker is required and must be running" >&2
  exit 2
fi
command -v curl > /dev/null 2>&1 || {
  echo "error: curl is required" >&2
  exit 2
}
[ -f "$env_file" ] || {
  echo "error: $env_file is missing: cp apps/.env.example $env_file and change the values" >&2
  exit 2
}

# The credentials are exported for the test suites; they are never printed.
set -a
# shellcheck source=/dev/null
. "$env_file"
set +a
export INTEGRATION_NETWORK="${project}_default"

compose() {
  docker compose -p "$project" --env-file "$env_file" \
    -f apps/docker-compose.yml -f apps/docker-compose.data.yml -f apps/docker-compose.integration.yml "$@"
}

status=0
checks=0
failures=0

on_exit() {
  local rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ] || [ "$failures" -gt 0 ]; then
    echo "==> failed; container logs follow" >&2
    compose logs --no-color --tail 200 >&2 || true
    if [ -n "${INTEGRATION_LOG_DIR:-}" ]; then
      mkdir -p "$INTEGRATION_LOG_DIR"
      compose logs --no-color > "$INTEGRATION_LOG_DIR/compose.log" 2>&1 || true
      compose ps -a > "$INTEGRATION_LOG_DIR/compose-ps.txt" 2>&1 || true
    fi
    [ "$rc" -ne 0 ] || rc=1
  fi
  echo "==> removing the stack and its volumes"
  compose down -v --remove-orphans > /dev/null 2>&1 || true
  exit "$rc"
}
trap on_exit EXIT

pass() {
  checks=$((checks + 1))
  printf '  ok    %s\n' "$1"
}

fail() {
  checks=$((checks + 1))
  failures=$((failures + 1))
  printf '  FAIL  %s\n' "$1" >&2
}

# check LABEL COMMAND...: records the outcome instead of stopping the run.
check() {
  local label="$1"
  shift
  if "$@" > /dev/null 2>&1; then pass "$label"; else fail "$label"; fi
}

# wait_until LABEL SECONDS COMMAND...: polls until the command succeeds.
wait_until() {
  local label="$1" seconds="$2" waited=0
  shift 2
  until "$@" > /dev/null 2>&1; do
    if [ "$waited" -ge "$seconds" ]; then
      fail "$label (not true after ${seconds}s)"
      return 1
    fi
    sleep 2
    waited=$((waited + 2))
  done
  pass "$label"
}

http_status() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" || true; }
is_status() { [ "$(http_status "${@:2}")" = "$1" ]; }
metric() { curl -s --max-time 5 "$1/metrics" | awk -v s="$2" 'index($0, s " ") == 1 { print $2; found = 1 } END { if (!found) print 0 }' | head -n 1; }
int() { printf '%s' "${1%.*}"; }

gateway="http://localhost:8080"
orders="http://localhost:8081"
payments="http://localhost:8082"
notifier="http://localhost:8083"
order_body='{"customer_id":"cust-chaos","items":[{"sku":"sku-1","quantity":1,"unit_price_minor":1500}],"currency":"USD"}'
run_id="chaos-$(date +%s)-$$"

# create_order prints the HTTP status of a new order. It runs in a subshell, so the key must be unique on its own.
create_order() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X POST "$gateway/api/orders" \
    -H 'Content-Type: application/json' -H "Idempotency-Key: $run_id-$RANDOM-$RANDOM" --data "$order_body" || true
}

expect_created() {
  local got
  got="$(create_order)"
  if [ "$got" = "201" ]; then pass "$1"; else fail "$1 (HTTP $got)"; fi
}

# order_creatable KEY: succeeds when creating (or replaying) an order with that key works.
order_creatable() {
  local got
  got="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X POST "$gateway/api/orders" \
    -H 'Content-Type: application/json' -H "Idempotency-Key: $1" --data "$order_body" || true)"
  [ "$got" = "201" ] || [ "$got" = "200" ]
}

stack_ready() {
  is_status 200 "$gateway/readyz" && is_status 200 "$orders/readyz" && is_status 200 "$payments/readyz" && is_status 200 "$notifier/readyz"
}

echo "==> starting the integration stack (project $project)"
compose up --build -d
wait_until "the stack is ready" "$ready_seconds" stack_ready || {
  echo "error: the stack did not become ready" >&2
  exit 1
}

if [ "$smoke_only" -eq 1 ]; then
  echo "==> smoke test (--integration)"
  ./scripts/smoke-test.sh --integration || exit 1
  exit 0
fi

echo "==> integration suites"
./scripts/apps.sh integration || status=1

echo "==> smoke test (--integration)"
./scripts/smoke-test.sh --integration || status=1

echo "==> chaos: RabbitMQ stopped"
processed='messages_consumed_total{result="processed"}'
processed_before="$(int "$(metric "$notifier" "$processed")")"
compose stop rabbitmq > /dev/null
for _ in 1 2 3; do
  expect_created "an order is created while RabbitMQ is down"
done
unpublished_at_least_3() { [ "$(int "$(metric "$orders" outbox_unpublished_events)")" -ge 6 ]; }
wait_until "the outbox holds the unpublished events (3 orders, 2 events each)" 60 unpublished_at_least_3 || true
orders_degraded() { curl -s --max-time 5 "$orders/readyz" | grep -q 'degraded' && is_status 200 "$orders/readyz"; }
wait_until "orders stays ready and reports rabbitmq as degraded" 30 orders_degraded || true
check "the notifier is not ready without RabbitMQ" is_status 503 "$notifier/readyz"
compose start rabbitmq > /dev/null
outbox_empty() { [ "$(int "$(metric "$orders" outbox_unpublished_events)")" -eq 0 ]; }
wait_until "the outbox drains after RabbitMQ returns" 180 outbox_empty || true
consumed_all() { [ "$(int "$(metric "$notifier" "$processed")")" -ge "$((processed_before + 6))" ]; }
wait_until "the notifier consumed all six events" 120 consumed_all || true
check "the notifier is ready again" is_status 200 "$notifier/readyz"
oldest_zero() { [ "$(int "$(metric "$orders" outbox_oldest_unpublished_age_seconds)")" -eq 0 ]; }
wait_until "the oldest unpublished age is back to zero" 30 oldest_zero || true

echo "==> chaos: Valkey stopped"
request_body="$(curl -s --max-time 20 -X POST "$gateway/api/orders" -H 'Content-Type: application/json' -H "Idempotency-Key: $run_id-valkey" --data "$order_body")"
order_id="$(printf '%s' "$request_body" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
errors_before="$(int "$(metric "$orders" 'cache_requests_total{result="error"}')")"
compose stop valkey > /dev/null
check "a cached order is still readable while Valkey is down" is_status 200 "$gateway/api/orders/$order_id"
expect_created "an order is created while Valkey is down"
cache_errors() { [ "$(int "$(metric "$orders" 'cache_requests_total{result="error"}')")" -gt "$errors_before" ]; }
wait_until "cache errors are counted" 20 cache_errors || true
valkey_degraded() { curl -s --max-time 5 "$orders/readyz" | grep -q '"valkey":"degraded' && is_status 200 "$orders/readyz"; }
wait_until "orders stays ready and reports valkey as degraded" 30 valkey_degraded || true
compose start valkey > /dev/null
valkey_ok() { curl -s --max-time 5 "$orders/readyz" | grep -q '"valkey":"ok"'; }
wait_until "orders sees Valkey again" 90 valkey_ok || true
check "reads work after Valkey returns" is_status 200 "$gateway/api/orders/$order_id"

echo "==> chaos: PostgreSQL stopped"
compose stop postgres > /dev/null
wait_until "orders is not ready without PostgreSQL" 30 is_status 503 "$orders/readyz" || true
wait_until "payments is not ready without PostgreSQL" 30 is_status 503 "$payments/readyz" || true
check "orders liveness is unaffected" is_status 200 "$orders/healthz"
check "payments liveness is unaffected" is_status 200 "$payments/healthz"
compose start postgres > /dev/null
wait_until "orders is ready again" 120 is_status 200 "$orders/readyz" || true
wait_until "payments is ready again" 120 is_status 200 "$payments/readyz" || true
wait_until "an order can be created again" 60 order_creatable "$run_id-after" || true

echo
if [ "$failures" -gt 0 ] || [ "$status" -ne 0 ]; then
  echo "$failures of $checks chaos checks FAILED (suite status $status)" >&2
  exit 1
fi
echo "All integration suites and $checks chaos checks passed"
