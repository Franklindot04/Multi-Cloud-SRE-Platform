# Infrastructure

Infrastructure as code for both clouds. Everything under [`terraform/`](terraform) is organised as:

| Path | Purpose |
| --- | --- |
| `bootstrap/aws`, `bootstrap/gcp` | One-time stacks that create the remote state buckets |
| `modules/` | Reusable Terraform modules (`aws-network`, `aws-eks`, `aws-irsa`, `gcp-network`, `gcp-gke`, `aws-dns`, `gcp-dns`), with a `_template` for new ones |
| `environments/aws` | AWS root stack: S3 backend, provider, variables, the VPC network, the EKS cluster and optional DNS |
| `environments/gcp` | GCP root stack: GCS backend, provider, variables, the VPC network, the GKE cluster and an optional DNS zone |

AWS networking (VPC, subnets, NAT, flow logs) and the EKS cluster (managed Spot node group, add-ons, IRSA) are defined and ready to apply; GCP networking (custom VPC, GKE secondary ranges, Cloud NAT, firewall) and the GKE cluster (private nodes, Workload Identity, Spot node pool) are defined as well. Optional DNS and cross-cloud traffic steering (a Route 53 parent zone, a Cloud DNS subdomain and weighted or failover records) is defined too, and is off until a domain name is supplied. See [ADR-0010](../docs/adr/0010-dns-and-traffic-management.md). The CIDR plan for both clouds is in [ADR-0006](../docs/adr/0006-aws-network-design.md). Cluster contents (add-ons, applications) are managed through GitOps from [`platform/`](../platform), not Terraform.

## Conventions

- Terraform 1.11 or later; AWS state uses S3 native locking (stable from 1.11), so there is no DynamoDB table.
- Regions: `eu-north-1` (AWS) and `europe-north1` (GCP).
- CI runs `fmt`, `validate` and `tflint` on pull requests with no cloud credentials (see [`terraform.yml`](../.github/workflows/terraform.yml)). CI also runs the module tests. Locally: `make fmt validate test`.
- Full conventions: [ADR-0004](../docs/adr/0004-terraform-module-and-state-conventions.md). Runbooks: [bootstrap](../docs/runbooks/terraform-bootstrap.md) and [AWS network](../docs/runbooks/aws-network.md) and [AWS EKS](../docs/runbooks/aws-eks.md) and [GCP network](../docs/runbooks/gcp-network.md) and [GCP GKE](../docs/runbooks/gcp-gke.md), and [global DNS](../docs/runbooks/global-dns.md). The baseline add-ons (load balancer controller, external-dns, cert-manager, metrics-server) are defined as GitOps-ready charts in [`platform/addons`](../platform/addons); Terraform creates only their cloud permissions (`addons-iam.tf` in each environment, IAM roles for service accounts on AWS and Workload Identity service accounts on GCP). See [ADR-0011](../docs/adr/0011-cluster-baseline-addons.md) and the [cluster add-ons runbook](../docs/runbooks/cluster-addons.md).
