# ADR-0008: GCP network design

- Status: Accepted
- Date: 2026-10-26

## Context

The GKE cluster needs a VPC in `europe-north1`. The design should mirror the AWS network where it makes sense ([ADR-0006](0006-aws-network-design.md)), use GCP's native strengths where the two clouds differ, keep the optional Cloud NAT cost switchable, and respect the shared address plan so the clouds can later be connected.

## Decision

Network

- A custom-mode VPC with no auto-created subnets and regional dynamic routing. Every range is chosen explicitly, which is required to keep the address plan authoritative.
- A VPC in GCP is global, so a single regional subnet in `europe-north1` carries the nodes. Additional regions would add subnets to the same VPC.

VPC-native GKE ranges

- GKE runs VPC-native (alias IPs), so pods and services get dedicated secondary ranges on the node subnet rather than routes. This avoids route quotas, makes pod IPs routable inside the VPC, and works with firewall rules and flow logs.
- Ranges are derived from the environment's `/16` with `cidrsubnet`. For `10.20.0.0/16`: nodes `10.20.0.0/20`, services `10.20.16.0/20` and pods `10.20.64.0/18`. This is the allocation ADR-0006 left open for GKE secondary ranges, and keeping them inside the `/16` guarantees they cannot overlap AWS (`10.10.0.0/16` upward) or another GCP environment.
- The module accepts only private `/16` blocks so the derivation is always valid.

Private access and egress

- Private Google access is on, so nodes without external addresses reach Google APIs and Container Registry or Artifact Registry over Google's network.
- Nodes have no external IPs. Outbound internet access (public registries, package mirrors) uses Cloud NAT with auto-allocated addresses and error-only logging.
- Cloud NAT is switchable with `nat_mode` (`enabled` default, `none`). Disabling it also removes the Cloud Router. Unlike AWS, GCP has no per-zone NAT choice to make: Cloud NAT is a regional, managed service.

Firewall posture

- Ingress is closed by default. Rules allow only: traffic from the node, pod and service ranges; Google load balancer health checks (`130.211.0.0/22`, `35.191.0.0/16`); and SSH from the IAP range `35.235.240.0/20`.
- An explicit deny-all ingress rule at the lowest priority (65534) documents the posture and makes it visible in the console, though GCP already denies other ingress implicitly. Egress follows the GCP default of allow.
- Administrative access to nodes goes through Identity-Aware Proxy TCP forwarding. No bastion host and no public SSH.

Observability

- Subnet flow logs use a 5 minute interval and 0.5 sampling by default. Sampling is configurable and zero turns them off, trading visibility against Cloud Logging cost.

## Consequences

- Same shape as the AWS network (private nodes, switchable NAT, flow logs), so both clouds can be operated and compared consistently.
- The pod range limits the cluster to 64 nodes at the GKE default of a `/24` per node; the unallocated space in the `/16` can accommodate growth.
- The firewall rules apply to the whole VPC; narrowing them with network tags or service accounts can follow when more workloads share the network.
- With NAT off, nodes can pull only from Google-hosted registries.

## Alternatives considered

- Auto-mode VPC: simple, but uses fixed ranges that overlap other networks and cannot be planned.
- Route-based (non-VPC-native) GKE: legacy, with quota limits and weaker integration.
- Public nodes with external IPs: no NAT cost, but exposes nodes and conflicts with the private design.
- Shared VPC or hub-and-spoke: appropriate for many projects, unnecessary for one.
- Allowing SSH from a fixed office range: IAP removes the need to maintain addresses and adds identity-based access.
