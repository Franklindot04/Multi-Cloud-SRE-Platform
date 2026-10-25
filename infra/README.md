# Infrastructure

Infrastructure as code for both clouds. Everything under [`terraform/`](terraform) is organised as:

| Path | Purpose |
| --- | --- |
| `bootstrap/` | One-time state backends and CI identity setup |
| `modules/` | Reusable Terraform modules |
| `environments/aws` | AWS root stacks per environment |
| `environments/gcp` | GCP root stacks per environment |

Cluster contents (add-ons, applications) are managed through GitOps from [`platform/`](../platform), not Terraform.
