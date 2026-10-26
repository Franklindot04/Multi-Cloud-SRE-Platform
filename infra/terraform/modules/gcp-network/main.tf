locals {
  name_prefix = "${var.name}-${var.environment}"

  # Ranges carved from the VPC /16. For 10.20.0.0/16:
  #   nodes     10.20.0.0/20   (index 0 of 16 /20 blocks)
  #   services  10.20.16.0/20  (index 1 of 16 /20 blocks)
  #   pods      10.20.64.0/18  (index 1 of 4 /18 blocks)
  node_cidr     = cidrsubnet(var.vpc_cidr, 4, 0)
  services_cidr = cidrsubnet(var.vpc_cidr, 4, 1)
  pods_cidr     = cidrsubnet(var.vpc_cidr, 2, 1)

  pods_range_name     = "${local.name_prefix}-pods"
  services_range_name = "${local.name_prefix}-services"

  nat_enabled = var.nat_mode == "enabled"

  # Google Cloud Identity-Aware Proxy TCP forwarding range.
  iap_range = "35.235.240.0/20"

  # Google Cloud load balancer and health check source ranges.
  health_check_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
}

# --- VPC ---

resource "google_compute_network" "this" {
  project = var.project_id
  name    = local.name_prefix

  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  description             = "Custom-mode VPC for ${local.name_prefix}"
}

# --- Subnet with secondary ranges for VPC-native GKE ---

resource "google_compute_subnetwork" "nodes" {
  project = var.project_id
  name    = "${local.name_prefix}-nodes"
  region  = var.region
  network = google_compute_network.this.id

  ip_cidr_range            = local.node_cidr
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = local.pods_range_name
    ip_cidr_range = local.pods_cidr
  }

  secondary_ip_range {
    range_name    = local.services_range_name
    ip_cidr_range = local.services_cidr
  }

  dynamic "log_config" {
    for_each = var.flow_log_sampling > 0 ? [1] : []

    content {
      aggregation_interval = "INTERVAL_5_MIN"
      flow_sampling        = var.flow_log_sampling
      metadata             = "INCLUDE_ALL_METADATA"
    }
  }
}

# --- Cloud Router and Cloud NAT (optional) ---

resource "google_compute_router" "this" {
  count = local.nat_enabled ? 1 : 0

  project = var.project_id
  name    = local.name_prefix
  region  = var.region
  network = google_compute_network.this.id
}

resource "google_compute_router_nat" "this" {
  count = local.nat_enabled ? 1 : 0

  project = var.project_id
  name    = local.name_prefix
  region  = var.region
  router  = google_compute_router.this[0].name

  nat_ip_allocate_option = "AUTO_ONLY"

  # Translate the node range and both secondary ranges.
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.nodes.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# --- Firewall ---

resource "google_compute_firewall" "allow_internal" {
  project = var.project_id
  name    = "${local.name_prefix}-allow-internal"
  network = google_compute_network.this.name

  description = "Allow traffic between nodes, pods and services"
  direction   = "INGRESS"
  priority    = 1000

  source_ranges = [local.node_cidr, local.pods_cidr, local.services_cidr]

  allow {
    protocol = "tcp"
  }

  allow {
    protocol = "udp"
  }

  allow {
    protocol = "icmp"
  }
}

resource "google_compute_firewall" "allow_iap_ssh" {
  project = var.project_id
  name    = "${local.name_prefix}-allow-iap-ssh"
  network = google_compute_network.this.name

  description = "Allow SSH only through Identity-Aware Proxy"
  direction   = "INGRESS"
  priority    = 1000

  source_ranges = [local.iap_range]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "allow_health_checks" {
  project = var.project_id
  name    = "${local.name_prefix}-allow-health-checks"
  network = google_compute_network.this.name

  description = "Allow Google Cloud load balancer health checks"
  direction   = "INGRESS"
  priority    = 1000

  source_ranges = local.health_check_ranges

  allow {
    protocol = "tcp"
  }
}

resource "google_compute_firewall" "deny_all_ingress" {
  project = var.project_id
  name    = "${local.name_prefix}-deny-all-ingress"
  network = google_compute_network.this.name

  description = "Explicit lowest-priority deny for all other ingress"
  direction   = "INGRESS"
  priority    = 65534

  source_ranges = ["0.0.0.0/0"]

  deny {
    protocol = "all"
  }
}
