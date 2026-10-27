#!/usr/bin/env bash
# Report which paths a .gitignore file would ignore, using only file reads and pattern matching (no git).
#
# Input on stdin: one path per line, prefixed with its type: "d <path>" for a directory, "f <path>" for a file,
# relative to the repository root. Output: one "IGNORED <path> (<pattern>, line <n>)" line per path that
# would be ignored. Exit status is 0 either way; callers decide what to do with the output.
#
# A path is ignored when the last rule that matches it, or the last rule that matches one of its parent
# directories, is not a negation. Once a parent directory is ignored, nothing below it can be re-included,
# which is how git behaves too.
#
# Limits: this reads one .gitignore only. It does not read nested .gitignore files, .git/info/exclude or a
# global excludes file; it does not know which files are already tracked (git does not ignore a tracked file);
# it treats matching as case-sensitive (git on macOS may not); and it does not handle backslash escapes, which
# the repository's rules do not use. Run "git check-ignore" if you need git's own answer.
#
# Usage: scripts/gitignore-match.sh [--gitignore FILE] < paths
#        scripts/gitignore-match.sh --self-test
set -euo pipefail

gitignore=".gitignore"

match() {
  awk -v gitignore="$1" '
    # Translate one gitignore glob to an extended regular expression.
    function glob_to_regex(p,    i, c, r, n, j) {
      r = ""
      n = length(p)
      for (i = 1; i <= n; i++) {
        c = substr(p, i, 1)
        if (c == "*") {
          if (substr(p, i + 1, 1) == "*") {
            if (substr(p, i + 2, 1) == "/") { r = r "(.*/)?"; i += 2 }
            else { r = r ".*"; i += 1 }
          } else {
            r = r "[^/]*"
          }
        } else if (c == "?") {
          r = r "[^/]"
        } else if (c == "[") {
          j = index(substr(p, i), "]")
          if (j > 0) {
            r = r "[" ((substr(p, i + 1, 1) == "!") ? "^" substr(p, i + 2, j - 3) : substr(p, i + 1, j - 2)) "]"
            i += j - 1
          } else {
            r = r "\\["
          }
        } else if (c ~ /[.+(){}|^$\\]/) {
          r = r "\\" c
        } else {
          r = r c
        }
      }
      return r
    }

    BEGIN {
      nrules = 0
      lineno = 0
      while ((getline line < gitignore) > 0) {
        lineno++
        sub(/[ \t\r]+$/, "", line)
        if (line == "" || substr(line, 1, 1) == "#") continue
        neg = 0
        if (substr(line, 1, 1) == "!") { neg = 1; line = substr(line, 2) }
        dironly = 0
        if (substr(line, length(line), 1) == "/") { dironly = 1; line = substr(line, 1, length(line) - 1) }
        anchored = (index(line, "/") > 0)
        if (substr(line, 1, 1) == "/") line = substr(line, 2)
        re = glob_to_regex(line)
        re = anchored ? ("^" re "$") : ("(^|/)" re "$")
        nrules++
        rule_re[nrules] = re
        rule_neg[nrules] = neg
        rule_dir[nrules] = dironly
        rule_text[nrules] = (neg ? "!" : "") line (dironly ? "/" : "")
        rule_line[nrules] = lineno
      }
      close(gitignore)
    }

    {
      type = substr($0, 1, 1)
      path = substr($0, 3)
      n = split(path, parts, "/")
      prefix = ""
      for (k = 1; k <= n; k++) {
        prefix = (k == 1) ? parts[k] : prefix "/" parts[k]
        is_dir = (k < n) || (type == "d")
        state = 0
        by = 0
        for (r = 1; r <= nrules; r++) {
          if (rule_dir[r] && !is_dir) continue
          if (prefix ~ rule_re[r]) { state = !rule_neg[r]; by = r }
        }
        if (state) {
          printf "IGNORED %s (%s, line %d)\n", path, rule_text[by], rule_line[by]
          break
        }
      }
    }
  '
}

self_test() {
  local dir out failures=0
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  cat > "$dir/.gitignore" << 'RULES'
# comment
*.pem
.env
.env.*
!.env.example
secrets/
/root-only/
apps/*/bin/
**/.terraform/*
*.tfvars
!example.tfvars
infra/terraform/modules/**/.terraform.lock.hcl
RULES

  expect() {
    # expect IGNORED|OK TYPE PATH
    out="$(printf '%s %s\n' "$2" "$3" | match "$dir/.gitignore")"
    if { [ "$1" = IGNORED ] && [ -n "$out" ]; } || { [ "$1" = OK ] && [ -z "$out" ]; }; then
      return 0
    fi
    echo "self-test failed: expected $1 for '$2 $3', got: ${out:-nothing}" >&2
    failures=$((failures + 1))
  }

  expect IGNORED f certs/server.pem
  expect IGNORED f apps/.env
  expect OK f apps/.env.example
  expect IGNORED d platform/data/secrets
  expect IGNORED f platform/data/secrets/values.yaml
  expect OK d platform/data/secretsx
  expect OK f platform/data/secrets.yaml
  expect IGNORED d root-only
  expect OK d platform/root-only
  expect IGNORED d apps/orders/bin
  expect OK d apps/orders/src
  expect IGNORED f infra/terraform/environments/aws/.terraform/x
  expect IGNORED f prod.tfvars
  expect OK f example.tfvars
  expect IGNORED f infra/terraform/modules/aws-eks/.terraform.lock.hcl
  expect OK f infra/terraform/environments/aws/.terraform.lock.hcl
  expect OK f docs/adr/README.md

  if [ "$failures" -gt 0 ]; then
    return 1
  fi
  echo "gitignore matcher self-test passed"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --gitignore)
      [ "$#" -ge 2 ] || {
        echo "error: --gitignore needs a value" >&2
        exit 2
      }
      gitignore="$2"
      shift 2
      ;;
    --self-test)
      self_test
      exit $?
      ;;
    -h | --help)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

match "$gitignore"
