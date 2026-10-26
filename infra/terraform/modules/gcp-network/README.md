# gcp-network

VPC networking for a VPC-native GKE cluster on GCP: a custom-mode VPC, one regional node subnet with secondary ranges for pods and services, private Google access, flow logs, optional Cloud NAT and a deny-by-default firewall posture. Design rationale is in [ADR-0008](../../../../docs/adr/0008-gcp-network-design.md); the address plan is in [ADR-0006](../../../../docs/adr/0006-aws-network-design.md).

## What it creates

- Custom-mode VPC (no auto-created subnets) with regional dynamic routing
- One regional subnet for nodes, with private Google access and two secondary ranges (pods, services)
- Subnet flow logs, 5 minute aggregation, sampling configurable (default 0.5; set 0 to turn off)
- Cloud Router and Cloud NAT (auto-allocated IPs, error-only logging) when `nat_mode = "enabled"`
- Firewall rules:
  - allow internal traffic from the node, pod and service ranges (TCP, UDP, ICMP)
  - allow SSH only from the IAP range `35.235.240.0/20`
  - allow load balancer health checks from `130.211.0.0/22` and `35.191.0.0/16`
  - explicit deny-all ingress at priority 65534

Network resources in GCP do not support labels, so this module takes no tags input. Provider default labels apply to resources that do.

## Usage

```hcl
module "network" {
  source = "../../modules/gcp-network"

  project_id  = "my-project-id"
  region      = "europe-north1"
  name        = "multi-cloud-sre"
  environment = "dev"
  vpc_cidr    = "10.20.0.0/16"
  nat_mode    = "enabled"
}
```

A GKE module consumes `subnet_name`, `pods_range_name` and `services_range_name` as `ip_allocation_policy`'s `cluster_secondary_range_name` and `services_secondary_range_name`.

## Naming

Every resource is named `<name>-<environment>` plus a suffix, so with `name = "multi-cloud-sre"` and `environment = "dev"`:

| Resource | Name |
| --- | --- |
| VPC network, Cloud Router, Cloud NAT | `multi-cloud-sre-dev` |
| Node subnet | `multi-cloud-sre-dev-nodes` |
| Secondary ranges | `multi-cloud-sre-dev-pods`, `multi-cloud-sre-dev-services` |
| Firewall rules | `multi-cloud-sre-dev-allow-internal`, `-allow-iap-ssh`, `-allow-health-checks`, `-deny-all-ingress` |

Pass the project name, not a name that already ends in the environment, or the environment appears twice.

## Address ranges

All ranges are carved from the VPC /16 with `cidrsubnet`, so they always lie inside it and never overlap each other. For `vpc_cidr = 10.20.0.0/16`:

| Range | Derivation | CIDR | Addresses |
| --- | --- | --- | --- |
| Nodes (subnet primary) | `/20`, block 0 | `10.20.0.0/20` | 4,096 |
| Services (secondary) | `/20`, block 1 | `10.20.16.0/20` | 4,096 |
| Pods (secondary) | `/18`, block 1 | `10.20.64.0/18` | 16,384 |

`10.20.32.0/19` and `10.20.128.0/17` remain unallocated for future use. With the GKE default of a /24 pod range per node, the pod range supports 64 nodes.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `project_id` | `string` | n/a | GCP project ID. |
| `region` | `string` | n/a | Region for the subnet, router and NAT. |
| `name` | `string` | n/a | Base name (3-40 characters, lowercase), typically the project name. Resources are named `<name>-<environment>`. |
| `environment` | `string` | n/a | One of `dev`, `staging`, `prod`. |
| `vpc_cidr` | `string` | n/a | Private `/16` the subnet and secondary ranges are derived from. |
| `nat_mode` | `string` | `"enabled"` | `enabled` or `none`. |
| `flow_log_sampling` | `number` | `0.5` | Fraction of packets sampled, 0 to 1; 0 turns flow logs off. |

## Outputs

| Name | Description |
| --- | --- |
| `network_id` | VPC network ID |
| `network_name` | VPC network name |
| `subnet_id` | Node subnet ID |
| `subnet_name` | Node subnet name |
| `pods_range_name` | Secondary range name for GKE pods |
| `services_range_name` | Secondary range name for GKE services |
| `router_name` | Cloud Router name (null when `nat_mode = "none"`) |
| `nat_name` | Cloud NAT name (null when `nat_mode = "none"`) |
| `node_cidr`, `pods_cidr`, `services_cidr` | The derived CIDR ranges |

## Cost

Figures are approximate and must be checked against current Google Cloud pricing before applying.

- **Cloud NAT** is the main cost. It bills per VM using the gateway per hour (about $0.0014, capped at 32 VMs, so a small cluster costs a few cents per hour), plus about $0.045 per GiB of data processed, plus charges for the external IP addresses the gateway uses. Turn it off with `nat_mode = "none"` when nodes do not need outbound internet access; private Google access still reaches Google APIs. GKE nodes normally need NAT to pull images from non-Google registries.
- **Flow logs** are billed as Cloud Logging ingestion and storage. The 0.5 default samples half the packets; lower `flow_log_sampling` or set it to 0 to cut cost.
- The VPC, subnet, Cloud Router and firewall rules are free.

## Tests

Plan-only tests with a mocked provider run without credentials:

```bash
terraform init -backend=false
terraform test
```

They cover the default resources, `nat_mode = "none"`, the derived ranges (for two different CIDRs), flow log sampling and every input validation.

## Requirements

Terraform 1.11 or later; Google provider 7.0 or later. The Compute Engine API must be enabled in the project.
