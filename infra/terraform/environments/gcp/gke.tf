locals {
  # The cluster keeps the full <project>-<environment> name (at most 24 characters).
  cluster_name = coalesce(var.cluster_name, "${var.project}-${var.environment}")
}

module "gke" {
  source = "../../modules/gcp-gke"

  project_id   = var.project_id
  cluster_name = local.cluster_name
  environment  = var.environment
  location     = var.gke_location

  network_name        = module.network.network_name
  subnet_name         = module.network.subnet_name
  pods_range_name     = module.network.pods_range_name
  services_range_name = module.network.services_range_name

  release_channel         = var.gke_release_channel
  master_authorized_cidrs = var.master_authorized_cidrs
  deletion_protection     = var.gke_deletion_protection
  kms_name_suffix         = var.gke_kms_name_suffix

  machine_type   = var.gke_machine_type
  spot           = var.gke_spot
  min_node_count = var.gke_min_node_count
  max_node_count = var.gke_max_node_count
  disk_size_gb   = var.gke_disk_size_gb

  labels = {
    project = var.project
    owner   = var.owner
  }

  # Nodes need Cloud NAT and the firewall rules; destroy the cluster before them.
  depends_on = [module.network]
}
