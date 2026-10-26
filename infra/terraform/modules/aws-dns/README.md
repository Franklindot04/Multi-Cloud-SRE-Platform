# aws-dns

A Route 53 public hosted zone, optional delegation of subdomains to another DNS provider, and DNS-level traffic steering between an AWS and a GCP endpoint with health checks. Design rationale is in [ADR-0010](../../../../docs/adr/0010-dns-and-traffic-management.md).

**Everything is off by default.** With an empty `domain_name` the module creates nothing and costs nothing. With a domain but no `endpoints` it creates only the hosted zone (and any delegations).

## What it creates

| Resource | Created when |
| --- | --- |
| Public hosted zone for `domain_name` | `domain_name` is set |
| NS records delegating each entry of `delegated_subdomains` | `domain_name` is set and entries are given |
| One health check per endpoint | `domain_name` and `endpoints` are set and `enable_health_checks` is true |
| One application record per endpoint (`app.<domain>`) | `domain_name` and `endpoints` are set |

Each application record has a set identifier (`aws` or `gcp`), a short TTL (default 60 seconds) and a routing policy:

- `weighted` (default): traffic is split by `weights` (default 50 and 50). Use it for normal operation and gradual shifts.
- `failover`: `primary_cloud` (default `aws`) serves traffic and the other cloud takes over when the primary's health check fails. Use it for disaster recovery.

An `fqdn` endpoint creates a CNAME record; an `ip` endpoint creates an A record. All endpoints must use the same kind, because a CNAME cannot share a name with an A record. If one cloud only has an IP address, publish a host name for it (for example an A record `lb.gke.example.com` in the Cloud DNS zone) and use that as its `fqdn`.

DNS steering is limited by caching. Resolvers and clients may hold answers for longer than the TTL, so a failover or weight change is not instant, and DNS cannot steer individual requests.

## Usage

```hcl
module "dns" {
  source = "../../modules/aws-dns"

  name        = "multi-cloud-sre"
  environment = "dev"
  domain_name = "example.com"

  delegated_subdomains = {
    gke = ["ns-cloud-a1.googledomains.com.", "ns-cloud-a2.googledomains.com.", "ns-cloud-a3.googledomains.com.", "ns-cloud-a4.googledomains.com."]
  }

  routing_policy = "weighted"

  endpoints = {
    aws = { fqdn = "my-alb-123456.eu-north-1.elb.amazonaws.com" }
    gcp = { fqdn = "lb.gke.example.com" }
  }
}
```

## Delegation walkthrough

The parent zone lives in Route 53; a subdomain (for example `gke.example.com`) is delegated to Cloud DNS so the GCP side can manage its own records.

1. Apply the GCP stack with `dns_name = "gke.example.com"`. The [`gcp-dns`](../gcp-dns) module creates the zone and outputs its `name_servers`.
2. Apply the AWS stack with `domain_name = "example.com"` and `delegated_subdomains = { gke = [<the name servers from step 1>] }`. The module creates the hosted zone and an NS record for `gke.example.com`. Take the `name_servers` output of this stack.
3. At your domain registrar, set the domain's name servers to the Route 53 `name_servers`. If the domain is registered in Route 53, update the registered domain's name servers to match the hosted zone.
4. Add records in the Cloud DNS zone as workloads come up, for example an A record `lb.gke.example.com` for the GCP load balancer, and add the endpoints to `endpoints` once the load balancers exist.

The stacks never reference each other: the GCP name servers are passed to the AWS stack as a plain input, so there is no circular dependency. See the [global DNS runbook](../../../../docs/runbooks/global-dns.md) for the full order.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `name` | `string` | n/a | Base name (3-32 characters, lowercase). |
| `environment` | `string` | n/a | One of `dev`, `staging`, `prod`. |
| `domain_name` | `string` | `""` | Domain for the hosted zone; empty creates nothing. |
| `delegated_subdomains` | `map(list(string))` | `{}` | Subdomain label to name servers; creates NS records. |
| `endpoints` | `map(object)` | `{}` | Endpoints keyed `aws` and `gcp`, each with `fqdn` or `ip`, and optional `port` (443), `protocol` (`HTTPS`, `HTTP` or `TCP`), `path` (`/healthz`), `failure_threshold` (3, 1-10) and `request_interval` (30, or 10). |
| `enable_health_checks` | `bool` | `true` | Create and attach a health check per endpoint. |
| `app_hostname` | `string` | `"app"` | Host label of the application record. |
| `routing_policy` | `string` | `"weighted"` | `weighted` or `failover`. |
| `weights` | `object` | `{ aws = 50, gcp = 50 }` | Weights for the weighted policy (0-255, not both zero). |
| `primary_cloud` | `string` | `"aws"` | Primary under the failover policy. |
| `record_ttl` | `number` | `60` | TTL in seconds for the application records. |
| `tags` | `map(string)` | `{}` | Additional tags. |

## Outputs

| Name | Description |
| --- | --- |
| `zone_id` | Hosted zone ID (null when no domain is set) |
| `name_servers` | Hosted zone name servers to set at the registrar (empty when no domain is set) |
| `health_check_ids` | Health check IDs keyed by cloud |
| `app_fqdn` | Fully qualified application name (null when no domain is set) |

## Cost

Figures are approximate and must be checked against current AWS pricing before applying. All of it is off while `domain_name` is empty.

- **Hosted zone:** about $0.50 per month per zone, billed from creation (a zone deleted within 12 hours is not charged).
- **Health checks:** about $0.50 per month for a basic check on an AWS endpoint and about $0.75 for one on a non-AWS endpoint, plus roughly $1.00 each for HTTPS (the default) and for the 10 second interval. Two HTTPS checks therefore cost a few dollars per month. Set `enable_health_checks = false` to remove them, at the price of failover that cannot detect failures.
- **Queries:** about $0.40 per million standard queries and about $0.60 per million for weighted and failover (policy) queries. Negligible at this scale.
- **Domain registration** is separate, roughly $10-15 per year for common domains.

## Tests

Plan-only tests with a mocked provider run without credentials:

```bash
terraform init -backend=false
terraform test
```

They cover the disabled default, the enabled zone, weighted and failover policies, A and CNAME records, health checks, delegation records and every input validation.

## Requirements

Terraform 1.11 or later; AWS provider 6.0 or later.
