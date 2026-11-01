# aws-eks

An Amazon EKS cluster with a managed node group, managed add-ons and IAM roles for service accounts (IRSA). Design rationale is in [ADR-0007](../../../../docs/adr/0007-eks-cluster-design.md). It is designed to sit on the [`aws-network`](../aws-network) module.

## What it creates

- EKS cluster with API-only authentication (EKS access entries, no `aws-auth` ConfigMap)
- Cluster IAM role; the EKS-managed cluster security group is left at its defaults
- Private API endpoint always on; public endpoint on by default and restricted by `public_access_cidrs`
- Control plane logs (`api`, `audit`, `authenticator`, `controllerManager`, `scheduler`) to a CloudWatch log group with configurable retention
- Secrets encryption with a dedicated KMS key (rotation on), switchable with `enable_secrets_encryption`
- Access entries and cluster admin policy associations for `admin_principal_arns`
- One managed node group (Spot by default) with a launch template that requires IMDSv2, an encrypted gp3 root volume, and a node role with the standard managed policies plus SSM access
- IAM OIDC provider for IRSA (no thumbprint is managed)
- Managed add-ons at the newest version compatible with the cluster: `vpc-cni`, `kube-proxy`, `eks-pod-identity-agent`, `coredns` and `aws-ebs-csi-driver` (the last with its own IRSA role)
- Network policy enforcement in the `vpc-cni` add-on (`enable_network_policy`, on by default), set through the add-on's configuration values
- Clusters are pinned to standard support, which avoids the extended-support surcharge

## Usage

```hcl
module "eks" {
  source = "../../modules/aws-eks"

  cluster_name       = "multi-cloud-sre-dev"
  environment        = "dev"
  kubernetes_version = "1.37"

  control_plane_subnet_ids = concat(module.network.public_subnet_ids, module.network.private_subnet_ids)
  node_subnet_ids          = module.network.private_subnet_ids

  public_access_cidrs  = ["203.0.113.10/32"] # your own address
  admin_principal_arns = ["arn:aws:iam::111122223333:role/platform-admin"]
}
```

The network must keep outbound access for the nodes: do not use `nat_mode = "none"` while the cluster exists, as nodes need to reach ECR, STS and the EKS API to join and pull images.

## Restrict the public endpoint

The public API endpoint defaults to `0.0.0.0/0` so the module works out of the box. Authentication is still required, but the endpoint is then exposed to the whole internet. Set `public_access_cidrs` to your own address as a `/32` (for example `["203.0.113.10/32"]`) before applying anywhere that matters, or set `endpoint_public_access = false` and reach the cluster from inside the VPC.

## Access

The module uses EKS access entries only. The identity that creates the cluster is an admin when `bootstrap_cluster_creator_admin_permissions` is true (the default). Add other administrators with `admin_principal_arns`. For IAM roles, use the plain role ARN without a path; for roles created by AWS IAM Identity Center, strip the `aws-reserved/sso.amazonaws.com/` path from the ARN.

## IRSA example

The module outputs `oidc_provider_arn` and `oidc_issuer_host`. A role for a workload's service account looks like this:

```hcl
data "aws_iam_policy_document" "app_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:orders:orders-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "orders" {
  name               = "orders-irsa"
  assume_role_policy = data.aws_iam_policy_document.app_assume.json
}
```

