#!/usr/bin/env bash
# Tests for the helper scripts used by CI: scripts/update-image-values.sh and scripts/changed-services.sh.
# Plain bash (3.2 compatible), no framework, no network. Fixtures are in scripts/tests/fixtures.
#
#   scripts/test-scripts.sh
set -euo pipefail

case "${1:-}" in
  -h | --help)
    echo "Usage: $0"
    exit 0
    ;;
esac

cd "$(dirname "${BASH_SOURCE[0]}")/.."
fixtures="scripts/tests/fixtures"
update="./scripts/update-image-values.sh"
changed="./scripts/changed-services.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

passed=0
failed=0

ok() {
  passed=$((passed + 1))
  printf '  ok    %s\n' "$1"
}

bad() {
  failed=$((failed + 1))
  printf '  FAIL  %s\n' "$1" >&2
}

# check LABEL COMMAND...: the command must succeed.
check() {
  local label="$1"
  shift
  if "$@" > /dev/null 2>&1; then ok "$label"; else bad "$label"; fi
}

# rejects LABEL FILE ARGS...: the update script must exit 2 and leave FILE as it was.
rejects() {
  local label="$1" file="$2" rc=0 before
  shift 2
  before="$(cksum < "$file")"
  "$update" --file "$file" "$@" > "$work/out" 2>&1 || rc=$?
  if [ "$rc" -eq 2 ] && [ "$before" = "$(cksum < "$file")" ]; then ok "$label"; else bad "$label (exit $rc)"; fi
}

fresh() { cp "$fixtures/images.yaml" "$work/images.yaml"; }

d1="sha256:$(printf 'a%.0s' $(seq 64))"
d2="sha256:$(printf 'b%.0s' $(seq 64))"
d3="sha256:$(printf 'c%.0s' $(seq 64))"
tag="0123456789abcdef0123456789abcdef01234567"

echo "update-image-values.sh"

fresh
"$update" --file "$work/images.yaml" --tag "$tag" --digest "gateway=$d1" --dry-run > "$work/out"
check "a dry run leaves the file untouched" cmp -s "$work/images.yaml" "$fixtures/images.yaml"
check "a dry run prints the diff" grep -q "+  tag: \"$tag\"" "$work/out"

fresh
"$update" --file "$work/images.yaml" --tag "$tag" --digest "gateway=$d1" --digest "notifier=$d2" > "$work/out"
check "the tag is written" grep -q "^  tag: \"$tag\"$" "$work/images.yaml"
check "digests are written in the fixed service order" test "$(grep -c '^  [a-z]*: "sha256:' "$work/images.yaml")" = 2
check "gateway comes before notifier" test "$(grep -n 'gateway:' "$work/images.yaml" | cut -d: -f1)" -lt "$(grep -n 'notifier:' "$work/images.yaml" | cut -d: -f1)"
check "the registry line is unchanged" grep -q '^  registry: ghcr.io/example-owner$' "$work/images.yaml"
check "the comments are preserved" test "$(grep -c '^#' "$work/images.yaml")" = "$(grep -c '^#' "$fixtures/images.yaml")"
check "only the tag and digests differ from the original" test "$(diff "$fixtures/images.yaml" "$work/images.yaml" | grep -c '^[<>]')" = 6

cp "$work/images.yaml" "$work/once.yaml"
"$update" --file "$work/images.yaml" --tag "$tag" --digest "gateway=$d1" --digest "notifier=$d2" > "$work/out"
check "running it again changes nothing" cmp -s "$work/images.yaml" "$work/once.yaml"
check "and says so" grep -q '^no changes' "$work/out"

"$update" --file "$work/images.yaml" --tag "$tag" --digest "orders=$d3" > /dev/null
check "a digest for another service is merged, not replacing the others" test "$(grep -c '^  [a-z]*: "sha256:' "$work/images.yaml")" = 3
check "the earlier digests are kept" grep -q "gateway: \"$d1\"" "$work/images.yaml"
"$update" --file "$work/images.yaml" --tag "$tag" --digest "gateway=$d3" > /dev/null
check "a new digest replaces the old one" grep -q "gateway: \"$d3\"" "$work/images.yaml"
"$update" --file "$work/images.yaml" --tag "next-tag.1" > /dev/null
check "a new tag alone keeps the digests" test "$(grep -c '^  [a-z]*: "sha256:' "$work/images.yaml")" = 3

