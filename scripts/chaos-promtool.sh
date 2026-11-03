#!/usr/bin/env bash
# Parses the probe queries written by scripts/chaos-lint.py --emit-promql with promtool, from the Prometheus image the stack deploys, and
# checks that the check can fail. Run by scripts/chaos-check.sh.
#
# The directory handed to the container is a subdirectory made here, readable by everyone, the way scripts/observability-check.sh mounts
# its rule files: the image runs as an unprivileged user, and on a Linux runner it cannot read the private directory mktemp -d makes
# (Docker Desktop does not enforce that, so it passes on a Mac). Nothing private goes into it.
#
#   scripts/chaos-promtool.sh PROBES.yaml
# Exits 0 when promtool parses the queries and notices a broken one, 1 when not, 0 with a message when Docker is not running.
set -euo pipefail

case "${1:-}" in
  -h | --help | "")
    sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    [ -n "${1:-}" ] && exit 0
    exit 2
    ;;
esac

probes="$1"
# The Prometheus the stack deploys (the version rendered by platform/observability/kube-prometheus-stack, as scripts/observability-check.sh
# reads it); move this with the stack. promtool parses each probe query as the expression of a recording rule.
prom_image="quay.io/prometheus/prometheus:v3.15.1-distroless"

if ! command -v docker > /dev/null 2>&1 || ! docker info > /dev/null 2>&1; then
  echo "    Docker is not running: the probe queries are not parsed by promtool (CI does it)"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/probes"
cp "$probes" "$work/probes/probes.yaml"
# The first line of a broken copy: a probe query that does not parse.
sed 's/sum(/sum(( /' "$probes" > "$work/probes/broken.yaml"
chmod 755 "$work/probes"
chmod 644 "$work/probes"/*.yaml
promtool="docker run --rm --entrypoint /bin/promtool -v $work/probes:/w:ro -w /w $prom_image"

# shellcheck disable=SC2086 # the command is a fixed word list
if $promtool check rules --lint-fatal probes.yaml > "$work/promtool.out" 2>&1; then
  echo "    promtool parses every probe query: $(sed -n 's/^ *SUCCESS: *//p' "$work/promtool.out" | head -1)"
  # shellcheck disable=SC2086
  if $promtool check rules broken.yaml > /dev/null 2>&1; then
    echo "    FAIL promtool did not notice a probe query that does not parse"
    exit 1
  fi
  echo "    promtool notices a probe query that does not parse"
else
  echo "    FAIL promtool does not accept a probe query:"
  sed 's/^/        /' "$work/promtool.out"
  exit 1
fi
