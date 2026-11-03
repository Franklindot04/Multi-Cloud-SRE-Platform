#!/usr/bin/env bash
# A small steady request load against the gateway, for the chaos experiments (chaos/README.md). Their steady-state probes are about requests,
# and an idle cluster has none. The load comes from one throwaway pod in the shop namespace and stops by itself.
#
#   scripts/chaos-load.sh start [--duration SECONDS] [--interval SECONDS] [--order-every N] [--cluster-pattern RE]
#   scripts/chaos-load.sh status
#   scripts/chaos-load.sh stop
#
#   start    makes the pod chaos-load and a NetworkPolicy that lets only that pod reach the gateway. The pod sends GET /api/orders every
#            INTERVAL seconds (default 0.5, from 0.2 to 5) and, every Nth request (default 4), POST /api/orders to create an order with a
#            new Idempotency-Key. That is about 2 requests a second and half an order a second: modest, and it creates real orders in
#            PostgreSQL, so the outbox and the notifier have work. It ends after DURATION seconds (default 1800, from 60 to 3600) and
#            the pod has a deadline of its own, so it cannot run on.
#   stop     deletes the pod and the policy.
#   status   says whether the pod is there and what it is doing.
#
# Why it needs a policy: the gateway's network policy lets in only Prometheus (deploy/helm/service/templates/networkpolicy.yaml), so a pod in
# shop would be refused. The pod is not selected by any policy of its own (the denies select the pods of one release), so its egress is
# open; the script reads the policies of the namespace and refuses to start if one would select the pod for egress.
#
# Everything it makes carries the label chaos.platform.example/managed-by=chaos-load, so `scripts/chaos-run.sh --cleanup` finds a leftover and
# removes it. A chaos run does not mind it: the run looks for its own label. The pod is the busybox of docs/runbooks/network-policies.md,
# pinned by digest (the only image of this kind pinned in the repository; deploy/helm/values/images.yaml holds the images of the services).
#
# Refuses to run unless the kubectl context names a cluster that matches --cluster-pattern (default: ends in -dev); only the name is printed.
# Needs no AWS credentials.
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

NAMESPACE="shop"
POD="chaos-load"
POLICY="chaos-load-to-gateway"
LABEL_KEY="chaos.platform.example/managed-by"
LABEL_VALUE="chaos-load"
IMAGE='docker.io/library/busybox:1.37@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec'
GATEWAY="http://gateway:8080/api/orders"

DURATION=1800
INTERVAL=0.5
EVERY=4
PATTERN='^[a-z0-9-]+-dev$'

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

command_name="${1:-}"
case "$command_name" in
  start | stop | status) shift ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --duration)
      DURATION="${2:?--duration needs a number of seconds}"
      shift 2
      ;;
    --interval)
      INTERVAL="${2:?--interval needs a number of seconds}"
      shift 2
      ;;
    --order-every)
      EVERY="${2:?--order-every needs a number}"
      shift 2
      ;;
    --cluster-pattern)
      PATTERN="${2:?--cluster-pattern needs a regular expression}"
      shift 2
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$DURATION" in '' | *[!0-9]*) die "--duration must be a whole number of seconds, not '$DURATION'" ;; esac
[ "$DURATION" -ge 60 ] && [ "$DURATION" -le 3600 ] || die "--duration must be from 60 to 3600 seconds, not $DURATION"
case "$EVERY" in '' | *[!0-9]*) die "--order-every must be a whole number, not '$EVERY'" ;; esac
[ "$EVERY" -ge 1 ] && [ "$EVERY" -le 100 ] || die "--order-every must be from 1 to 100, not $EVERY"
printf '%s' "$INTERVAL" | grep -Eq '^[0-9]+(\.[0-9]+)?$' || die "--interval must be a number of seconds, not '$INTERVAL'"
awk -v i="$INTERVAL" 'BEGIN { exit !(i >= 0.2 && i <= 5) }' || die "--interval must be from 0.2 to 5 seconds, not $INTERVAL"

context="$(kubectl config current-context 2> /dev/null)" || die "kubectl has no current context"
cluster="${context##*/}"
printf '%s' "$cluster" | grep -Eq "$PATTERN" || die "the cluster '$cluster' does not match the pattern $PATTERN: nothing was touched"
k() { kubectl --context "$context" "$@"; }

case "$command_name" in
  status)
    if info="$(k -n "$NAMESPACE" get pod "$POD" -o json 2> /dev/null)"; then
      phase="$(printf '%s' "$info" | sed -n 's/.*"phase": *"\([A-Za-z]*\)".*/\1/p' | head -1)"
      printf 'The load pod %s/%s is there on the cluster %s (phase %s).\n' "$NAMESPACE" "$POD" "$cluster" "${phase:-unknown}"
    else
      printf 'No load pod on the cluster %s.\n' "$cluster"
      exit 1
    fi
    ;;
  stop)
    k -n "$NAMESPACE" delete pod -l "$LABEL_KEY=$LABEL_VALUE" --wait=false
    k -n "$NAMESPACE" delete networkpolicy -l "$LABEL_KEY=$LABEL_VALUE"
    printf 'The load is stopped on the cluster %s.\n' "$cluster"
    ;;
  start)
    if k -n "$NAMESPACE" get pod "$POD" -o json > /dev/null 2>&1; then
      die "the load pod $NAMESPACE/$POD is already there on the cluster $cluster; stop it first"
    fi
    # The pod is selected by no policy for egress, or it could not reach the gateway.
    if ! k -n "$NAMESPACE" get networkpolicy -o json | python3 -c '
