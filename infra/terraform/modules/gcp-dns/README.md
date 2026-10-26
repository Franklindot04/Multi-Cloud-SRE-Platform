# gcp-dns

A Cloud DNS public managed zone for a subdomain that is delegated from a parent zone, typically one hosted in Route 53 ([`aws-dns`](../aws-dns)). Design rationale is in [ADR-0010](../../../../docs/adr/0010-dns-and-traffic-management.md).

**Off by default.** With an empty `dns_name` the module creates nothing and costs nothing.

## What it creates

- A public Cloud DNS managed zone for `dns_name` (a trailing dot is added if missing), with labels
- DNSSEC, off by default and switchable with `enable_dnssec`

The module creates only the zone. Records (for example an A record for the GKE load balancer) are added separately when the workloads exist.

## Usage

```hcl
module "dns" {
  source = "../../modules/gcp-dns"

  project_id  = "my-project-id"
  name        = "multi-cloud-sre"
  environment = "dev"
  dns_name    = "gke.example.com"
}
```

The `name_servers` output feeds the AWS side:

```hcl
module "dns" {
  source = "../../modules/aws-dns"
  # ...
  delegated_subdomains = { gke = var.gcp_name_servers }
}
```

## Delegation walkthrough

1. Apply the GCP stack with `dns_name = "gke.example.com"` and note the `dns_name_servers` output (for example `ns-cloud-a1.googledomains.com.`).
2. Pass those name servers to the AWS stack as `delegated_subdomains = { gke = [...] }`, together with `domain_name = "example.com"`. This creates the NS record `gke.example.com` in the Route 53 parent zone.
3. Point the registrar at the Route 53 name servers.
4. Check delegation with `dig NS gke.example.com`, which should return the Cloud DNS name servers once the parent zone is live.

If DNSSEC is enabled, also add the zone's DS record at the parent zone; otherwise validating resolvers fail to resolve the subdomain. Leave DNSSEC off until delegation works.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `project_id` | `string` | n/a | GCP project ID. |
| `name` | `string` | n/a | Base name (3-32 characters, lowercase). |
| `environment` | `string` | n/a | One of `dev`, `staging`, `prod`. |
| `dns_name` | `string` | `""` | Zone DNS name such as `gke.example.com`; empty creates nothing. |
| `enable_dnssec` | `bool` | `false` | Sign the zone with DNSSEC. |
| `force_destroy` | `bool` | `false` | Allow destroying the zone when it still has unmanaged records. |
| `labels` | `map(string)` | `{}` | Additional labels. |

## Outputs

| Name | Description |
| --- | --- |
| `zone_name` | Name of the managed zone (null when disabled) |
| `zone_id` | ID of the managed zone (null when disabled) |
| `dns_name` | Zone DNS name with a trailing dot (null when disabled) |
| `name_servers` | Zone name servers, for delegation from the parent zone (empty when disabled) |

## Cost

Figures are approximate and must be checked against current Google Cloud pricing before applying.

- **Managed zone:** about $0.20 per month per zone for the first 25 zones.
- **Queries:** about $0.40 per million queries. Negligible at this scale.
- DNSSEC adds no separate charge. The domain registration is separate.

## Tests

Plan-only tests with a mocked provider run without credentials:

```bash
terraform init -backend=false
terraform test
```

They cover the disabled default, the enabled zone, trailing dot handling, DNSSEC, labels and every input validation.

## Requirements

Terraform 1.11 or later; Google provider 7.0 or later. The Cloud DNS API (`dns.googleapis.com`) must be enabled in the project.
