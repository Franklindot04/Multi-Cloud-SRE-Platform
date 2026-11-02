# Plan-only tests using a mocked AWS provider: no credentials or network access required.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_eks_addon_version" {
    defaults = {
      version = "v1.0.0-eksbuild.1"
    }
  }

  override_resource {
    target = aws_eks_cluster.this
    values = {
      identity = [{
        oidc = [{
          issuer = "https://oidc.eks.eu-north-1.amazonaws.com/id/EXAMPLE0123456789"
        }]
      }]
    }
  }
}

variables {
  cluster_name             = "test-dev"
  environment              = "dev"
  kubernetes_version       = "1.37"
  control_plane_subnet_ids = ["subnet-pub-a", "subnet-pub-b", "subnet-priv-a", "subnet-priv-b"]
  node_subnet_ids          = ["subnet-priv-a", "subnet-priv-b"]
}

run "defaults" {
  command = plan

  assert {
    condition     = aws_eks_cluster.this.access_config[0].authentication_mode == "API" && aws_eks_cluster.this.access_config[0].bootstrap_cluster_creator_admin_permissions == true
    error_message = "The cluster must use API authentication with creator admin bootstrap enabled."
  }

  assert {
    condition     = aws_eks_cluster.this.vpc_config[0].endpoint_private_access == true && aws_eks_cluster.this.vpc_config[0].endpoint_public_access == true
    error_message = "Private endpoint must be on and public endpoint on by default."
  }

  assert {
    condition     = contains(aws_eks_cluster.this.vpc_config[0].public_access_cidrs, "0.0.0.0/0") && length(aws_eks_cluster.this.vpc_config[0].public_access_cidrs) == 1
    error_message = "public_access_cidrs should default to 0.0.0.0/0."
  }

  assert {
    condition     = length(aws_eks_cluster.this.enabled_cluster_log_types) == 5 && aws_cloudwatch_log_group.cluster.retention_in_days == 14
    error_message = "All five log types and 14-day retention are expected by default."
  }

  assert {
    condition     = aws_eks_cluster.this.upgrade_policy[0].support_type == "STANDARD"
    error_message = "Clusters must stay on standard support."
  }

  assert {
    condition     = aws_eks_node_group.default.capacity_type == "SPOT" && toset(aws_eks_node_group.default.instance_types) == toset(["t3.large", "m5.large"])
    error_message = "Node group should default to Spot with t3.large and m5.large."
  }

  assert {
    condition     = aws_eks_node_group.default.scaling_config[0].desired_size == 2 && aws_eks_node_group.default.scaling_config[0].min_size == 1 && aws_eks_node_group.default.scaling_config[0].max_size == 4
    error_message = "Node group should default to 2 desired, 1 minimum and 4 maximum nodes."
  }

  assert {
    condition     = aws_launch_template.node.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be required on nodes."
  }

  assert {
    condition     = length(aws_eks_addon.before_compute) == 3 && length(aws_eks_addon.after_compute) == 2
    error_message = "Five managed add-ons are expected: vpc-cni, kube-proxy, eks-pod-identity-agent, coredns, aws-ebs-csi-driver."
  }

  assert {
    condition     = length(aws_eks_access_entry.admin) == 0 && length(aws_eks_access_policy_association.admin) == 0
    error_message = "No access entries are expected without admin_principal_arns."
  }

  assert {
    condition     = length(aws_kms_key.secrets) == 1 && aws_kms_key.secrets[0].enable_key_rotation == true
    error_message = "A rotating KMS key is expected by default."
  }

  assert {
    condition     = length(aws_eks_cluster.this.encryption_config) == 1
    error_message = "Secrets encryption should be configured by default."
  }
}

run "network_policy_enabled_by_default" {
  command = plan

  assert {
    condition     = jsondecode(aws_eks_addon.before_compute["vpc-cni"].configuration_values).enableNetworkPolicy == "true"
    error_message = "Network policy enforcement must be on in the vpc-cni add-on by default."
  }
}

run "network_policy_disabled" {
  command = plan

  variables {
    enable_network_policy = false
  }

  assert {
    condition     = jsondecode(aws_eks_addon.before_compute["vpc-cni"].configuration_values).enableNetworkPolicy == "false"
    error_message = "The vpc-cni add-on must say enableNetworkPolicy false when the variable is off."
  }
}