import json
import sys

labels = {"app.kubernetes.io/name": "chaos-load", "chaos.platform.example/managed-by": "chaos-load"}
for np in json.load(sys.stdin)["items"]:
    spec = np["spec"]
    sel = spec.get("podSelector") or {}
    match = sel.get("matchLabels") or {}
    exprs = sel.get("matchExpressions") or []
    if "Egress" in (spec.get("policyTypes") or []) and not exprs and all(labels.get(k) == v for k, v in match.items()):
        print("the network policy {} selects the load pod for egress, so it could not reach the gateway".format(np["metadata"]["name"]), file=sys.stderr)
        sys.exit(1)
'; then
      die "the load pod would be blocked (see above); nothing was started"
    fi
    esc() { sed 's/\\/\\\\/g; s/"/\\"/g'; }
    order='{"customer_id":"cust-chaos","items":[{"sku":"sku-1","quantity":1,"unit_price_minor":1250}],"currency":"USD"}'
    # shellcheck disable=SC2016 # the loop runs in the pod, so nothing in it is meant to expand here
    loop='end=$(( $(date +%s) + __DURATION__ )); i=0; while [ "$(date +%s)" -lt "$end" ]; do i=$((i+1)); if [ $((i % __EVERY__)) -eq 0 ]; then wget -q -O /dev/null -T 5 --header "Content-Type: application/json" --header "Idempotency-Key: chaos-load-$(date +%s)-$i-$RANDOM" --post-data '"'"'__ORDER__'"'"' __URL__; else wget -q -O /dev/null -T 5 __URL__; fi; sleep __INTERVAL__; done'
    loop="${loop//__DURATION__/$DURATION}"
    loop="${loop//__EVERY__/$EVERY}"
    loop="${loop//__INTERVAL__/$INTERVAL}"
    loop="${loop//__URL__/$GATEWAY}"
    loop="${loop//__ORDER__/$order}"
    labels="\"app.kubernetes.io/name\":\"chaos-load\",\"$LABEL_KEY\":\"$LABEL_VALUE\",\"chaos.platform.example/experiment\":\"chaos-load\""
    policy="{\"apiVersion\":\"networking.k8s.io/v1\",\"kind\":\"NetworkPolicy\",\"metadata\":{\"name\":\"$POLICY\",\"namespace\":\"$NAMESPACE\",\"labels\":{$labels}},\"spec\":{\"podSelector\":{\"matchLabels\":{\"app.kubernetes.io/name\":\"gateway\",\"app.kubernetes.io/instance\":\"gateway\"}},\"policyTypes\":[\"Ingress\"],\"ingress\":[{\"from\":[{\"podSelector\":{\"matchLabels\":{\"app.kubernetes.io/name\":\"chaos-load\",\"$LABEL_KEY\":\"$LABEL_VALUE\"}}}],\"ports\":[{\"protocol\":\"TCP\",\"port\":8080}]}]}}"
    pod="{\"apiVersion\":\"v1\",\"kind\":\"Pod\",\"metadata\":{\"name\":\"$POD\",\"namespace\":\"$NAMESPACE\",\"labels\":{$labels}},\"spec\":{\"restartPolicy\":\"Never\",\"automountServiceAccountToken\":false,\"activeDeadlineSeconds\":$((DURATION + 60)),\"securityContext\":{\"runAsNonRoot\":true,\"runAsUser\":65534,\"runAsGroup\":65534,\"seccompProfile\":{\"type\":\"RuntimeDefault\"}},\"containers\":[{\"name\":\"load\",\"image\":\"$IMAGE\",\"command\":[\"sh\",\"-c\",\"$(printf '%s' "$loop" | esc)\"],\"resources\":{\"requests\":{\"cpu\":\"10m\",\"memory\":\"16Mi\"},\"limits\":{\"cpu\":\"100m\",\"memory\":\"32Mi\"}},\"securityContext\":{\"allowPrivilegeEscalation\":false,\"readOnlyRootFilesystem\":true,\"capabilities\":{\"drop\":[\"ALL\"]}}}]}}"
    # The policy first: the pod is refused at the gateway until it exists, but never the other way round.
    printf '%s\n' "$policy" | k apply -f - > /dev/null
    printf '%s\n' "$pod" | k apply -f - > /dev/null
    printf 'The load is running on the cluster %s: %s/%s, about %s requests a second, an order every %s requests, for %s seconds.\n' \
      "$cluster" "$NAMESPACE" "$POD" "$(awk -v i="$INTERVAL" 'BEGIN { printf "%.1f", 1 / i }')" "$EVERY" "$DURATION"
    printf 'Stop it with: scripts/chaos-load.sh stop (or scripts/chaos-run.sh --cleanup --execute).\n'
    ;;
esac