Annotate the Kubernetes service account with `eks.amazonaws.com/role-arn: <role ARN>`. The EKS Pod Identity agent is installed as well, so workloads can use Pod Identity associations instead where that is preferred.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `cluster_name` | `string` | n/a | Cluster name and resource prefix (3-40 characters, lowercase). |
| `environment` | `string` | n/a | One of `dev`, `staging`, `prod`. |
| `kubernetes_version` | `string` | n/a | Minor version such as `"1.37"`. Pick one in standard support. |
| `control_plane_subnet_ids` | `list(string)` | n/a | At least two subnets for the control plane (public and private may be mixed). |
| `node_subnet_ids` | `list(string)` | n/a | At least two private subnets for nodes. |
| `endpoint_public_access` | `bool` | `true` | Enable the public API endpoint. The private endpoint is always on. |
| `public_access_cidrs` | `list(string)` | `["0.0.0.0/0"]` | CIDRs allowed to reach the public endpoint. Restrict to your own `/32`. |
| `admin_principal_arns` | `list(string)` | `[]` | IAM user or role ARNs granted cluster admin. |
| `bootstrap_cluster_creator_admin_permissions` | `bool` | `true` | Give the creating identity admin access. |
| `enable_secrets_encryption` | `bool` | `true` | Encrypt secrets with a dedicated KMS key. |
| `kms_deletion_window_days` | `number` | `7` | Pending-deletion window for the KMS key (7-30). |
| `enabled_log_types` | `list(string)` | all five | Control plane log types to ship. |
| `log_retention_days` | `number` | `14` | Control plane log retention; must be a supported CloudWatch value. |
| `instance_types` | `list(string)` | `["t3.large", "m5.large"]` | Node instance types. |
| `capacity_type` | `string` | `"SPOT"` | `SPOT` or `ON_DEMAND`. |
| `ami_type` | `string` | `"AL2023_x86_64_STANDARD"` | Node AMI type (x86 or Arm Amazon Linux 2023). |
| `min_size` / `desired_size` / `max_size` | `number` | `1` / `2` / `4` | Node group size; `min <= desired <= max`. |
| `disk_size_gb` | `number` | `30` | Root volume size in GiB (20-500). |
| `enable_network_policy` | `bool` | `true` | Sets `enableNetworkPolicy` in the `vpc-cni` add-on configuration. Needs add-on 1.14.0-eksbuild.3 or later (the newest compatible version is always used), Kubernetes 1.25 or later and nodes with kernel 5.10 or later (Amazon Linux 2023 qualifies). Without it, NetworkPolicy objects are accepted and not enforced. |
| `node_labels` | `map(string)` | `{}` | Kubernetes labels for the nodes. |
| `tags` | `map(string)` | `{}` | Additional tags. |

## Outputs

| Name | Description |
| --- | --- |
| `cluster_name` | Cluster name |
| `cluster_arn` | Cluster ARN |
| `cluster_endpoint` | API server endpoint |
| `cluster_certificate_authority_data` | Base64 certificate authority data |
| `cluster_security_group_id` | EKS-managed cluster security group |
| `oidc_provider_arn` | IAM OIDC provider ARN |
| `oidc_issuer` | OIDC issuer URL |
| `oidc_issuer_host` | OIDC issuer without `https://`, for trust policy conditions |
| `node_role_arn` | Node IAM role ARN |
| `node_group_name` | Managed node group name |
| `kms_key_arn` | Secrets KMS key ARN (null when encryption is off) |

## Cost

All figures are approximate and must be checked against current AWS pricing before applying.

- **Control plane:** about $0.10 per hour (roughly $73 per month) per cluster on standard support. It bills whenever the cluster exists, whatever the node count. Extended support costs several times more; the module avoids it.
- **Nodes:** `t3.large` and `m5.large` On-Demand cost on the order of $0.10 per hour each in `eu-north-1`. Spot is typically 60-70% cheaper but can be interrupted at short notice, which suits non-production. Two nodes is the default.
- **KMS key:** about $1 per month, prorated, plus a small per-request charge. A destroyed key bills until its deletion window (7 days by default) ends.
- **Other:** each node's gp3 volume, CloudWatch Logs ingestion and storage for control plane logs, and the NAT gateway from the network module.

For a short-lived environment, expect a few dollars per day with the defaults. Destroy the stack when not in use.

## Tests

Plan-only tests with a mocked provider run without credentials:

```bash
terraform init -backend=false
terraform test
```

They cover the defaults, the network policy setting, the secrets encryption toggle, admin access entries, and the validation of the endpoint CIDRs, capacity type, node group sizes and other inputs.

## Requirements

Terraform 1.11 or later; AWS provider 6.0 or later.
