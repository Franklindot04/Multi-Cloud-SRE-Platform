#!/usr/bin/env bash
# Run shellcheck on the repository's shell scripts exactly as CI does.
#
# One place defines the flags and the version, and every local and CI shell lint goes through it
# (make argocd-check, make apps-lint and the argocd workflow), so a finding that fails in CI also
# fails locally:
#   - severity: -S style, the strictest level, so info and style findings fail the run
#   - version:  CI installs shellcheck 0.11.0 (see .github/workflows/argocd.yml); a different local
#               version prints a warning because newer releases report fewer findings than older ones
#
# Usage: scripts/shellcheck.sh [file...]   (default: scripts/*.sh apps/data/*.sh)
set -euo pipefail

pinned="${SHELLCHECK_VERSION:-0.11.0}"

case "${1:-}" in
  -h | --help)
    echo "Usage: $0 [file...]   (default: scripts/*.sh apps/data/*.sh)"
    exit 0
    ;;
esac

if ! command -v shellcheck > /dev/null 2>&1; then
  echo "shellcheck not installed; skipping shell lint"
  exit 0
fi

actual="$(shellcheck --version | sed -n 's/^version: //p')"
if [ "$actual" != "$pinned" ]; then
  echo "warning: shellcheck $actual is installed but CI uses $pinned; results may differ" >&2
fi

cd "$(dirname "${BASH_SOURCE[0]}")/.."
if [ "$#" -eq 0 ]; then
  set -- scripts/*.sh apps/data/*.sh
fi
exec shellcheck -S style "$@"
