#!/usr/bin/env bash
# Wait for the local data layer (apps/docker-compose.data.yml) to be healthy, then check each component:
#   PostgreSQL  each service role reaches its own database and is refused by the other one
#   Valkey      unauthenticated access is refused; an authenticated SET and GET round-trips
#   RabbitMQ    a message published to a queue through the management API is read back
# Exits non-zero on the first failed component. Needs Docker and curl.
#
# Environment:
#   WAIT_SECONDS  how long to wait for the healthchecks (default 120)
set -euo pipefail

case "${1:-}" in
  -h | --help)
    echo "Usage: $0   (start the stack first with: make data-up)"
    exit 0
    ;;
esac

cd "$(dirname "${BASH_SOURCE[0]}")/.."
compose=(docker compose -f apps/docker-compose.data.yml)
wait_seconds="${WAIT_SECONDS:-120}"

if [ ! -f apps/.env ]; then
  echo "error: apps/.env is missing; copy apps/.env.example to apps/.env first" >&2
  exit 2
fi
# shellcheck source=/dev/null
. apps/.env

failures=0
pass() { printf '  ok    %s\n' "$1"; }
fail() {
  printf '  FAIL  %s\n' "$1" >&2
  failures=$((failures + 1))
}

echo "Waiting for healthchecks (up to ${wait_seconds}s)"
for svc in postgres valkey rabbitmq; do
  waited=0
  while true; do
    id="$("${compose[@]}" ps -q "$svc" 2> /dev/null || true)"
    health=""
    if [ -n "$id" ]; then
      health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id" 2> /dev/null || true)"
    fi
    if [ "$health" = "healthy" ]; then
      pass "$svc is healthy"
      break
    fi
    if [ "$waited" -ge "$wait_seconds" ]; then
      fail "$svc did not become healthy (status: ${health:-not running}); is the stack up? make data-up"
      echo "Failed: $failures component(s) not ready" >&2
      exit 1
    fi
    sleep 2
    waited=$((waited + 2))
  done
done

echo
echo "PostgreSQL"
for svc in orders payments; do
  case "$svc" in
    orders)
      pw="$ORDERS_DB_PASSWORD"
      other=payments
      ;;
    payments)
      pw="$PAYMENTS_DB_PASSWORD"
      other=orders
      ;;
  esac
  got="$("${compose[@]}" exec -T -e PGPASSWORD="$pw" postgres psql -h 127.0.0.1 -U "$svc" -d "$svc" -tAc 'select 1' 2> /dev/null || true)"
  if [ "$got" = "1" ]; then pass "role $svc runs a query in database $svc"; else fail "role $svc could not query database $svc"; fi
  if "${compose[@]}" exec -T -e PGPASSWORD="$pw" postgres psql -h 127.0.0.1 -U "$svc" -d "$other" -tAc 'select 1' > /dev/null 2>&1; then
    fail "role $svc can connect to database $other (it must not)"
  else
    pass "role $svc is refused by database $other"
  fi
done

echo
echo "Valkey"
if "${compose[@]}" exec -T valkey valkey-cli ping 2> /dev/null | grep -q PONG; then
  fail "Valkey answers without a password"
else
  pass "Valkey refuses unauthenticated commands"
fi
vk() { "${compose[@]}" exec -T -e REDISCLI_AUTH="$VALKEY_PASSWORD" valkey valkey-cli "$@"; }
if [ "$(vk set smoke-check hello EX 60 2> /dev/null | tr -d '\r')" = "OK" ] && [ "$(vk get smoke-check 2> /dev/null | tr -d '\r')" = "hello" ]; then
  pass "authenticated SET and GET round-trip"
else
  fail "authenticated SET and GET did not round-trip"
fi

echo
echo "RabbitMQ"
api=http://127.0.0.1:15672/api
auth="$RABBITMQ_DEFAULT_USER:$RABBITMQ_DEFAULT_PASS"
rq() { curl -sS --max-time 10 -u "$auth" -H 'content-type: application/json' "$@"; }
rq -o /dev/null -X PUT -d '{"durable":true,"auto_delete":false}' "$api/queues/%2F/smoke-check" || true
rq -o /dev/null -X POST -d '{"properties":{},"routing_key":"smoke-check","payload":"hello-queue","payload_encoding":"string"}' "$api/exchanges/%2F/amq.default/publish" || true
got="$(rq -X POST -d '{"count":1,"ackmode":"ack_requeue_false","encoding":"auto"}' "$api/queues/%2F/smoke-check/get" 2> /dev/null || true)"
if printf '%s' "$got" | grep -q '"payload":"hello-queue"'; then
  pass "a published message was read back from the queue"
else
  fail "publish and consume did not round-trip: $got"
fi
rq -o /dev/null -X DELETE "$api/queues/%2F/smoke-check" || true

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) FAILED" >&2
  exit 1
fi
echo "All data layer checks passed"
