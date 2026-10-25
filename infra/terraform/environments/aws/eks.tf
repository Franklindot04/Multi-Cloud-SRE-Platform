locals {
  # One name for the cluster, shared with the network so the subnet tag matches.
  cluster_name = coalesce(var.cluster_name, "${var.project}-${var.environment}")
}

module "eks" {
  source = "../../modules/aws-eks"

  cluster_name       = local.cluster_name
  environment        = var.environment
  kubernetes_version = var.kubernetes_version

  # The control plane spans public and private subnets; nodes run only in private subnets.
  control_plane_subnet_ids = concat(module.network.public_subnet_ids, module.network.private_subnet_ids)
  node_subnet_ids          = module.network.private_subnet_ids

  public_access_cidrs  = var.public_access_cidrs
  admin_principal_arns = var.admin_principal_arns

  instance_types = var.node_instance_types
  capacity_type  = var.node_capacity_type
  desired_size   = var.node_desired_size
  min_size       = var.node_min_size
  max_size       = var.node_max_size
  disk_size_gb   = var.node_disk_size_gb
}