run "secrets_encryption_disabled" {
  command = plan

  variables {
    enable_secrets_encryption = false
  }

  assert {
    condition     = length(aws_kms_key.secrets) == 0 && length(aws_kms_alias.secrets) == 0 && length(aws_iam_role_policy.cluster_kms) == 0
    error_message = "No KMS resources are expected when encryption is disabled."
  }

  assert {
    condition     = length(aws_eks_cluster.this.encryption_config) == 0
    error_message = "The cluster must not configure encryption_config when disabled."
  }
}

run "restricted_endpoint" {
  command = plan

  variables {
    public_access_cidrs = ["203.0.113.10/32"]
  }

  assert {
    condition     = contains(aws_eks_cluster.this.vpc_config[0].public_access_cidrs, "203.0.113.10/32") && !contains(aws_eks_cluster.this.vpc_config[0].public_access_cidrs, "0.0.0.0/0")
    error_message = "The restricted CIDR should be applied to the public endpoint."
  }
}

run "admin_access_entries" {
  command = plan

  variables {
    admin_principal_arns = [
      "arn:aws:iam::123456789012:user/alice",
      "arn:aws:iam::123456789012:role/platform-admin",
    ]
  }

  assert {
    condition     = length(aws_eks_access_entry.admin) == 2 && length(aws_eks_access_policy_association.admin) == 2
    error_message = "Each admin principal needs an access entry and a policy association."
  }
}

run "on_demand_capacity" {
  command = plan

  variables {
    capacity_type = "ON_DEMAND"
  }

  assert {
    condition     = aws_eks_node_group.default.capacity_type == "ON_DEMAND"
    error_message = "capacity_type should be passed through."
  }
}

run "rejects_invalid_capacity_type" {
  command = plan

  variables {
    capacity_type = "RESERVED"
  }

  expect_failures = [var.capacity_type]
}

run "rejects_invalid_endpoint_cidr" {
  command = plan

  variables {
    public_access_cidrs = ["203.0.113.10/33"]
  }

  expect_failures = [var.public_access_cidrs]
}

run "rejects_non_cidr_endpoint_entry" {
  command = plan

  variables {
    public_access_cidrs = ["my-office"]
  }

  expect_failures = [var.public_access_cidrs]
}

run "rejects_empty_endpoint_cidrs" {
  command = plan

  variables {
    public_access_cidrs = []
  }

  expect_failures = [var.public_access_cidrs]
}

run "rejects_desired_above_max" {
  command = plan

  variables {
    desired_size = 5
    max_size     = 4
  }

  expect_failures = [var.desired_size]
}

run "rejects_min_above_desired" {
  command = plan

  variables {
    min_size     = 3
    desired_size = 2
    max_size     = 4
  }

  expect_failures = [var.desired_size]
}

run "rejects_max_below_min" {
  command = plan

  variables {
    min_size     = 3
    desired_size = 3
    max_size     = 2
  }

  expect_failures = [var.max_size]
}

run "rejects_negative_min_size" {
  command = plan

  variables {
    min_size = -1
  }

  expect_failures = [var.min_size]
}

run "rejects_invalid_kubernetes_version" {
  command = plan

  variables {
    kubernetes_version = "latest"
  }

  expect_failures = [var.kubernetes_version]
}

run "rejects_unsupported_log_retention" {
  command = plan

  variables {
    log_retention_days = 10
  }

  expect_failures = [var.log_retention_days]
}

run "rejects_invalid_cluster_name" {
  command = plan

  variables {
    cluster_name = "Bad_Name"
  }

  expect_failures = [var.cluster_name]
}

run "rejects_single_node_subnet" {
  command = plan

  variables {
    node_subnet_ids = ["subnet-priv-a"]
  }

  expect_failures = [var.node_subnet_ids]
}

run "rejects_invalid_admin_arn" {
  command = plan

  variables {
    admin_principal_arns = ["alice"]
  }

  expect_failures = [var.admin_principal_arns]
}

run "rejects_small_disk" {
  command = plan

  variables {
    disk_size_gb = 5
  }

  expect_failures = [var.disk_size_gb]
}