fresh
"$update" --file "$work/images.yaml" --tag "$tag" > /dev/null
check "a tag without digests keeps digests as an empty map" grep -q '^digests: {}$' "$work/images.yaml"

fresh
rejects "no tag is rejected" "$work/images.yaml" --digest "gateway=$d1"
rejects "a tag with a space is rejected" "$work/images.yaml" --tag "bad tag"
rejects "a tag with a colon is rejected" "$work/images.yaml" --tag "a:b"
rejects "a tag with a leading dash is rejected" "$work/images.yaml" --tag "-x"
rejects "an empty tag is rejected" "$work/images.yaml" --tag ""
rejects "a tag with shell characters is rejected" "$work/images.yaml" --tag 'x;rm -rf /'
rejects "a short digest is rejected" "$work/images.yaml" --tag "$tag" --digest "gateway=sha256:abc"
rejects "an upper-case digest is rejected" "$work/images.yaml" --tag "$tag" --digest "gateway=sha256:$(printf 'A%.0s' $(seq 64))"
rejects "a digest without the algorithm is rejected" "$work/images.yaml" --tag "$tag" --digest "gateway=$(printf 'a%.0s' $(seq 64))"
rejects "an unknown service is rejected" "$work/images.yaml" --tag "$tag" --digest "frontend=$d1"
rejects "a digest without a service is rejected" "$work/images.yaml" --tag "$tag" --digest "$d1"
rejects "a service given twice is rejected" "$work/images.yaml" --tag "$tag" --digest "gateway=$d1" --digest "gateway=$d2"
rejects "an unknown option is rejected" "$work/images.yaml" --tag "$tag" --force
rejects "a file without a tag line is rejected" "$fixtures/no-tag.yaml" --tag "$tag"
rejects "a digests block with unexpected content is rejected" "$fixtures/odd-digests.yaml" --tag "$tag"
rejc=0
"$update" --file "$work/missing.yaml" --tag "$tag" > /dev/null 2>&1 || rejc=$?
if [ "$rejc" -eq 2 ]; then ok "a missing file is rejected"; else bad "a missing file is rejected (exit $rejc)"; fi
check "the script runs no version control command" test "$(grep -Ec '(^|[;&| ])git( |$)' "$update")" = 0

echo "changed-services.sh"

run_changed() {
  # run_changed "file1 file2" ARGS...
  local files="$1"
  shift
  printf '%s\n' "$files" | tr ' ' '\n' | "$changed" "$@"
}

shared=(--all-on scripts/apps.sh --all-on .github/workflows/apps.yml --all-on apps/data/)

check "a gateway change affects only the gateway" test "$(run_changed 'apps/gateway/internal/x.go' "${shared[@]}" | head -1)" = 'services=["gateway"]'
check "two services are listed in the fixed order" test "$(run_changed 'apps/payments/pom.xml apps/gateway/main.go' "${shared[@]}" | head -1)" = 'services=["gateway","payments"]'
check "docs do not affect any service" test "$(run_changed 'docs/adr/README.md README.md' "${shared[@]}" | tail -1)" = 'any=false'
check "an empty change affects nothing" test "$(run_changed '' "${shared[@]}" | head -1)" = 'services=[]'
check "a shared script affects every service" test "$(run_changed 'scripts/apps.sh' "${shared[@]}" | head -1)" = 'services=["gateway","orders","payments","notifier"]'
check "the workflow itself affects every service" test "$(run_changed '.github/workflows/apps.yml' "${shared[@]}" | head -1)" = 'services=["gateway","orders","payments","notifier"]'
check "a directory prefix matches files below it" test "$(run_changed 'apps/data/init.sh' "${shared[@]}" | tail -1)" = 'any=true'
check "a similarly named path is not a prefix match" test "$(run_changed 'apps/database/x' "${shared[@]}" | tail -1)" = 'any=false'
check "--all forces every service" test "$(run_changed 'README.md' --all | head -1)" = 'services=["gateway","orders","payments","notifier"]'
check "paths with .. are ignored" test "$(run_changed 'apps/gateway/../orders/x' "${shared[@]}" | tail -1)" = 'any=false'
check "a leading ./ is accepted" test "$(run_changed './apps/orders/x.py' "${shared[@]}" | head -1)" = 'services=["orders"]'
check "an unknown option is rejected" test "$(run_changed 'x' --bogus > /dev/null 2>&1; echo $?)" = 2

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
