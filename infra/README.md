# Infrastructure

Infrastructure as code for both clouds. Everything under [`terraform/`](terraform) is organised as:

| Path | Purpose |
| --- | --- |
| `bootstrap/aws`, `bootstrap/gcp` | One-time stacks that create the remote state buckets |
| `modules/` | Reusable Terraform modules (`aws-network`, `aws-eks`), with a `_template` for new ones |
| `environments/aws` | AWS root stack: S3 backend, provider, variables, the VPC network and the EKS cluster |
| `environments/gcp` | GCP root stack: GCS backend, provider and variables |

AWS networking (VPC, subnets, NAT, flow logs) and the EKS cluster (managed Spot node group, add-ons, IRSA) are defined and ready to apply; GCP networking and GKE follow in later changes. The CIDR plan for both clouds is in [ADR-0006](../docs/adr/0006-aws-network-design.md). Cluster contents (add-ons, applications) are managed through GitOps from [`platform/`](../platform), not Terraform.

## Conventions

- Terraform 1.11 or later; AWS state uses S3 native locking (stable from 1.11), so there is no DynamoDB table.
- Regions: `eu-north-1` (AWS) and `europe-north1` (GCP).
- CI runs `fmt`, `validate` and `tflint` on pull requests with no cloud credentials (see [`terraform.yml`](../.github/workflows/terraform.yml)). CI also runs the module tests. Locally: `make fmt validate test`.
- Full conventions: [ADR-0004](../docs/adr/0004-terraform-module-and-state-conventions.md). Runbooks: [bootstrap](../docs/runbooks/terraform-bootstrap.md) and [AWS network](../docs/runbooks/aws-network.md) and [AWS EKS](../docs/runbooks/aws-eks.md).
