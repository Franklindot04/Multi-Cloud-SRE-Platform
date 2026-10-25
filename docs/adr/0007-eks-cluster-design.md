# ADR-0007: EKS cluster design

- Status: Accepted
- Date: 2026-10-26

## Context

The AWS side of the platform needs a Kubernetes cluster built on the network from [ADR-0006](0006-aws-network-design.md). The cluster will be created for short periods and destroyed, so the defaults must be cheap, while still following current practice for access, encryption and node hardening.

## Decision

Access

- Authentication mode is `API`, using EKS access entries. The `aws-auth` ConfigMap is not used. Access is managed through the AWS API and Terraform, is auditable, and cannot lock administrators out through a bad ConfigMap edit.
- The creating identity receives admin access through the bootstrap option, and additional administrators are granted `AmazonEKSClusterAdminPolicy` through access entries.

Endpoint

- The private endpoint is always enabled. The public endpoint is enabled by default so the cluster is reachable from a workstation, and is limited by `public_access_cidrs`. The module default is `0.0.0.0/0` to keep it usable out of the box; documentation and the runbook direct operators to restrict it to their own `/32`. The public endpoint can be disabled once access from inside the VPC exists.

Compute

- A single managed node group in the private subnets comes first. It keeps node lifecycle, AMI updates and draining under EKS control with little to operate.
- Karpenter is a later option for just-in-time, consolidated capacity once workloads justify it. It would run on a small managed node group and replace the general node group's scaling role.
- Nodes use Spot by default (`t3.large` and `m5.large`, two to four nodes) because the cluster is non-production and interruption tolerance is part of what the platform demonstrates. Production uses `ON_DEMAND` or a mix.
- A launch template requires IMDSv2 with a hop limit of 1, so pods cannot reach node credentials through the metadata service, and encrypts the root volume.
- Amazon Linux 2023 is the AMI family.

Identity for workloads

- IAM roles for service accounts (IRSA) are used now, through an IAM OIDC provider created without a managed thumbprint. The EKS Pod Identity agent is installed too, so workloads can move to Pod Identity associations without a cluster change. Both mechanisms can coexist.
- The EBS CSI driver uses its own IRSA role. The VPC CNI currently relies on the node role's CNI policy, which is simpler but broader; moving it to a dedicated role is a hardening follow-up.

Add-ons

- `vpc-cni`, `kube-proxy`, `eks-pod-identity-agent`, `coredns` and `aws-ebs-csi-driver` are managed EKS add-ons at the newest version compatible with the cluster, resolved at plan time instead of being hard-coded. Self-managed bootstrap add-ons are disabled. Networking add-ons are installed before the node group, and add-ons that run as Deployments after it.

Secrets and logging

- Kubernetes secrets are envelope-encrypted with a dedicated customer-managed KMS key with rotation enabled. The toggle `enable_secrets_encryption` exists for experiments where the roughly $1 per month key is not wanted; it should stay on otherwise.
- All five control plane log types go to CloudWatch with 14-day retention.

Versions

- The cluster stays on standard support (`upgrade_policy`), which avoids the extended-support surcharge. The root stack defaults to the newest version in standard support (1.37 at the time of writing) and is upgraded deliberately, one minor version at a time.

## Consequences

- Cheap, quick to create and destroy, and consistent with current AWS recommendations.
- Spot interruptions and a two-node footprint mean the cluster is unsuitable for production without changing `capacity_type` and sizing.
- The default public endpoint is open to the internet until restricted. This is an explicit trade-off for ease of first use.
- The cluster needs outbound access from the private subnets, so the network cannot use `nat_mode = "none"` while it exists.
- The nodes' CNI permissions and the single node group are known simplifications to revisit.

## Alternatives considered

- `aws-auth` ConfigMap or both authentication modes: legacy and error-prone.
- Karpenter or EKS Auto Mode from the start: better long-term scaling, but more moving parts and cost than a short-lived learning cluster needs.
- Fargate: removes node management but limits DaemonSets, storage and cost control.
- Pod Identity only: simpler trust policies, but IRSA remains the broadest-supported mechanism across charts today.
- Private-only endpoint: strongest posture, but requires a bastion, VPN or in-VPC runner before the first `kubectl` command.
