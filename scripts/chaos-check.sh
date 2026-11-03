#!/usr/bin/env bash
# Offline checks for the chaos framework (chaos/README.md, ADR-0029). Needs no cluster, no network and no vendored chart.
#
#   1. every experiment under chaos/experiments is valid against chaos/schema/experiment.schema.json and the rules across its fields
#      (the rollback undoes the injection, the injection stays inside the blast radius, the numbers add up)
#   2. the lint of the experiments against the platform (scripts/chaos-lint.py): every metric in a probe is one the rules, the confirmed list, a
#      dashboard or chaos/metrics-allowlist.txt know, every alert in expectedObservations and mustNotFire is an alert of the rules (read from
#      the rendered monitors chart), and the blast radius is no wider than the injection; then every probe query is parsed by promtool, from
#      the Prometheus image the stack deploys (run with Docker; skipped with a message when Docker is not running)
#   3. yamllint on chaos/ and on the fixtures of the tests
#   4. the framework tests (scripts/chaos-tests.sh): the schema, the lint, the dry run and a run of every experiment against a fake cluster,
#      the refusals, the abort rules, the rollback on every signal, the blast radius in code, the cleanup and the load helper, against a
#      fake kubectl and a fake Prometheus
#   5. shellcheck on the scripts, through scripts/shellcheck.sh
#
# Tools that are not installed are skipped with a message. Nothing is run on a cluster.
set -euo pipefail

case "${1:-}" in
  -h | --help)
    sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

cd "$(dirname "${BASH_SOURCE[0]}")/.."
have() { command -v "$1" > /dev/null 2>&1; }
status=0

echo "==> the experiments"
./scripts/python-with-yaml.sh > /dev/null || {
  echo "no Python with PyYAML found (installing yamllint provides it); the experiments cannot be checked"
  exit 1
}
count="$(find chaos/experiments -name '*.yaml' | wc -l | tr -d ' ')"
if [ "$count" -eq 0 ]; then
  echo "    FAIL chaos/experiments holds no experiment"
  status=1
else
  ./scripts/chaos-run.sh --validate chaos/experiments/*.yaml || status=1
fi

echo "==> the experiments against the platform"
if ! have helm; then
  echo "helm not installed; skipping the lint of the experiments against the rules"
else
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  helm template observability-monitors platform/observability/monitors --namespace observability > "$work/monitors.yaml" || status=1
  "$(./scripts/python-with-yaml.sh)" scripts/chaos-lint.py --rules "$work/monitors.yaml" \
    --confirmed platform/observability/dashboards/confirmed-upstream.txt --dashboards platform/observability/dashboards/files \
    --allow chaos/metrics-allowlist.txt --emit-promql "$work/probes.yaml" chaos/experiments/*.yaml || status=1
  # The Prometheus the stack deploys (the version rendered by platform/observability/kube-prometheus-stack, as scripts/observability-check.sh
  # reads it); move this with the stack. promtool parses each probe query as the expression of a recording rule.
  prom_image="quay.io/prometheus/prometheus:v3.15.1-distroless"
  if ! have docker || ! docker info > /dev/null 2>&1; then
    echo "    Docker is not running: the probe queries are not parsed by promtool (CI does it)"
  elif docker run --rm --entrypoint /bin/promtool -v "$work:/w:ro" -w /w "$prom_image" check rules --lint-fatal probes.yaml > "$work/promtool.out" 2>&1; then
    echo "    promtool parses every probe query: $(sed -n 's/^ *SUCCESS: *//p' "$work/promtool.out" | head -1)"
    # The check must be able to fail.
    sed 's/sum(/sum(( /' "$work/probes.yaml" > "$work/broken.yaml"
    if docker run --rm --entrypoint /bin/promtool -v "$work:/w:ro" -w /w "$prom_image" check rules broken.yaml > /dev/null 2>&1; then
      echo "    FAIL promtool did not notice a probe query that does not parse"
      status=1
    else
      echo "    promtool notices a probe query that does not parse"
    fi
  else
    echo "    FAIL promtool does not accept a probe query:"
    sed 's/^/        /' "$work/promtool.out"
    status=1
  fi
fi

echo "==> yamllint"
if have yamllint; then
  yamllint --strict chaos scripts/tests/fixtures/chaos || status=1
else
  echo "yamllint not installed; skipping yaml lint"
fi

echo "==> the framework tests"
./scripts/chaos-tests.sh || status=1

echo "==> shellcheck"
./scripts/shellcheck.sh || status=1

exit "$status"
