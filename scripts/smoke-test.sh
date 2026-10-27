#!/usr/bin/env bash
# End-to-end smoke test for the sample order-processing application.
#
# Exercises the happy path (order paid), the decline path (order failed), idempotent replays, an
# idempotency-key conflict and the metrics endpoint, all through the gateway of a running stack:
#
#   docker compose -f apps/docker-compose.yml up --build -d
#   ./scripts/smoke-test.sh
#
# With --integration it also checks the data layer wiring of a stack started with the integration override
# (make smoke-test-integration): a notification arrives through RabbitMQ, the order read is consistent with
# the Valkey cache, the outbox drains and nothing was dead-lettered. The default checks do not change.
#
# Exits non-zero on the first failed check. Needs only curl and a POSIX shell toolbox; it works
# with bash 3.2.
#
# Environment:
#   GATEWAY_URL   default http://localhost:8080
#   NOTIFIER_URL  default http://localhost:8083 (checked for a recorded notification)
#   ORDERS_URL    default http://localhost:8081 (--integration only: orders metrics and readiness)
#   WAIT_SECONDS  how long to wait for the stack to become ready (default 90)
set -euo pipefail

usage() {
  echo "Usage: $0 [--integration]   (see the header of this script for the environment variables)"
}

integration=0
case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  --integration) integration=1 ;;
  "") ;;
  *)
    usage >&2
    exit 2
    ;;
esac

GATEWAY_URL="${GATEWAY_URL:-http://localhost:8080}"
NOTIFIER_URL="${NOTIFIER_URL:-http://localhost:8083}"
ORDERS_URL="${ORDERS_URL:-http://localhost:8081}"
WAIT_SECONDS="${WAIT_SECONDS:-90}"

