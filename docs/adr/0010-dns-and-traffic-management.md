# ADR-0010: DNS and traffic management

- Status: Accepted
- Date: 2026-10-26

## Context

The platform runs the same workload on EKS and GKE. Users need a single name that reaches both, traffic must be steerable between the clouds (shifting load in normal operation and failing over in a disaster), and the design has to be affordable, since hosted zones and health checks bill monthly. The project does not own a domain yet, and the application load balancers do not exist yet.

## Decision

Zones and delegation

- Route 53 hosts the authoritative public zone for the parent domain (for example `example.com`). It is the zone the registrar points to, and it holds the application record.
- Cloud DNS hosts a delegated subdomain (for example `gke.example.com`) so the GCP side manages its own records, such as the address of its load balancer. The parent zone delegates to Cloud DNS with NS records.
- The stacks stay independent. The GCP stack outputs its name servers and the AWS stack takes them as a plain input variable (`delegated_subdomains`). No stack reads the other's state, which avoids a circular dependency; the apply order is GCP first, then AWS.

Traffic steering

- Steering is done at the DNS level with Route 53 routing policies on a single record (`app.<domain>`), one record per cloud with a set identifier and a short TTL (60 seconds).
- **Weighted** is the default for normal operation: an even split by default, adjustable for gradual shifts, canarying a cloud, or draining one by setting its weight to zero.
- **Failover** is for disaster recovery: one cloud is primary (AWS by default), the other secondary, and Route 53 switches when the primary's health check fails.
- DNS steering has limits. Resolvers and clients may cache answers beyond the TTL, so changes and failover take effect gradually, typically within minutes but not instantly. DNS balances connections per resolver, not requests, cannot see application load, and cannot shift traffic away from a failing endpoint faster than health check detection plus caching allows. Where faster or finer control is needed, a global load balancer or anycast front end would be the next step.

Health checks

- Route 53 health checks probe an HTTPS `/healthz` path on each endpoint every 30 seconds and mark it unhealthy after 3 consecutive failures, so detection takes about 90 seconds plus record caching. The path, port, protocol, threshold and interval are configurable per endpoint, and a 10 second interval is allowed at extra cost.
- The health endpoint should reflect the ability to serve traffic (for example dependencies reachable), not just that the process is up. Under the failover policy the primary's health check is what triggers the switch; without health checks, failover cannot detect failure, so they can be switched off only for cost experiments.
- Endpoints are either host names (CNAME) or IP addresses (A). Because a CNAME cannot coexist with an A record at the same name, both endpoints must use the same kind. A cloud that only has an IP publishes a host name for it in its own zone.

Off until a domain exists

- Everything is disabled by default. An empty `domain_name` (AWS) or `dns_name` (GCP) creates nothing, and a zone without endpoints creates no records or health checks. This keeps the repository free of recurring DNS cost and of placeholder domains until a real domain is registered and the load balancers exist.

## Consequences

- Both clouds can serve the same name and be steered or failed over without a third-party service.
- Failover and weight changes are bounded by caching and health check timing, which the failure exercises measure.
- Route 53 is the single authoritative entry point; losing it affects the whole name, so the parent zone is a critical dependency (mitigated, if ever needed, by a secondary DNS provider).
- Recurring cost starts as soon as a domain is set: a hosted zone, a Cloud DNS zone and health checks, all small but non-zero.
- Two applies in a fixed order are needed the first time delegation is set up.

## Alternatives considered

- Cloud DNS as the parent zone: equivalent, but Route 53 has built-in health-checked failover and weighted routing across clouds.
- Latency or geolocation routing: useful for global users, but the goal here is controllable weights and disaster recovery from a single region pair.
- A global load balancer or a third-party traffic manager: faster and request-level steering, but extra cost, a new dependency and a new single point of failure.
- Remote state sharing between stacks to pass name servers: convenient, but creates coupling and ordering constraints that a plain input avoids.
- Creating placeholder zones for an example domain: generates cost and confusion without a real domain.
