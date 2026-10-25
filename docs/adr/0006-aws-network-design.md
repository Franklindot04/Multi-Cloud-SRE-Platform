# ADR-0006: AWS network design

- Status: Accepted
- Date: 2026-10-25

## Context

The EKS cluster and its supporting services need a VPC. The design has to balance resilience against cost (the NAT gateway is the dominant fixed cost), leave room for Kubernetes pod IPs, and avoid address overlap with the GCP side so that private connectivity between the clouds stays possible later.

## Decision

Topology

- One VPC per environment in `eu-north-1`, built by the `aws-network` module.
- Three availability zones, taken from the regular zones the region reports as available (local and opt-in zones are excluded).
- One public and one private subnet per zone. Public subnets are `/24`s that host load balancers and NAT gateways. Private subnets are `/19`s that host nodes and pods; with the AWS VPC CNI, pods consume VPC addresses, so private subnets are deliberately large.
- Workloads run in private subnets. Public subnets hold only load balancers and NAT gateways.
- Subnets carry the Kubernetes role tags (`kubernetes.io/role/elb`, `kubernetes.io/role/internal-elb`) and, once a cluster exists, the `kubernetes.io/cluster/<name>` shared tag.

Egress and cost

- NAT is controlled by `nat_mode`. The default is `single`: one NAT gateway shared by all zones, which keeps the fixed cost to one gateway. `per_az` gives a gateway per zone for production-grade zone isolation, and `none` removes egress entirely.
- The single gateway is a known trade-off: a failure of its zone interrupts outbound traffic from the other zones. This is acceptable for dev and for early phases, and `per_az` is the setting for production.

Endpoints

- An S3 gateway endpoint is attached to every route table. It is free and keeps S3 traffic (image layers, state, logs) off the NAT gateway. Interface endpoints (ECR, STS, CloudWatch and similar) cost per hour per zone and are deferred until the traffic justifies them. DynamoDB would use a gateway endpoint as well if it is introduced.

Observability and hardening

- VPC flow logs for all traffic go to CloudWatch Logs with 14-day retention by default.
- The default security group has all rules removed; workloads use explicit security groups.

Address plan

| Cloud | Range | Notes |
| --- | --- | --- |
| AWS | `10.10.0.0/16` to `10.19.0.0/16` | `10.10.0.0/16` for the first environment (dev); further environments take the next `/16` |
| GCP | `10.20.0.0/16` to `10.29.0.0/16` | `10.20.0.0/16` for the first environment; GKE pod and service secondary ranges are allocated separately and must not overlap anything in this table |
| Reserved | `10.30.0.0/16` and above | Future use (additional regions, shared services, on-premises) |

Each environment uses a distinct `/16`, so environments within and across clouds never overlap. The module accepts only private ranges between `/16` and `/20`.

## Consequences

- Cost stays low by default; production hardening is a single variable.
- Large private subnets avoid IP exhaustion with the VPC CNI, at the price of using a large share of the `/16`.
- The documented allocation lets VPN or interconnect between AWS and GCP be added without renumbering.
- Interface endpoints are not provisioned, so image pulls and AWS API calls from private subnets go through NAT until they are added.

## Alternatives considered

- NAT gateway per zone by default: more resilient but triples the largest fixed cost for a learning platform.
- NAT instances: cheaper, but they need patching and scaling and add an operational burden not worth the saving.
- Two zones: cheaper, but three is the standard for quorum-based and spread workloads and matches the failure exercises planned.
- Custom networking or a secondary pod CIDR (100.64.0.0/10): avoids private address consumption, at the cost of added CNI configuration. It can be adopted later if address space becomes tight.
- IPv6-only or dual-stack: valuable, but out of scope for the first iteration.
