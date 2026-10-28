#!/usr/bin/env bash
# Decides which sample services a change affects, for the CI workflows.
#
#   some-command-that-lists-changed-files | scripts/changed-services.sh [--all-on PATH]... [--all]
#
# Reads changed file paths (one per line) on standard input and prints, in GitHub Actions output format:
#
#   services=["gateway","orders"]   JSON array, in the fixed order gateway, orders, payments, notifier
#   any=true|false                  whether any service is affected
#
# A file under apps/<service>/ affects that service. A file that matches an --all-on PATH affects every
# service; PATH is an exact file name or a directory prefix ending in '/'. --all forces every service, for
# example for a first push where no base commit exists. Paths are only compared as text; this script never
# runs a command taken from its input.
set -euo pipefail

SERVICES="gateway orders payments notifier"
ALL=0
ALL_ON=""

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --all)
      ALL=1
      shift
      ;;
    --all-on)
      [ "$#" -ge 2 ] || {
        echo "error: --all-on needs a value" >&2
        exit 2
      }
      ALL_ON="$ALL_ON
$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      echo "error: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

affected=" "
if [ "$ALL" -eq 1 ]; then
  affected=" $SERVICES "
fi

while IFS= read -r file; do
  [ -n "$file" ] || continue
  # Normalise a leading ./ and refuse anything that is not a plain relative path.
  file="${file#./}"
  case "$file" in
    /* | *..*) continue ;;
  esac
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    case "$pattern" in
      */)
        case "$file" in
          "$pattern"*) affected=" $SERVICES " ;;
        esac
        ;;
      *)
        [ "$file" != "$pattern" ] || affected=" $SERVICES "
        ;;
    esac
  done << PATTERNS
$ALL_ON
PATTERNS
  for svc in $SERVICES; do
    case "$file" in
      "apps/$svc/"*)
        case "$affected" in
          *" $svc "*) ;;
          *) affected="$affected$svc " ;;
        esac
        ;;
    esac
  done
done

json="["
count=0
for svc in $SERVICES; do
  case "$affected" in
    *" $svc "*)
      [ "$count" -eq 0 ] || json="$json,"
      json="$json\"$svc\""
      count=$((count + 1))
      ;;
  esac
done
json="$json]"

echo "services=$json"
if [ "$count" -gt 0 ]; then echo "any=true"; else echo "any=false"; fi
