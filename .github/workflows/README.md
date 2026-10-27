# Workflows

GitHub Actions workflows.

| Workflow | Trigger | Purpose |
| --- | --- | --- |
| `lint.yml` | Pull request | Markdown and YAML linting |
| `terraform.yml` | Pull request touching `infra/terraform` | `terraform fmt`, `validate`, module tests and `tflint` |
| `argocd.yml` | Pull request touching `platform/argocd`, `platform/addons` or `scripts` | Argo CD chart render and schema checks, ApplicationSet reference and parameter checks, `yamllint`, `shellcheck` |
| `data.yml` | Pull request touching `platform/data`, the local data compose file or `scripts` | Data layer charts (standard and HA profiles), vendored operator manifest checksum, custom resource schemas, compose file, `yamllint`, `shellcheck` |
| `deploy.yml` | Pull request touching `deploy`, `platform/argocd`, the RabbitMQ credential chart or `scripts` | Service chart `helm lint` and `helm template` under every profile and cloud, `kubeconform`, security checks on the rendered output, `yamllint`, `shellcheck` |
| `addons.yml` | Pull request touching `platform/addons` | `helm lint`, `helm template`, `kubeconform` and `yamllint` for every add-on |

All workflows use read-only permissions and no cloud credentials.

Planned: Terraform plan/apply, and container build and scan.
