#!/usr/bin/env bash
# Generate the platform's secret values and write them to AWS Systems Manager Parameter Store.
#
#   scripts/seed-secrets.sh --region eu-north-1                  create the parameters that are missing
#   scripts/seed-secrets.sh --region eu-north-1 --check          list which exist and which are missing
#   scripts/seed-secrets.sh --region eu-north-1 --purge          delete every parameter under the path
#
# The list of secrets is scripts/secrets/manifest.yaml: a name, a length and a character set for each, never a value. Each
# parameter is written as
#
#   /<prefix>/<environment>/<name>      for example /multi-cloud-sre/dev/postgres/orders-password
#
# as a SecureString of the standard tier, encrypted with the AWS-managed key alias/aws/ssm. That key outlives the cluster
# (the Terraform KMS key is destroyed and recreated with every cluster, and parameters encrypted with it would become unreadable
# after a rebuild). A production setup would use a customer-managed key with its own lifecycle. Terraform creates no parameter
# and the values never pass through it or its state; the IAM role of the External Secrets Operator (infra/terraform, module
# aws-external-secrets-iam) only reads the path.
#
# The values:
#   - are generated here, from /dev/urandom, restricted to the character set of the manifest entry
#   - are written with put-parameter --no-overwrite, so a value that exists is never changed; running the script twice is safe
#   - are never printed and never read back: the script does not call get-parameter, and --check uses describe-parameters, which
#     returns names and metadata only
#   - never appear on a command line. They are held in a shell variable and written, as {"Value": "..."}, to a file that the
#     AWS CLI reads (--cli-input-json file://<path>) with the printf builtin, so no process has a value in its arguments (ps shows
#     only the parameter name and the flags). The AWS CLI does not accept the JSON from a pipe (file:///dev/stdin fails with
#     "Invalid JSON received"), so a file it is. The file is in a directory made for this run with umask 077 and mktemp -d (mode
#     0700, owner only), is itself mode 0600, and is deleted straight after each put-parameter call; the directory is removed
#     by a trap on exit, interrupt, termination and hangup. This does not erase the value: on a modern Mac or an SSD, deleting
#     or overwriting a file does not guarantee that the blocks are gone. The honest statement is that the value exists on disk
#     for a moment, in a directory only the owner can read, and the file is deleted straight after use.
#   - are not echoed by the error handling: the script prints the AWS error code of a failure (when there is one) and the exit
#     status of the CLI, not the CLI's message, which can quote the input
#   - cannot be traced: shell tracing is switched off at the start
#
# Options:
#   --region REGION       AWS region (default: AWS_REGION, then AWS_DEFAULT_REGION); required
#   --environment ENV     dev, staging or prod (default dev)
#   --prefix PREFIX       first segment of the path (default multi-cloud-sre; the Terraform variable secrets_parameter_prefix)
#   --profile PROFILE     AWS CLI profile
#   --manifest FILE       the list of secrets (default scripts/secrets/manifest.yaml)
#   --check               report which parameters exist and which are missing; no value is written or read; exit 1 if any is missing
#   --purge               delete every parameter under /<prefix>/<environment>, after you type the environment name to confirm
#   --dry-run             print what would be done and make no AWS call
#   -h, --help            show this help
# There is no --yes: the confirmation of --purge cannot be skipped.
#
# Exit status: 0 done (or nothing to do), 1 a parameter is missing (--check), an error occurred, or --purge was not confirmed,
# 2 bad arguments.
set -euo pipefail
set +o xtrace

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

