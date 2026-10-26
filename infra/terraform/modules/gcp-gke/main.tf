data "google_project" "this" {
  project_id = var.project_id
}

locals {
  name_prefix = var.cluster_name

  labels = merge(var.labels, {
    environment  = var.environment
    "managed-by" = "terraform"
  })

  # A zone has three dash-separated parts (europe-north1-a); a region has two.
  location_parts = split("-", var.location)
  region         = length(local.location_parts) == 3 ? join("-", slice(local.location_parts, 0, 2)) : var.location

  workload_pool = "${var.project_id}.svc.id.goog"

  node_service_account_roles = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ])

  # Identity of the Google-managed GKE service agent, which needs access to the encryption key.
  gke_service_agent = "serviceAccount:service-${data.google_project.this.number}@container-engine-robot.iam.gserviceaccount.com"
}

# --- Node service account (least privilege, not the default compute account) ---

resource "google_service_account" "nodes" {
  project      = var.project_id
  account_id   = "${local.name_prefix}-nodes"
  display_name = "GKE nodes for ${var.cluster_name}"
}

resource "google_project_iam_member" "nodes" {
  for_each = local.node_service_account_roles

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

# --- Secrets encryption ---

resource "google_kms_key_ring" "gke" {
  count = var.enable_secrets_encryption ? 1 : 0

  project  = var.project_id
  name     = "${local.name_prefix}-gke${var.kms_name_suffix}"
  location = local.region
}

resource "google_kms_crypto_key" "secrets" {
  count = var.enable_secrets_encryption ? 1 : 0

  name            = "secrets"
  key_ring        = google_kms_key_ring.gke[0].id
  rotation_period = "${var.kms_rotation_period_days * 86400}s"
  purpose         = "ENCRYPT_DECRYPT"

  labels = local.labels
}

resource "google_kms_crypto_key_iam_member" "gke_service_agent" {
  count = var.enable_secrets_encryption ? 1 : 0

  crypto_key_id = google_kms_crypto_key.secrets[0].id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = local.gke_service_agent
}

# --- Cluster ---

resource "google_container_cluster" "this" {
  project  = var.project_id
  name     = var.cluster_name
  location = var.location

  network    = var.network_name
  subnetwork = var.subnet_name

  # The default node pool is replaced by the managed pool below.
  remove_default_node_pool = true
  initial_node_count       = 1

  deletion_protection = var.deletion_protection
  resource_labels     = local.labels

  # Dataplane V2 provides network policy enforcement; no separate network_policy block is needed.
  datapath_provider = "ADVANCED_DATAPATH"

  enable_shielded_nodes = true

  release_channel {
    channel = var.release_channel
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = var.enable_private_endpoint
    master_ipv4_cidr_block  = var.master_ipv4_cidr
  }

  # Present even when empty, so authorized networks are always enforced.
  master_authorized_networks_config {
    gcp_public_cidrs_access_enabled = false

    dynamic "cidr_blocks" {
      for_each = var.master_authorized_cidrs

      content {
        cidr_block   = cidr_blocks.value
        display_name = "authorized-${cidr_blocks.key}"
      }
    }
  }

  workload_identity_config {
    workload_pool = local.workload_pool
  }

  dynamic "database_encryption" {
    for_each = var.enable_secrets_encryption ? [1] : []

    content {
      state    = "ENCRYPTED"
      key_name = google_kms_crypto_key.secrets[0].id
    }
  }

  logging_config {
    enable_components = var.logging_components
  }

  monitoring_config {
    enable_components = var.monitoring_components

    managed_prometheus {
      enabled = var.enable_managed_prometheus
    }
  }

  maintenance_policy {
    daily_maintenance_window {
      start_time = var.maintenance_start_time
    }
  }

  # Only used to create the temporary default pool with the dedicated service account.
  node_config {
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  lifecycle {
    # The default pool is removed after creation, so its node_config is not tracked afterwards.
    ignore_changes = [node_config]
  }

  depends_on = [
    google_project_iam_member.nodes,
    google_kms_crypto_key_iam_member.gke_service_agent,
  ]
}

# --- Managed node pool ---

resource "google_container_node_pool" "default" {
  project  = var.project_id
  name     = "${local.name_prefix}-default"
  cluster  = google_container_cluster.this.name
  location = var.location

  initial_node_count = var.min_node_count

  autoscaling {
    min_node_count = var.min_node_count
    max_node_count = var.max_node_count
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    strategy        = "SURGE"
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type    = var.machine_type
    spot            = var.spot
    disk_size_gb    = var.disk_size_gb
    disk_type       = var.disk_type
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    labels          = var.node_labels
    resource_labels = local.labels

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }
}
