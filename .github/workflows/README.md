# Workflows

GitHub Actions workflows.

| Workflow | Trigger | Purpose |
| --- | --- | --- |
| `lint.yml` | Pull request | Markdown and YAML linting |
| `terraform.yml` | Pull request touching `infra/terraform` | `terraform fmt`, `validate`, module tests and `tflint` |
| `argocd.yml` | Pull request touching `platform/argocd`, `platform/addons` or `scripts` | Argo CD chart render and schema checks, ApplicationSet reference and parameter checks, `yamllint`, `shellcheck` |
| `data.yml` | Pull request touching `platform/data`, the local data compose file or `scripts` | Data layer charts (standard and HA profiles), vendored operator manifest checksum, custom resource schemas, compose file, `yamllint`, `shellcheck` |
| `deploy.yml` | Pull request touching `deploy`, `platform/argocd`, the RabbitMQ credential chart or `scripts` | Service chart `helm lint` and `helm template` under every profile and cloud, `kubeconform`, security checks on the rendered output, `yamllint`, `shellcheck` |
| `apps.yml` | Every pull request; push to `main` touching `apps`, `scripts` or the Makefile | Change detection per service; lint and unit tests per changed service (cached Go modules, uv, Maven); helper script tests and `shellcheck`; the in-memory smoke test; the integration suite, `smoke-test.sh --integration` and the chaos checks against PostgreSQL, Valkey and RabbitMQ containers, with container logs uploaded on failure |
| `images.yml` | Pull request or push to `main` touching `apps` | Builds each changed image for `linux/amd64` (no push on pull requests); on `main` pushes `ghcr.io/<owner>/<service>` tagged with the full and short commit SHA (no `latest`) and writes a summary with digests and the command to update the chart values. The only job with `packages: write`; never runs for pull requests |
| `addons.yml` | Pull request touching `platform/addons` | `helm lint`, `helm template`, `kubeconform` and `yamllint` for every add-on |

All jobs run on `ubuntu-24.04`, not `ubuntu-latest`, so a runner image migration cannot change builds unannounced. Checked on 2026-10-28 against the GitHub-hosted runner list in `actions/runner-images`: the labels on offer were `ubuntu-26.04`, `ubuntu-24.04` and `ubuntu-22.04` (plus arm64 variants and `ubuntu-slim`), and `ubuntu-latest` still resolved to `ubuntu-24.04`. 24.04 is the current LTS that `ubuntu-latest` points to, so nothing changes today; moving to 26.04 is a deliberate edit of the label once the tools the workflows install have been tried on it. The `apps` workflow starts on every pull request (a change-detection job decides what runs, and the `Apps result` job counts skipped jobs as passing and fails on any failure or cancellation); the `images` workflow and the push trigger keep their path filters.

All workflows use read-only permissions by default and no cloud credentials. `images.yml` is the one workflow with a write permission (`packages: write`, on the publish job only, on pushes to `main`) and uses only the built-in token. None uses `pull_request_target`, and none interpolates untrusted input into a shell command. The new workflows pin their actions to commit SHAs (the release is named in a comment); the older ones still use version tags, and moving them is part of the supply chain change ([ADR-0017](../../docs/adr/0017-ci-pipeline-and-image-publishing.md)). CI never commits to the repository: image tags are updated with `scripts/update-image-values.sh` in a pull request ([releasing images](../../docs/runbooks/releasing-images.md)).

Planned: Terraform plan/apply, and the supply chain steps for the images (SBOM, vulnerability scanning, signing, provenance).
