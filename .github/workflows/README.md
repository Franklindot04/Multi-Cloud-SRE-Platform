# Workflows

GitHub Actions workflows.

| Workflow | Trigger | Purpose |
| --- | --- | --- |
| `lint.yml` | Pull request | Markdown and YAML linting |
| `terraform.yml` | Pull request touching `infra/terraform` | `terraform fmt`, `validate`, module tests and `tflint` |
| `addons.yml` | Pull request touching `platform/addons` | `helm lint`, `helm template`, `kubeconform` and `yamllint` for every add-on |

All workflows use read-only permissions and no cloud credentials.

Planned: Terraform plan/apply, and container build and scan.