cd "$(dirname "${BASH_SOURCE[0]}")/.."

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
ENVIRONMENT=dev
PREFIX=multi-cloud-sre
PROFILE=""
MANIFEST=scripts/secrets/manifest.yaml
MODE=seed
DRY_RUN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --region | --environment | --prefix | --profile | --manifest)
      [ "$#" -ge 2 ] || die "$1 needs a value"
      case "$1" in
        --region) REGION="$2" ;;
        --environment) ENVIRONMENT="$2" ;;
        --prefix) PREFIX="$2" ;;
        --profile) PROFILE="$2" ;;
        --manifest) MANIFEST="$2" ;;
      esac
      shift 2
      ;;
    --check)
      [ "$MODE" = seed ] || die "--check and --purge cannot be combined"
      MODE=check
      shift
      ;;
    --purge)
      [ "$MODE" = seed ] || die "--check and --purge cannot be combined"
      MODE=purge
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --yes | -y | --force)
      die "$1 is not accepted: --purge always asks you to type the environment name"
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

[ -n "$REGION" ] || die "--region is required (or set AWS_REGION)"
case "$REGION" in
  *[!a-z0-9-]*) die "--region must look like eu-north-1, got '$REGION'" ;;
esac
case "$ENVIRONMENT" in
  dev | staging | prod) ;;
  *) die "--environment must be dev, staging or prod, got '$ENVIRONMENT'" ;;
esac
case "$PREFIX" in
  "" | *[!a-z0-9-]* | -* | *-) die "--prefix must be one lower-case segment of letters, digits and hyphens, got '$PREFIX'" ;;
esac
[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"

PATH_ROOT="/$PREFIX/$ENVIRONMENT"
KEY_ID="alias/aws/ssm"

aws_cmd() {
  if [ -n "$PROFILE" ]; then
    aws --region "$REGION" --profile "$PROFILE" "$@"
  else
    aws --region "$REGION" "$@"
  fi
}

n=0
TOTAL=3
step() {
  n=$((n + 1))
  printf '\n[%s/%s] %s\n' "$n" "$TOTAL" "$1"
}

# --- 1. the manifest ---

py="$(./scripts/python-with-yaml.sh)" || die "no Python with PyYAML found (installing yamllint provides it)"

# The manifest, checked and flattened to one line for each secret: name, length, tr class, prefix (a dash if none).
LINES="$("$py" - "$MANIFEST" << 'PYEND'
import re
import sys

import yaml

doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
problems = []
if not isinstance(doc, dict) or doc.get("version") != 1:
    problems.append("the manifest must be a mapping with version: 1")
    doc = {}
sets = doc.get("charsets") or {}
for key, value in sets.items():
    # A tr class made of single characters and ranges of letters and digits: nothing that needs escaping anywhere.
    if not isinstance(value, str) or not re.fullmatch(r"(?:[A-Za-z0-9]-[A-Za-z0-9]|[A-Za-z0-9])+", value):
        problems.append("charset %s must be letters, digits and ranges of them, such as A-Za-z0-9" % key)
seen = set()
rows = []
for s in doc.get("secrets") or []:
    name = s.get("name", "")
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*/[a-z0-9]+(?:-[a-z0-9]+)*", str(name)):
        problems.append("secret name %r must be <component>/<name> in lower case letters, digits and hyphens" % name)
        continue
    if name in seen:
        problems.append("secret %s is listed twice" % name)
    seen.add(name)
    length = s.get("length")
    if not isinstance(length, int) or not 16 <= length <= 128:
        problems.append("%s: length must be a whole number from 16 to 128" % name)
        continue
    charset = s.get("charset")
    if charset not in sets:
        problems.append("%s: charset %r is not defined" % (name, charset))
        continue
    prefix = str(s.get("prefix", ""))
    if prefix and not re.fullmatch(r"[A-Za-z0-9]{1,8}", prefix):
        problems.append("%s: prefix must be one to eight letters or digits" % name)
        continue
    if len(prefix) >= length:
        problems.append("%s: the prefix is not shorter than the length" % name)
        continue
    if not s.get("consumers"):
        problems.append("%s: consumers must say who reads the value" % name)
    rows.append((name, length, sets[charset], prefix or "-"))
if not rows and not problems:
    problems.append("the manifest lists no secret")
if problems:
    for p in problems:
        print("manifest: " + p, file=sys.stderr)
    sys.exit(1)
for r in rows:
    print("\t".join(str(x) for x in r))
PYEND
)" || die "the manifest is not valid: $MANIFEST"

