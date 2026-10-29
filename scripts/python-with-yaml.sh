#!/usr/bin/env bash
# Prints the path of a Python interpreter that can import PyYAML, for the scripts that parse YAML.
# python3 if it has PyYAML, otherwise the interpreter yamllint runs on (it depends on PyYAML). Exits 1 and
# prints nothing when there is none.
#
#   py="$(scripts/python-with-yaml.sh)" || echo "no Python with PyYAML"
set -euo pipefail

case "${1:-}" in
  -h | --help)
    sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

if python3 -c 'import yaml' > /dev/null 2>&1; then
  echo python3
  exit 0
fi
if command -v yamllint > /dev/null 2>&1; then
  candidate="$(head -n 1 "$(command -v yamllint)" | sed 's/^#!//')"
  if "$candidate" -c 'import yaml' > /dev/null 2>&1; then
    echo "$candidate"
    exit 0
  fi
fi
exit 1
