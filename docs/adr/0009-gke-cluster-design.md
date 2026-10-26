# ADR-0009: GKE cluster design

- Status: Accepted
- Date: 2026-10-26

## Context

The GCP side of the platform needs a Kubernetes cluster on the network from [ADR-0008](0008-gcp-network-design.md), comparable to the EKS cluster in [ADR-0007](0007-eks-cluster-design.md). It will be created for short periods and destroyed, so defaults must be cheap, while still following current practice for identity, encryption and node hardening.

## Decision

Cluster mode

- A GKE Standard cluster, not Autopilot. The platform exists to practise operating clusters: node pools, upgrades, scheduling, disruption and capacity are part of what is demonstrated and tested, and Autopilot hides them. Autopilot also restricts privileged workloads, host access and some DaemonSets that observability and chaos tooling may need, and prices per pod request, which makes cost harder to compare with EKS. Autopilot remains a reasonable choice for teams that do not want to run nodes.
- The cluster is zonal by default (`europe-north1-a`) because it has a single-zone control plane and nodes, which keeps cost and node count down. A regional cluster, with a highly available control plane and nodes in three zones, is the production choice and is selected by passing a region as `location`.

Network and access

- VPC-native using the pod and service secondary ranges from the network module.
- Nodes are private (no external IPs) and reach the internet through Cloud NAT.
- The control plane keeps a public endpoint so the cluster can be managed without a bastion, but it is limited by `master_authorized_cidrs`, which defaults to empty. With an empty list nothing on the internet can reach it, so operators must add their own `/32`. A private-only endpoint can be selected with `enable_private_endpoint` for stricter environments.
- Google public IP ranges are not given access to the control plane.

Identity

- Workload Identity is enabled with the project pool (`PROJECT.svc.id.goog`) and nodes use the GKE metadata server (`GKE_METADATA`), so pods get short-lived Google credentials bound to Kubernetes service accounts and cannot read node credentials.
- Nodes run as a dedicated service account with only logging, metric writing, monitoring read, resource metadata and Artifact Registry read roles. The default Compute Engine service account, which is broadly privileged by default, is not used.

Dataplane and nodes

- Dataplane V2 (`ADVANCED_DATAPATH`, eBPF-based Cilium) gives built-in Kubernetes network policy enforcement and better network observability.
- Nodes are shielded (secure boot and integrity monitoring), use Container-Optimized OS, and have auto repair and auto upgrade on. Releases follow the `REGULAR` channel by default, with a daily maintenance window.
- One managed node pool uses Spot VMs for non-production, with `e2-standard-2` nodes autoscaling from one to three per zone. Spot capacity can be reclaimed with short notice, so workloads must tolerate node loss, which is also part of the failure exercises. Production uses standard VMs, and may use a mixed set of pools.

Secrets and observability

- Kubernetes secrets are encrypted at the application layer with a Cloud KMS key created by the module, rotated every 90 days, with the GKE service agent granted use of the key. The toggle exists for experiments and should stay on.
- Cloud KMS key rings cannot be deleted, so the module exposes a name suffix for re-creating the cluster after a destroy.
- Logging and monitoring send system components only by default, and managed Prometheus is off, to avoid ingestion cost until the observability phase decides what to collect.

## Consequences

- Cheap and quick to create and destroy; with one zonal cluster the management fee is covered by the free-tier credit.
- A zonal cluster has no control plane availability during zone events or upgrades, and Spot nodes are not suitable for production.
- The default endpoint restriction means a fresh cluster is not reachable from a workstation until a CIDR is supplied; this is deliberate.
- A KMS key ring is left behind after destroy; versions are scheduled for destruction but the ring remains.
- Temporarily, GKE creates a default node pool during cluster creation before it is removed, using the dedicated service account.

## Alternatives considered

- Autopilot: less to operate, but hides the node layer this platform is meant to exercise and constrains some workloads.
- Regional cluster by default: better availability, but three times the nodes and no free-tier credit coverage.
- Fully private endpoint only: strongest posture, but needs a bastion, VPN or in-VPC runner before the first `kubectl` command.
- Default compute service account for nodes: simpler, but over-privileged.
- Node pool service account keys or node-level credentials for workloads: replaced by Workload Identity.