COUNT="$(printf '%s\n' "$LINES" | wc -l | tr -d ' ')"

printf 'Secrets under %s in %s (%s): %s listed in %s\n' "$PATH_ROOT" "$REGION" "$ENVIRONMENT" "$COUNT" "$MANIFEST"
[ "$DRY_RUN" -eq 0 ] || printf 'Dry run: no AWS call is made and no value is generated.\n'

step "Read the manifest"
printf '%s\n' "$LINES" | while IFS="$(printf '\t')" read -r name length class prefix; do
  printf '  %s (%s characters from %s%s)\n' "$name" "$length" "$class" "$([ "$prefix" = "-" ] || printf ', starting with %s' "$prefix")"
done

if [ "$DRY_RUN" -eq 0 ]; then
  command -v aws > /dev/null 2>&1 || die "the AWS CLI is not installed"
fi

# names_under_path: the names of the parameters under the path, one per line. describe-parameters returns names and metadata,
# never a value.
names_under_path() {
  local out
  out="$(aws_cmd ssm describe-parameters --parameter-filters "Key=Path,Option=Recursive,Values=$PATH_ROOT" \
    --query 'Parameters[].Name' --output text)" || return 1
  printf '%s\n' "$out" | tr '\t' '\n' | grep '^/' || true
}

# error_code TEXT: the AWS error code in "An error occurred (Code) when calling ...", or nothing.
error_code() {
  printf '%s\n' "$1" | sed -n 's/^.*An error occurred (\([A-Za-z]*\)).*$/\1/p' | head -n 1
}

