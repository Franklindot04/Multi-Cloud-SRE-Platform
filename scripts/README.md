# Scripts

Small helper scripts used by the Makefile, CI and local development. Shell scripts are linted with `scripts/shellcheck.sh`, which runs `shellcheck -S style` (the strictest level, so info and style findings fail) at the version CI installs (0.11.0); `make argocd-check` and `make apps-lint` both use it. Scripts must be idempotent, use `set -euo pipefail`, print usage with `-h`, and avoid embedding credentials.