command -v curl > /dev/null 2>&1 || {
  echo "error: curl is required" >&2
  exit 2
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
body_file="$work/body"
failures=0
checks=0

pass() {
  checks=$((checks + 1))
  printf '  ok    %s\n' "$1"
}

fail() {
  checks=$((checks + 1))
  failures=$((failures + 1))
  printf '  FAIL  %s\n' "$1" >&2
}

# request METHOD URL [BODY] [IDEMPOTENCY_KEY]: sets STATUS and prints nothing.
STATUS=""
request() {
  local method="$1" url="$2" data="${3:-}" key="${4:-}"
  local args=(-sS -o "$body_file" -w '%{http_code}' -X "$method" --max-time 15)
  if [ -n "$data" ]; then
    args+=(-H 'Content-Type: application/json' --data "$data")
  fi
  if [ -n "$key" ]; then
    args+=(-H "Idempotency-Key: $key")
  fi
  STATUS="$(curl "${args[@]}" "$url" || echo 000)"
}

body() { cat "$body_file"; }

# json_field NAME prints the first string or number value of "NAME" in the last response body.
json_field() {
  body | sed -n "s/.*\"$1\":\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" | head -n 1
}

expect_status() {
  # expect_status WANT LABEL
  if [ "$STATUS" = "$1" ]; then
    pass "$2 (HTTP $STATUS)"
  else
    fail "$2: expected HTTP $1, got $STATUS: $(body)"
  fi
}

expect_field() {
  # expect_field NAME WANT LABEL
  local got
  got="$(json_field "$1")"
  if [ "$got" = "$2" ]; then
    pass "$3 ($1=$got)"
  else
    fail "$3: expected $1=$2, got '$got': $(body)"
  fi
}

echo "Waiting for the stack at $GATEWAY_URL (up to ${WAIT_SECONDS}s)"
waited=0
until [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$GATEWAY_URL/readyz" || true)" = "200" ]; do
  if [ "$waited" -ge "$WAIT_SECONDS" ]; then
    echo "error: the gateway did not become ready within ${WAIT_SECONDS}s" >&2
    cat >&2 << HINT

This script is a client: it expects a stack that is already running at $GATEWAY_URL.
Start the stack first:

  docker compose -f apps/docker-compose.yml up --build -d

or let make start it, run the test and stop it again:

  make smoke-test-stack

If the stack is up but not ready, check 'docker compose -f apps/docker-compose.yml ps' and the logs.
See docs/runbooks/local-development.md for details and troubleshooting.
HINT
    exit 1
  fi
  sleep 2
  waited=$((waited + 2))
done
echo "Ready after ~${waited}s"

run_id="smoke-$(date +%s)-$$"
order='{"customer_id":"cust-smoke","items":[{"sku":"sku-1","quantity":2,"unit_price_minor":1250}],"currency":"USD"}'

echo
echo "Happy path"
request POST "$GATEWAY_URL/api/orders" "$order" "$run_id-ok"
expect_status 201 "create an order"
expect_field status paid "the order is paid"
expect_field total_minor 2500 "the total is quantity times unit price"
order_id="$(json_field id)"
payment_id="$(json_field payment_id)"
if [ -z "$order_id" ] || [ -z "$payment_id" ]; then
  fail "the order response should carry an id and a payment_id"
fi

request GET "$GATEWAY_URL/api/orders/$order_id"
expect_status 200 "get the order back"
expect_field status paid "the stored order is paid"

request GET "$GATEWAY_URL/api/payments/$payment_id"
expect_status 200 "get the payment through the gateway"
expect_field status approved "the payment is approved"

request GET "$GATEWAY_URL/api/orders?limit=5"
expect_status 200 "list orders"

echo
echo "Idempotency"
request POST "$GATEWAY_URL/api/orders" "$order" "$run_id-ok"
expect_status 200 "replaying the same key returns 200"
expect_field id "$order_id" "the replay returns the same order"

request POST "$GATEWAY_URL/api/orders" '{"customer_id":"cust-smoke","items":[{"sku":"sku-1","quantity":3,"unit_price_minor":1250}],"currency":"USD"}' "$run_id-ok"
expect_status 422 "the same key with another body is rejected"
expect_field code idempotency_key_mismatch "the conflict has its own error code"

request POST "$GATEWAY_URL/api/orders" "$order" ""
expect_status 400 "a missing Idempotency-Key is rejected"

echo
echo "Decline path"
big='{"customer_id":"cust-smoke","items":[{"sku":"sku-big","quantity":2,"unit_price_minor":60000}],"currency":"USD"}'
request POST "$GATEWAY_URL/api/orders" "$big" "$run_id-big"
expect_status 201 "create an order above the payment limit"
expect_field status failed "the order is failed"
expect_field failure_reason amount_exceeds_limit "the decline reason is recorded"

echo
echo "Observability"
request GET "$GATEWAY_URL/metrics"
expect_status 200 "gateway metrics"
if body | grep -q 'http_requests_total'; then pass "gateway exposes http_requests_total"; else fail "gateway metrics are missing http_requests_total"; fi
if body | grep -q 'route="/api/orders/{id}"'; then pass "metrics use route templates"; else fail "metrics should use the route template /api/orders/{id}"; fi

request GET "$GATEWAY_URL/version"
expect_status 200 "gateway version"

request GET "$NOTIFIER_URL/metrics"
if [ "$integration" -eq 1 ]; then
  echo "  skip  notifications arrive over RabbitMQ in this mode, not through POST /notifications (checked below)"
elif [ "$STATUS" = "200" ]; then
  if body | grep -q 'route="/notifications"'; then
    pass "the notifier recorded notifications"
  else
    fail "the notifier received no notifications"
  fi
else
  echo "  skip  notifier metrics not reachable at $NOTIFIER_URL (HTTP $STATUS)"
fi

# metric_value URL SERIES prints the value of one series from a /metrics endpoint (0 when it is missing).
metric_value() {
  curl -s --max-time 5 "$1/metrics" | awk -v s="$2" 'index($0, s " ") == 1 { print $2; found = 1 } END { if (!found) print 0 }' | head -n 1
}

# wait_for LABEL SECONDS COMMAND...: polls until the command succeeds.
wait_for() {
  local label="$1" seconds="$2" waited_for=0
  shift 2
  until "$@" > /dev/null 2>&1; do
    if [ "$waited_for" -ge "$seconds" ]; then
      fail "$label (not true after ${seconds}s)"
      return 1
    fi
    sleep 1
    waited_for=$((waited_for + 1))
  done
  pass "$label"
}

# at_least VALUE MINIMUM: numeric comparison that also works for values like 3.0.
at_least() { awk -v v="$1" -v m="$2" 'BEGIN { exit !(v + 0 >= m + 0) }'; }
is_zero() { awk -v v="$1" 'BEGIN { exit !(v + 0 == 0) }'; }

if [ "$integration" -eq 1 ]; then
  echo
  echo "Integration (PostgreSQL, Valkey, RabbitMQ)"

  request GET "$ORDERS_URL/readyz"
  expect_status 200 "orders is ready with its data layer"
  for dep in postgres valkey rabbitmq; do
    if body | grep -q "\"$dep\":\"ok\""; then pass "orders reports $dep ok"; else fail "orders should report $dep ok: $(body)"; fi
  done

  processed_series='messages_consumed_total{result="processed"}'
  dead_series='messages_consumed_total{result="dead_letter"}'
  processed_before="$(metric_value "$NOTIFIER_URL" "$processed_series")"
  dead_before="$(metric_value "$NOTIFIER_URL" "$dead_series")"
  hits_before="$(metric_value "$ORDERS_URL" 'cache_requests_total{result="hit"}')"

  request POST "$GATEWAY_URL/api/orders" "$order" "$run_id-integration"
  expect_status 201 "create an order against PostgreSQL"
  expect_field status paid "the order is paid"
  created_id="$(json_field id)"
  created_updated="$(json_field updated_at)"

  # Two events (order.created and order.paid) travel outbox -> RabbitMQ -> notifier.
  processed_reached() { at_least "$(metric_value "$NOTIFIER_URL" "$processed_series")" "$1"; }
  wait_for "the notifier consumed the order events from RabbitMQ" 30 processed_reached "$((${processed_before%.*} + 2))" || true

  request GET "$GATEWAY_URL/api/orders/$created_id"
  expect_status 200 "read the order (cache miss, then stored)"
  expect_field updated_at "$created_updated" "the read matches the order that was created"
  request GET "$GATEWAY_URL/api/orders/$created_id"
  expect_status 200 "read the order again (served from the cache)"
  expect_field status paid "the cached order is paid"
  expect_field updated_at "$created_updated" "the cached read is consistent with the stored order"
  hits_after="$(metric_value "$ORDERS_URL" 'cache_requests_total{result="hit"}')"
  if at_least "$hits_after" "$((${hits_before%.*} + 1))"; then pass "the second read was a cache hit"; else fail "expected a cache hit (hits $hits_before -> $hits_after)"; fi

  unpublished="$(metric_value "$ORDERS_URL" 'outbox_unpublished_events')"
  if is_zero "$unpublished"; then pass "the outbox is drained"; else fail "outbox_unpublished_events is $unpublished"; fi
  if is_zero "$(awk -v a="$(metric_value "$NOTIFIER_URL" "$dead_series")" -v b="$dead_before" 'BEGIN { print a - b }')"; then
    pass "nothing was dead-lettered"
  else
    fail "messages were dead-lettered during the smoke test"
  fi
fi

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures of $checks checks FAILED" >&2
  exit 1
fi
echo "All $checks checks passed"
