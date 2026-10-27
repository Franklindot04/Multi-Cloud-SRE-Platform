#!/usr/bin/env bash
# End-to-end smoke test for the sample order-processing application.
#
# Exercises the happy path (order paid), the decline path (order failed), idempotent replays, an
# idempotency-key conflict and the metrics endpoint, all through the gateway of a running stack:
#
#   docker compose -f apps/docker-compose.yml up --build -d
#   ./scripts/smoke-test.sh
#
# Exits non-zero on the first failed check. Needs only curl and a POSIX shell toolbox; it works
# with bash 3.2.
#
# Environment:
#   GATEWAY_URL   default http://localhost:8080
#   NOTIFIER_URL  default http://localhost:8083 (checked for a recorded notification)
#   WAIT_SECONDS  how long to wait for the stack to become ready (default 90)
set -euo pipefail

usage() {
  echo "Usage: $0   (see the header of this script for the environment variables)"
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

GATEWAY_URL="${GATEWAY_URL:-http://localhost:8080}"
NOTIFIER_URL="${NOTIFIER_URL:-http://localhost:8083}"
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
if [ "$STATUS" = "200" ]; then
  if body | grep -q 'route="/notifications"'; then
    pass "the notifier recorded notifications"
  else
    fail "the notifier received no notifications"
  fi
else
  echo "  skip  notifier metrics not reachable at $NOTIFIER_URL (HTTP $STATUS)"
fi

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures of $checks checks FAILED" >&2
  exit 1
fi
echo "All $checks checks passed"
