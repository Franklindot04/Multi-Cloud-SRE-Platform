#!/usr/bin/env bash
# Rewrites deploy/helm/values/images.yaml with a new image tag and per-service digests.
#
#   scripts/update-image-values.sh --tag <full commit SHA> \
#     --digest gateway=sha256:<64 hex> --digest orders=sha256:<64 hex> [--dry-run]
#
# Only the "tag:" line under "image:" and the entries under "digests:" change. Comments, the registry and
# every other line are left as they are. A digest given for a service replaces its previous one; services you
# do not mention keep theirs, so a release that rebuilt only some images does not lose the others. Running it
# twice with the same arguments changes nothing. It prints a unified diff of what changed (or "no changes")
# and runs no version control commands, so committing the result and opening a pull request stay manual.
#
# Options:
#   --tag TAG            image tag (the full commit SHA of the build); required
#   --digest SVC=DIGEST  digest of one service image, sha256:<64 lower-case hex>; repeatable
#   --file PATH          values file (default deploy/helm/values/images.yaml)
#   --dry-run            show the diff and change nothing
#   -h, --help           show this help
#
# Services: gateway, orders, payments, notifier. Exit status: 0 success, 2 bad arguments or file.
set -euo pipefail

SERVICES="gateway orders payments notifier"
FILE="deploy/helm/values/images.yaml"
TAG=""
DRY_RUN=0
DIGESTS=""

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tag)
      [ "$#" -ge 2 ] || die "--tag needs a value"
      TAG="$2"
      shift 2
      ;;
    --digest)
      [ "$#" -ge 2 ] || die "--digest needs a value like gateway=sha256:..."
      DIGESTS="$DIGESTS
$2"
      shift 2
      ;;
    --file)
      [ "$#" -ge 2 ] || die "--file needs a value"
      FILE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
done

[ -n "$TAG" ] || die "--tag is required"
# The Docker tag grammar: at most 128 characters, no leading '.' or '-'.
printf '%s' "$TAG" | grep -Eq '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$' ||
  die "invalid tag '$TAG' (letters, digits, '_', '.', '-', at most 128, no leading '.' or '-')"

# Validate every digest argument and build "service digest" lines.
pairs=""
seen=" "
while IFS= read -r arg; do
  [ -n "$arg" ] || continue
  svc="${arg%%=*}"
  digest="${arg#*=}"
  [ "$svc" != "$arg" ] || die "invalid --digest '$arg': expected SERVICE=sha256:<64 hex>"
  case " $SERVICES " in
    *" $svc "*) ;;
    *) die "unknown service '$svc' (expected one of: $SERVICES)" ;;
  esac
  printf '%s' "$digest" | grep -Eq '^sha256:[0-9a-f]{64}$' ||
    die "invalid digest for $svc: expected sha256: followed by 64 lower-case hex characters"
  case "$seen" in
    *" $svc "*) die "digest for $svc given more than once" ;;
  esac
  seen="$seen$svc "
  pairs="$pairs$svc $digest
"
done << ARGS
$DIGESTS
ARGS

[ -f "$FILE" ] || die "$FILE does not exist"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
new="$work/new.yaml"

# One pass over the file. State is the current top-level key. The tag line under "image:" is replaced; the
# "digests:" block is rebuilt from its existing entries plus the new ones, in the fixed service order, and
# anything unexpected inside it makes the script stop rather than guess.
PAIRS="$pairs" awk -v tag="$TAG" -v services="$SERVICES" '
  function flush_digests(   i, n, any) {
    if (!in_digests) return
    for (svc in fresh) digest[svc] = fresh[svc]
    any = 0
    n = split(services, order, " ")
    for (i = 1; i <= n; i++) if (order[i] in digest) any = 1
    if (any) {
      print "digests:"
      for (i = 1; i <= n; i++) if (order[i] in digest) printf "  %s: \"%s\"\n", order[i], digest[order[i]]
    } else {
      print "digests: {}"
    }
    for (i = 1; i <= blanks; i++) print ""
    blanks = 0
    in_digests = 0
  }
  BEGIN {
    n = split(ENVIRON["PAIRS"], lines, "\n")
    for (i = 1; i <= n; i++) {
      if (lines[i] == "") continue
      split(lines[i], kv, " ")
      fresh[kv[1]] = kv[2]
    }
  }
  /^[A-Za-z_][A-Za-z0-9_]*:/ {
    flush_digests()
    section = $0
    sub(/:.*/, "", section)
    if (section == "digests") {
      in_digests = 1
      seen_digests++
      if ($0 !~ /^digests:[ ]*(\{\})?[ ]*$/) { print "unsupported digests line: " $0 > "/dev/stderr"; bad = 1 }
      next
    }
  }
  in_digests {
    if ($0 ~ /^[ ]*$/) { blanks++; next }
    if ($0 ~ /^  [a-z]+: "?sha256:[0-9a-f]+"?[ ]*$/) {
      svc = $0; sub(/^  /, "", svc); sub(/:.*/, "", svc)
      match($0, /sha256:[0-9a-f]+/)
      digest[svc] = substr($0, RSTART, RLENGTH)
      next
    }
    print "unsupported line in digests: " $0 > "/dev/stderr"; bad = 1
    next
  }
  section == "image" && /^  tag:/ { print "  tag: \"" tag "\""; tags++; next }
  { print }
  END {
    flush_digests()
    if (tags != 1) { print "expected exactly one tag: line under image:, found " tags + 0 > "/dev/stderr"; bad = 1 }
    if (seen_digests != 1) { print "expected exactly one digests: key, found " seen_digests + 0 > "/dev/stderr"; bad = 1 }
    exit bad ? 1 : 0
  }
' "$FILE" > "$new" 2> "$work/err" || {
  cat "$work/err" >&2
  die "$FILE does not have the expected structure; nothing was changed"
}

if cmp -s "$FILE" "$new"; then
  echo "no changes: $FILE already has this tag and these digests"
  exit 0
fi

echo "changes to $FILE:"
diff -u "$FILE" "$new" | sed '1,2d' || true

if [ "$DRY_RUN" -eq 1 ]; then
  echo "dry run: $FILE was not modified"
  exit 0
fi

cp "$new" "$FILE"
echo "updated $FILE"
