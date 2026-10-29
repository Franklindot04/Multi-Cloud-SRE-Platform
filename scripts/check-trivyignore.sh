#!/usr/bin/env bash
# Checks the Trivy ignore file before an image scan runs, so a finding is never waved through without a reason
# and a date on which the decision is looked at again.
#
#   scripts/check-trivyignore.sh [FILE]        (default: .trivyignore)
#
# Every entry is one vulnerability ID followed by its expiry, and the line directly above it states the reason:
#
#   # reason: the vulnerable function is never called by the gateway; waiting for the base image update
#   CVE-2026-12345 exp:2026-12-31
#
# Blank lines and other comment lines are allowed between entries. An entry fails the check when it
#   - has no "# reason:" line directly above it, or the reason is shorter than ten characters,
#   - has no exp:YYYY-MM-DD date, or the date is not a calendar date,
#   - has an expiry date in the past (Trivy stops ignoring it on that date anyway; the check says so up front),
#   - has anything else on the line.
# An empty file (no entries) passes. TRIVYIGNORE_TODAY (YYYY-MM-DD) replaces today's date, for tests.
#
# Exit status: 0 valid, 1 at least one entry is not valid, 2 bad arguments or an unreadable file.
set -euo pipefail

FILE=".trivyignore"
TODAY="${TRIVYIGNORE_TODAY:-$(date -u +%Y-%m-%d)}"

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  -*)
    printf 'error: unknown option: %s\n' "$1" >&2
    exit 2
    ;;
  '') ;;
  *) FILE="$1" ;;
esac
[ "$#" -le 1 ] || {
  echo "error: at most one file" >&2
  exit 2
}
[ -r "$FILE" ] || {
  printf 'error: cannot read %s\n' "$FILE" >&2
  exit 2
}
if ! [[ "$TODAY" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "error: TRIVYIGNORE_TODAY must be YYYY-MM-DD" >&2
  exit 2
fi

reason_re='^#[[:space:]]*reason:[[:space:]]*(.*[^[:space:]])[[:space:]]*$'
id_re='^[A-Za-z0-9][A-Za-z0-9._:-]*$'
date_re='^exp:([0-9]{4})-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$'

entries=0
problems=0
previous="none"
number=0

fail() {
  printf 'FAIL %s line %s: %s\n' "$FILE" "$number" "$*" >&2
  problems=$((problems + 1))
}

while IFS= read -r line || [ -n "$line" ]; do
  number=$((number + 1))
  trimmed="${line#"${line%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
  if [ -z "$trimmed" ]; then
    previous="blank"
    continue
  fi
  if [[ "$trimmed" == \#* ]]; then
    if [[ "$trimmed" =~ $reason_re ]] && [ "${#BASH_REMATCH[1]}" -ge 10 ]; then
      previous="reason"
    else
      previous="comment"
    fi
    continue
  fi

  entries=$((entries + 1))
  # shellcheck disable=SC2086 # the line is split into words on purpose
  set -- $trimmed
  id="$1"
  expiry="${2:-}"
  if ! [[ "$id" =~ $id_re ]]; then
    fail "'$id' is not a vulnerability ID"
  fi
  if [ "$previous" != "reason" ]; then
    fail "$id has no reason. Put '# reason: <why this is accepted, at least ten characters>' on the line directly above it."
  fi
  if [ "$#" -ne 2 ]; then
    fail "$id must be followed by exactly one expiry, exp:YYYY-MM-DD, and nothing else"
  elif ! [[ "$expiry" =~ $date_re ]]; then
    fail "$id has the expiry '$expiry'; it must be exp:YYYY-MM-DD with a real date"
  elif [[ "${expiry#exp:}" < "$TODAY" ]]; then
    fail "$id expired on ${expiry#exp:}. Remove it, or renew it with a new reason and date after looking at the finding again."
  fi
  previous="entry"
done < "$FILE"

if [ "$problems" -gt 0 ]; then
  printf '%s: %s problem(s) in %s entr%s\n' "$FILE" "$problems" "$entries" "$([ "$entries" -eq 1 ] && echo y || echo ies)" >&2
  exit 1
fi
printf '%s: ok (%s entr%s)\n' "$FILE" "$entries" "$([ "$entries" -eq 1 ] && echo y || echo ies)"
