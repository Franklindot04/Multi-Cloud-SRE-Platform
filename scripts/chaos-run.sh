#!/usr/bin/env bash
# Runs a chaos experiment: a thin wrapper around scripts/chaos-run.py (the logic is in Python because the experiments are YAML with a
# schema, the probes are HTTP queries to Prometheus and the rollback has to survive signals; shell would do none of that well).
#
#   scripts/chaos-run.sh chaos/experiments/NAME.yaml             dry run: validate and print the plan, touch nothing
#   scripts/chaos-run.sh chaos/experiments/NAME.yaml --execute   run it for real, after typing the cluster name (there is no --yes)
#   scripts/chaos-run.sh --validate chaos/experiments/*.yaml     check the files against the schema
#   scripts/chaos-run.sh --cleanup [--execute]                   find (and revert) what an earlier run left behind
#
# Needs kubectl with a context for a dev cluster and Python with PyYAML. Needs no AWS credentials and never calls AWS. See chaos/README.md.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

case "${1:-}" in
  -h | --help)
    sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

py="$(./scripts/python-with-yaml.sh)" || {
  echo "error: no Python with PyYAML found (installing yamllint provides it)" >&2
  exit 1
}
exec "$py" scripts/chaos-run.py "$@"
