data "aws_partition" "current" {}

locals {
  name_prefix = var.cluster_name

  tags = merge(var.tags, {
    environment  = var.environment
    "managed-by" = "terraform"
  })

  partition = data.aws_partition.current.partition

  oidc_issuer_host = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")

  # Installed before nodes exist: nodes need the CNI and kube-proxy to become Ready.
  addons_before_compute = toset(["vpc-cni", "kube-proxy", "eks-pod-identity-agent"])

  # Installed after the node group: these run as Deployments and need nodes to schedule onto.
  addons_after_compute = {
    "coredns"            = null
    "aws-ebs-csi-driver" = aws_iam_role.ebs_csi.arn
  }
}

# Add-on versions: the newest build compatible with the cluster version, looked up at plan time.
data "aws_eks_addon_version" "this" {
  for_each = setunion(local.addons_before_compute, toset(keys(local.addons_after_compute)))

  addon_name         = each.key
  kubernetes_version = var.kubernetes_version
  most_recent        = true
}

# --- Cluster IAM role ---

resource "aws_iam_role" "cluster" {
  name = "${local.name_prefix}-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# --- Secrets encryption ---

resource "aws_kms_key" "secrets" {
  count = var.enable_secrets_encryption ? 1 : 0

  description             = "Envelope encryption of Kubernetes secrets for ${var.cluster_name}"
  enable_key_rotation     = true
  deletion_window_in_days = var.kms_deletion_window_days

  tags = merge(local.tags, { Name = "${local.name_prefix}-secrets" })
}

resource "aws_kms_alias" "secrets" {
  count = var.enable_secrets_encryption ? 1 : 0

  name          = "alias/${local.name_prefix}-secrets"
  target_key_id = aws_kms_key.secrets[0].key_id
}

resource "aws_iam_role_policy" "cluster_kms" {
  count = var.enable_secrets_encryption ? 1 : 0

  name = "use-secrets-key"
  role = aws_iam_role.cluster.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["kms:Encrypt", "kms:Decrypt", "kms:ListGrants", "kms:DescribeKey"]
      Resource = aws_kms_key.secrets[0].arn
    }]
  })
}

# --- Control plane logging ---

resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days

  tags = local.tags
}

# --- Cluster ---

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  enabled_cluster_log_types = var.enabled_log_types

  # Add-ons are managed explicitly below instead of being bootstrapped by EKS.
  bootstrap_self_managed_addons = false

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = var.bootstrap_cluster_creator_admin_permissions
  }

  vpc_config {
    subnet_ids              = var.control_plane_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.public_access_cidrs
  }

  # Stay on standard support; extended support is billed at a much higher hourly rate.
  upgrade_policy {
    support_type = "STANDARD"
  }

  dynamic "encryption_config" {
    for_each = var.enable_secrets_encryption ? [1] : []

    content {
      resources = ["secrets"]

      provider {
        key_arn = aws_kms_key.secrets[0].arn
      }
    }
  }

  tags = local.tags

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_iam_role_policy.cluster_kms,
    aws_cloudwatch_log_group.cluster,
  ]
}

# --- Access entries (API authentication mode) ---

resource "aws_eks_access_entry" "admin" {
  for_each = toset(var.admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"

  tags = local.tags
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = aws_eks_access_entry.admin

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# --- OIDC provider for IAM roles for service accounts ---
# No thumbprint is configured: AWS validates the issuer against its trusted CA library.

resource "aws_iam_openid_connect_provider" "this" {
  url            = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list = ["sts.amazonaws.com"]

  tags = merge(local.tags, { Name = "${local.name_prefix}-irsa" })
}

# --- Node IAM role ---

resource "aws_iam_role" "node" {
  name = "${local.name_prefix}-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    "AmazonEC2ContainerRegistryReadOnly",
    "AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.key}"
}

# --- Launch template: IMDSv2 required, encrypted gp3 root volume ---

resource "aws_launch_template" "node" {
  name_prefix = "${local.name_prefix}-node-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.disk_size_gb
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = "${local.name_prefix}-node" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.tags, { Name = "${local.name_prefix}-node" })
  }

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

# --- Add-ons that must exist before nodes ---

resource "aws_eks_addon" "before_compute" {
  for_each = local.addons_before_compute

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = data.aws_eks_addon_version.this[each.key].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = local.tags
}

# --- Managed node group ---

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${local.name_prefix}-default"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.node_subnet_ids

  capacity_type  = var.capacity_type
  instance_types = var.instance_types
  ami_type       = var.ami_type
  labels         = var.node_labels

  scaling_config {
    desired_size = var.desired_size
    min_size     = var.min_size
    max_size     = var.max_size
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  tags = local.tags

  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_eks_addon.before_compute,
  ]
}

# --- EBS CSI driver role (IRSA) ---

resource "aws_iam_role" "ebs_csi" {
  name = "${local.name_prefix}-ebs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.this.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer_host}:aud" = "sts.amazonaws.com"
          "${local.oidc_issuer_host}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
        }
      }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# --- Add-ons that need nodes ---

resource "aws_eks_addon" "after_compute" {
  for_each = local.addons_after_compute

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = data.aws_eks_addon_version.this[each.key].version
  service_account_role_arn    = each.value
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = local.tags

  depends_on = [
    aws_eks_node_group.default,
    aws_iam_role_policy_attachment.ebs_csi,
  ]
}
