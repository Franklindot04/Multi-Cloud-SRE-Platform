#!/usr/bin/env bash
# Run `terraform init -backend=false` and `terraform validate` in every
# directory under infra/terraform that contains Terraform files.
set -euo pipefail

usage() {
  echo "Usage: $0 [terraform-root]   (default: infra/terraform)"
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

root="${1:-infra/terraform}"

if ! command -v terraform > /dev/null 2>&1; then
  echo "terraform not installed; skipping validate"
  exit 0
fi

dirs="$(find "$root" -name '*.tf' -not -path '*/.terraform/*' -exec dirname {} \; | sort -u)"

if [ -z "$dirs" ]; then
  echo "no Terraform configuration found; nothing to validate"
  exit 0
fi

# Use a throwaway data directory so validation never reads or changes a developer's
# own .terraform state (for example a backend that was initialised against real state).
data_dir="$(mktemp -d)"
trap 'rm -rf "$data_dir"' EXIT

# Share downloaded providers between directories to avoid repeated downloads.
if [ -z "${TF_PLUGIN_CACHE_DIR:-}" ]; then
  export TF_PLUGIN_CACHE_DIR="${TMPDIR:-/tmp}/terraform-plugin-cache"
fi
mkdir -p "$TF_PLUGIN_CACHE_DIR"

while IFS= read -r dir; do
  echo "==> validating $dir"
  TF_DATA_DIR="$data_dir/$(echo "$dir" | tr '/' '_')"
  export TF_DATA_DIR
  terraform -chdir="$dir" init -backend=false -input=false > /dev/null
  terraform -chdir="$dir" validate
done <<< "$dirs"
