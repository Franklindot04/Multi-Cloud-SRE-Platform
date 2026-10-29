# Scripts

Small helper scripts used by the Makefile, CI and local development. Shell scripts are linted with `scripts/shellcheck.sh`, which runs `shellcheck -S style` (the strictest level, so info and style findings fail) at the version CI installs (0.11.0); `make argocd-check` and `make apps-lint` both use it. Scripts must be idempotent, use `set -euo pipefail`, print usage with `-h`, and avoid embedding credentials.

- `teardown-prep.sh --context CONTEXT [--region R] [--cluster-name N] [--dry-run]`: prepares a cluster for `terraform destroy` (removes the Argo CD cluster Secret labels, deletes the kept data resources and claims, checks volumes, load balancers and security groups). See the [data layer runbook](../docs/runbooks/data-layer.md#teardown). Tested against a fake `kubectl` and `aws` in `scripts/tests/fakes` by `scripts/test-scripts.sh`.
- `chart-contract-check.py` and `python-with-yaml.sh`: contract checks run by `data-manifests-check.sh`, `deploy-check.sh` and `argocd-check.sh` (no hook-only chart, no Helm-hook Job that creates Secrets, the PostgreSQL PreSync gate, the sync-wave order of the data ApplicationSets).
