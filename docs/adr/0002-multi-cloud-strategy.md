# ADR-0002: Multi-cloud strategy

- Status: Accepted
- Date: 2026-10-25

## Context

The platform is meant to demonstrate operating workloads across more than one cloud provider, including failover between them. We need a strategy that provides real multi-cloud learning without pretending that providers are interchangeable or building an abstraction layer that hides useful features.

## Decision

- Run one managed Kubernetes cluster per cloud: Amazon EKS on AWS and Google GKE on GCP.
- Treat Kubernetes and open standards (Helm, OpenTelemetry, Prometheus, OCI images) as the portability boundary.
- Keep the same application set and configuration on both clusters, with per-cloud overlays only where required.
- Use native cloud services for what is inherently provider-specific (networking, identity, load balancing, managed storage) and isolate them in cloud-prefixed Terraform modules.
- Operate the clusters in an active-active posture for stateless services, with DNS-based traffic routing and health checks. Stateful dependencies are initially single-homed per cloud, and cross-cloud data replication is out of scope for early phases.
- Use workload identity federation rather than long-lived credentials for CI and in-cluster access.

## Consequences

- Teaches real provider differences and enables cross-cloud failure exercises.
- Doubles some operational and cost overhead; budgets and teardown automation are required.
- Cross-cloud state consistency is deliberately limited, which constrains which failure scenarios are realistic.
- A thin abstraction in modules and charts is needed, and it must be kept honest rather than lowest-common-denominator.

## Alternatives considered

- Single cloud with multiple regions: simpler, but does not exercise provider diversity.
- Cloud-agnostic abstraction frameworks (for example Crossplane as the primary layer): adds a control plane to run and learn, and obscures provider details; may be revisited.
- Self-managed Kubernetes on VMs: more control but unnecessary operational burden for the goals.