# new_value LENGTH CLASS PREFIX: print a random value, without a newline.
new_value() {
  local length="$1" class="$2" prefix="$3" body want
  [ "$prefix" != "-" ] || prefix=""
  want=$((length - ${#prefix}))
  body="$(LC_ALL=C tr -dc "$class" < /dev/urandom | head -c "$want" || true)"
  [ "${#body}" -eq "$want" ] || return 1
  printf '%s%s' "$prefix" "$body"
}

status=0

# The directory for the files that carry a value to the AWS CLI. Made only when something is written, removed on every way out.
SEED_DIR=""
# The EXIT trap runs on every way out, including the exits the signal traps below cause.
trap '[ -z "$SEED_DIR" ] || rm -rf "$SEED_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

case "$MODE" in
  seed)
    step "Check the path and the tools"
    printf '  path: %s\n  key: %s, standard tier, SecureString, put with --no-overwrite\n' "$PATH_ROOT" "$KEY_ID"

    step "Create the parameters that are missing"
    if [ "$DRY_RUN" -eq 0 ]; then
      # Owner only: the directory is mode 0700 and the files in it 0600.
      umask 077
      SEED_DIR="$(mktemp -d "${TMPDIR:-/tmp}/seed-secrets.XXXXXX")" || die "could not create a temporary directory"
      SEED_FILE="$SEED_DIR/parameter.json"
    fi
    created=0
    existed=0
    failed=0
    while IFS="$(printf '\t')" read -r name length class prefix <&3; do
      full="$PATH_ROOT/$name"
      if [ "$DRY_RUN" -eq 1 ]; then
        printf '  would write  %s  (%s characters)\n' "$full" "$length"
        continue
      fi
      value="$(new_value "$length" "$class" "$prefix")" || {
        printf '  error    %s: could not generate a value\n' "$full"
        failed=$((failed + 1))
        continue
      }
      # The value goes into a file that only the owner can read (printf is a builtin, so it is in no command line); the command line
      # has the name, the flags and the path. The file is deleted straight after the call.
      printf '{"Value":"%s"}' "$value" > "$SEED_FILE"
      if err="$(aws_cmd ssm put-parameter --name "$full" --type SecureString --tier Standard \
        --key-id "$KEY_ID" --no-overwrite --cli-input-json "file://$SEED_FILE" 2>&1 > /dev/null)"; then
        rm -f "$SEED_FILE"
        printf '  created  %s\n' "$full"
        created=$((created + 1))
      else
        put_status=$?
        rm -f "$SEED_FILE"
        code="$(error_code "$err")"
        if [ "$code" = ParameterAlreadyExists ]; then
          printf '  exists   %s\n' "$full"
          existed=$((existed + 1))
        else
          printf '  error    %s: %s (exit status %s)\n' "$full" "${code:-the AWS CLI failed}" "$put_status"
          failed=$((failed + 1))
        fi
      fi
      value=""
    done 3<<< "$LINES"
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '\nDry run: %s parameter(s) would be written (those that exist are left as they are).\n' "$COUNT"
    else
      printf '\n%s created, %s already existed, %s failed.\n' "$created" "$existed" "$failed"
    fi
    [ "$failed" -eq 0 ] || status=1
    ;;

  check)
    step "List the parameters under the path"
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '  would list the parameters under %s (names only)\n' "$PATH_ROOT"
      exit 0
    fi
    existing="$(names_under_path)" || {
      printf 'error: could not list the parameters under %s\n' "$PATH_ROOT" >&2
      exit 1
    }
    step "Compare with the manifest"
    missing=0
    while IFS="$(printf '\t')" read -r name _ _ _ <&3; do
      full="$PATH_ROOT/$name"
      if printf '%s\n' "$existing" | grep -qxF -- "$full"; then
        printf '  exists   %s\n' "$full"
      else
        printf '  missing  %s\n' "$full"
        missing=$((missing + 1))
      fi
    done 3<<< "$LINES"
    printf '\n%s of %s parameter(s) missing.\n' "$missing" "$COUNT"
    [ "$missing" -eq 0 ] || status=1
    ;;

  purge)
    step "List the parameters under the path"
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '  would list every parameter under %s and delete them after you type "%s"\n' "$PATH_ROOT" "$ENVIRONMENT"
      exit 0
    fi
    existing="$(names_under_path)" || {
      printf 'error: could not list the parameters under %s\n' "$PATH_ROOT" >&2
      exit 1
    }
    if [ -z "$existing" ]; then
      printf '  no parameter under %s: nothing to delete\n' "$PATH_ROOT"
      exit 0
    fi
    printf '%s\n' "$existing" | sed 's/^/  /'
    total="$(printf '%s\n' "$existing" | wc -l | tr -d ' ')"
    step "Confirm"
    printf '  This deletes %s parameter(s) under %s in %s for good.\n' "$total" "$PATH_ROOT" "$REGION"
    printf '  Type the environment name (%s) to go on: ' "$ENVIRONMENT"
    answer=""
    read -r answer || true
    if [ "$answer" != "$ENVIRONMENT" ]; then
      printf '\nNot confirmed. Nothing was deleted.\n' >&2
      exit 1
    fi
    printf '\n'
    deleted=0
    batch=()
    flush() {
      [ "${#batch[@]}" -gt 0 ] || return 0
      if aws_cmd ssm delete-parameters --names "${batch[@]}" --query 'InvalidParameters' --output text > /dev/null; then
        for b in "${batch[@]}"; do
          printf '  deleted  %s\n' "$b"
          deleted=$((deleted + 1))
        done
      else
        for b in "${batch[@]}"; do printf '  error    %s: delete-parameters failed\n' "$b"; done
        status=1
      fi
      batch=()
    }
    while IFS= read -r name; do
      batch+=("$name")
      [ "${#batch[@]}" -lt 10 ] || flush
    done <<< "$existing"
    flush
    printf '\n%s deleted.\n' "$deleted"
    ;;
esac

exit "$status"
