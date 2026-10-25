# Infrastructure

Infrastructure as code for both clouds. Everything under [`terraform/`](terraform) is organised as:

| Path | Purpose |
| --- | --- |
| `bootstrap/aws`, `bootstrap/gcp` | One-time stacks that create the remote state buckets |
| `modules/` | Reusable Terraform modules, with a `_template` for new ones |
| `environments/aws` | AWS root stack: S3 backend, provider and variables |
| `environments/gcp` | GCP root stack: GCS backend, provider and variables |

The environment stacks are scaffolding only; networking and clusters follow in later changes. Cluster contents (add-ons, applications) are managed through GitOps from [`platform/`](../platform), not Terraform.

## Conventions

- Terraform 1.11 or later; AWS state uses S3 native locking (stable from 1.11), so there is no DynamoDB table.
- Regions: `eu-north-1` (AWS) and `europe-north1` (GCP).
- CI runs `fmt`, `validate` and `tflint` on pull requests with no cloud credentials (see [`terraform.yml`](../.github/workflows/terraform.yml)). Locally: `make fmt validate`.
- Full conventions: [ADR-0004](../docs/adr/0004-terraform-module-and-state-conventions.md). Bootstrap steps: [runbook](../docs/runbooks/terraform-bootstrap.md).
