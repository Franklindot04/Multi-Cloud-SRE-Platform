locals {
  # One name for the cluster, shared by the network resources and the future GKE cluster.
  cluster_name = coalesce(var.cluster_name, "${var.project}-${var.environment}")
}

module "network" {
  source = "../../modules/gcp-network"

  project_id        = var.project_id
  region            = var.region
  name              = local.cluster_name
  environment       = var.environment
  vpc_cidr          = var.vpc_cidr
  nat_mode          = var.nat_mode
  flow_log_sampling = var.flow_log_sampling
}
