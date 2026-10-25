# aws-network

VPC networking for an EKS-ready environment on AWS: three availability zones, public and private subnets, internet and NAT egress, an S3 gateway endpoint, flow logs and a locked-down default security group. Design rationale is in [ADR-0006](../../../../docs/adr/0006-aws-network-design.md).

## What it creates

- VPC with DNS support and hostnames enabled
- Three availability zones, the first three regular (non-local) zones returned by the region, sorted by name
- Per zone: one public subnet (`/24` in a `/16`) and one private subnet (`/19` in a `/16`), computed from `vpc_cidr`
- Internet gateway; one public route table; one private route table per zone
- NAT gateways according to `nat_mode`
- S3 gateway endpoint attached to every route table
- VPC flow logs (all traffic) to a CloudWatch log group, with an IAM role scoped to that group
- Default security group with all rules removed
- Subnet tags for Kubernetes load balancers, plus an optional cluster tag

## Usage

```hcl
module "network" {
  source = "../../modules/aws-network"

  name         = "multi-cloud-sre"
  environment  = "dev"
  vpc_cidr     = "10.10.0.0/16"
  nat_mode     = "single"
  cluster_name = "multi-cloud-sre-dev"

  tags = { owner = "platform-team" }
}
```

## Subnet layout

For `vpc_cidr = 10.10.0.0/16`:

| Zone | Public | Private |
| --- | --- | --- |
| 1st | `10.10.0.0/24` | `10.10.32.0/19` |
| 2nd | `10.10.1.0/24` | `10.10.64.0/19` |
| 3rd | `10.10.2.0/24` | `10.10.96.0/19` |

The remaining space (`10.10.128.0/17` and the gaps) is unallocated for future use.

## NAT modes

| `nat_mode` | Gateways | Behaviour |
| --- | --- | --- |
| `single` (default) | 1, in the first zone | All private subnets share one gateway. Cheapest; a loss of that zone cuts egress for the others. |
| `per_az` | 3 | Each zone uses its own gateway. Resilient to a zone failure; roughly three times the cost. |
| `none` | 0 | No internet egress from private subnets. Use only with VPC endpoints or for teardown savings. |

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `name` | `string` | n/a | Base name for resources (3-32 characters, lowercase). |
| `environment` | `string` | n/a | One of `dev`, `staging`, `prod`. |
| `vpc_cidr` | `string` | n/a | Private IPv4 range, between `/16` and `/20`. |
| `nat_mode` | `string` | `"single"` | `single`, `per_az` or `none`. |
| `flow_log_retention_days` | `number` | `14` | CloudWatch Logs retention; must be a supported value. |
| `cluster_name` | `string` | `null` | Adds `kubernetes.io/cluster/<name> = shared` to all subnets. |
| `tags` | `map(string)` | `{}` | Additional tags merged onto all resources. |

## Outputs

| Name | Description |
| --- | --- |
| `vpc_id` | VPC ID |
| `vpc_cidr_block` | VPC CIDR block |
| `availability_zones` | Zones used, in the order of the subnet lists |
| `public_subnet_ids` | Public subnet IDs, one per zone |
| `private_subnet_ids` | Private subnet IDs, one per zone |
| `public_route_table_id` | Public route table ID |
| `private_route_table_ids` | Private route table IDs, one per zone |
| `nat_public_ips` | NAT gateway public IPs (empty for `none`) |
| `s3_endpoint_id` | S3 gateway endpoint ID |
| `flow_log_group_name` | CloudWatch log group for flow logs |

## Cost

The NAT gateway is the main cost. At the time of writing a NAT gateway in `eu-north-1` costs about $0.05 per hour (around $35 per month) plus a per-GB processing charge, and each gateway also holds a public IPv4 address billed hourly. `per_az` triples the fixed cost. Flow logs add CloudWatch ingestion and storage charges that grow with traffic; the 14-day default keeps storage small. The VPC, subnets, route tables, internet gateway and S3 gateway endpoint are free. Check current AWS pricing before applying.

For short-lived environments use `nat_mode = "none"` or destroy the stack when idle.

## Tests

Plan-only tests with a mocked provider run without credentials:

```bash
terraform init -backend=false
terraform test
```

They cover the resource counts for each `nat_mode`, the computed subnet CIDRs, Kubernetes tags and every input validation.

## Requirements

Terraform 1.11 or later; AWS provider 6.0 or later.
