#!/usr/bin/env bash
# Run `terraform test` in every module under infra/terraform/modules that has a tests/ directory.
# Tests use mocked providers, so no cloud credentials are needed.
set -euo pipefail

usage() {
  echo "Usage: $0 [modules-root]   (default: infra/terraform/modules)"
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

root="${1:-infra/terraform/modules}"

if ! command -v terraform > /dev/null 2>&1; then
  echo "terraform not installed; skipping tests"
  exit 0
fi

dirs="$(find "$root" -type d -name tests -not -path '*/.terraform/*' -exec dirname {} \; | sort -u)"

if [ -z "$dirs" ]; then
  echo "no module tests found; nothing to run"
  exit 0
fi

while IFS= read -r dir; do
  echo "==> testing $dir"
  terraform -chdir="$dir" init -backend=false -input=false > /dev/null
  terraform -chdir="$dir" test
done <<< "$dirs"
