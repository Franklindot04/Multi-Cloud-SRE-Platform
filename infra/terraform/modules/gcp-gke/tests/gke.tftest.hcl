# Plan-only tests using a mocked Google provider: no credentials or network access required.

mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "123456789012"
    }
  }

}

variables {
  project_id          = "test-project-123"
  cluster_name        = "test-dev"
  environment         = "dev"
  location            = "europe-north1-a"
  network_name        = "test-dev"
  subnet_name         = "test-dev-nodes"
  pods_range_name     = "test-dev-pods"
  services_range_name = "test-dev-services"
}

run "defaults" {
  command = plan

  assert {
    condition     = google_container_cluster.this.remove_default_node_pool == true && google_container_cluster.this.location == "europe-north1-a"
    error_message = "The default node pool must be removed and the cluster must be zonal by default."
  }

  assert {
    condition     = google_container_cluster.this.private_cluster_config[0].enable_private_nodes == true && google_container_cluster.this.private_cluster_config[0].enable_private_endpoint == false
    error_message = "Nodes must be private and the public endpoint enabled by default."
  }

  assert {
    condition     = google_container_cluster.this.private_cluster_config[0].master_ipv4_cidr_block == "172.16.0.0/28"
    error_message = "The control plane range should default to 172.16.0.0/28."
  }

  assert {
    condition     = length(google_container_cluster.this.master_authorized_networks_config) == 1 && length(google_container_cluster.this.master_authorized_networks_config[0].cidr_blocks) == 0
    error_message = "Authorized networks must be enforced with no CIDRs by default."
  }

  assert {
    condition     = google_container_cluster.this.workload_identity_config[0].workload_pool == "test-project-123.svc.id.goog"
    error_message = "Workload Identity must use the project workload pool."
  }

  assert {
    condition     = google_container_cluster.this.datapath_provider == "ADVANCED_DATAPATH" && google_container_cluster.this.enable_shielded_nodes == true
    error_message = "Dataplane V2 and shielded nodes are required."
  }

  assert {
    condition     = google_container_cluster.this.release_channel[0].channel == "REGULAR"
    error_message = "The release channel should default to REGULAR."
  }

  assert {
    condition     = google_container_cluster.this.deletion_protection == false
    error_message = "Deletion protection should default to false."
  }

  assert {
    condition     = google_container_cluster.this.ip_allocation_policy[0].cluster_secondary_range_name == "test-dev-pods" && google_container_cluster.this.ip_allocation_policy[0].services_secondary_range_name == "test-dev-services"
    error_message = "The cluster must use the supplied secondary range names."
  }

  assert {
    condition     = toset(google_container_cluster.this.logging_config[0].enable_components) == toset(["SYSTEM_COMPONENTS"]) && toset(google_container_cluster.this.monitoring_config[0].enable_components) == toset(["SYSTEM_COMPONENTS"]) && google_container_cluster.this.monitoring_config[0].managed_prometheus[0].enabled == false
    error_message = "Only system components should be logged and monitored, with managed Prometheus off."
  }

  assert {
    condition     = google_container_cluster.this.maintenance_policy[0].daily_maintenance_window[0].start_time == "02:00"
    error_message = "The maintenance window should default to 02:00 UTC."
  }

  assert {
    condition     = length(google_container_cluster.this.database_encryption) == 1 && google_container_cluster.this.database_encryption[0].state == "ENCRYPTED"
    error_message = "Secrets encryption should be on by default."
  }

  assert {
    condition     = google_container_node_pool.default.node_config[0].spot == true && google_container_node_pool.default.node_config[0].machine_type == "e2-standard-2"
    error_message = "Nodes should default to Spot e2-standard-2."
  }

  assert {
    condition     = google_container_node_pool.default.autoscaling[0].min_node_count == 1 && google_container_node_pool.default.autoscaling[0].max_node_count == 3
    error_message = "Autoscaling should default to 1-3 nodes per zone."
  }

  assert {
    condition     = google_container_node_pool.default.management[0].auto_repair == true && google_container_node_pool.default.management[0].auto_upgrade == true
    error_message = "Auto repair and auto upgrade must be on."
  }

  assert {
    condition     = google_container_node_pool.default.node_config[0].workload_metadata_config[0].mode == "GKE_METADATA"
    error_message = "Nodes must use the GKE metadata server."
  }

  assert {
    condition     = google_container_node_pool.default.node_config[0].shielded_instance_config[0].enable_secure_boot == true && google_container_node_pool.default.node_config[0].shielded_instance_config[0].enable_integrity_monitoring == true
    error_message = "Secure boot and integrity monitoring must be on."
  }

  assert {
    condition     = length(google_project_iam_member.nodes) == 5
    error_message = "The node service account should receive exactly five roles."
  }

  assert {
    condition     = google_kms_crypto_key.secrets[0].rotation_period == "7776000s" && google_kms_key_ring.gke[0].location == "europe-north1"
    error_message = "The key should rotate every 90 days and live in the cluster's region."
  }

  assert {
    condition     = google_kms_crypto_key_iam_member.gke_service_agent[0].role == "roles/cloudkms.cryptoKeyEncrypterDecrypter"
    error_message = "The GKE service agent needs the encrypter/decrypter role on the key."
  }

  assert {
    condition     = output.workload_pool == "test-project-123.svc.id.goog" && output.get_credentials_command == "gcloud container clusters get-credentials test-dev --location europe-north1-a --project test-project-123"
    error_message = "Workload pool and get-credentials outputs are wrong."
  }
}

run "node_roles_are_least_privilege" {
  command = plan

  assert {
    condition = toset([for m in google_project_iam_member.nodes : m.role]) == toset([
      "roles/logging.logWriter",
      "roles/monitoring.metricWriter",
      "roles/monitoring.viewer",
      "roles/stackdriver.resourceMetadata.writer",
      "roles/artifactregistry.reader",
    ])
    error_message = "The node service account roles must be exactly the five documented roles."
  }
}

run "regional_cluster" {
  command = plan

  variables {
    location = "europe-north1"
  }

  assert {
    condition     = google_container_cluster.this.location == "europe-north1" && google_container_node_pool.default.location == "europe-north1"
    error_message = "A region as location should create a regional cluster and node pool."
  }

  assert {
    condition     = google_kms_key_ring.gke[0].location == "europe-north1"
    error_message = "The key ring should be in the cluster's region."
  }
}

run "secrets_encryption_disabled" {
  command = plan

  variables {
    enable_secrets_encryption = false
  }

  assert {
    condition     = length(google_kms_key_ring.gke) == 0 && length(google_kms_crypto_key.secrets) == 0 && length(google_kms_crypto_key_iam_member.gke_service_agent) == 0
    error_message = "No KMS resources are expected when encryption is disabled."
  }

  assert {
    condition     = length(google_container_cluster.this.database_encryption) == 0 && output.kms_key_id == null
    error_message = "The cluster must not configure database encryption when disabled."
  }
}

run "kms_suffix_and_rotation" {
  command = plan

  variables {
    kms_name_suffix          = "-2"
    kms_rotation_period_days = 30
  }

  assert {
    condition     = google_kms_key_ring.gke[0].name == "test-dev-gke-2" && google_kms_crypto_key.secrets[0].rotation_period == "2592000s"
    error_message = "The key ring suffix and rotation period should be applied."
  }
}

run "spot_off" {
  command = plan

  variables {
    spot = false
  }

  assert {
    condition     = google_container_node_pool.default.node_config[0].spot == false
    error_message = "spot = false should create standard VMs."
  }
}

run "authorized_cidrs" {
  command = plan

  variables {
    master_authorized_cidrs = ["203.0.113.10/32", "198.51.100.0/24"]
  }

  assert {
    condition     = length(google_container_cluster.this.master_authorized_networks_config[0].cidr_blocks) == 2
    error_message = "Each authorized CIDR should become a cidr_blocks entry."
  }
}

run "private_endpoint" {
  command = plan

  variables {
    enable_private_endpoint = true
  }

  assert {
    condition     = google_container_cluster.this.private_cluster_config[0].enable_private_endpoint == true
    error_message = "enable_private_endpoint should be passed through."
  }
}

run "managed_prometheus_and_logging" {
  command = plan

  variables {
    enable_managed_prometheus = true
    logging_components        = ["SYSTEM_COMPONENTS", "WORKLOADS"]
    monitoring_components     = ["SYSTEM_COMPONENTS", "POD"]
  }

  assert {
    condition     = google_container_cluster.this.monitoring_config[0].managed_prometheus[0].enabled == true && length(google_container_cluster.this.logging_config[0].enable_components) == 2
    error_message = "Logging, monitoring and Prometheus settings should be passed through."
  }
}

run "rejects_invalid_authorized_cidr" {
  command = plan

  variables {
    master_authorized_cidrs = ["203.0.113.10"]
  }

  expect_failures = [var.master_authorized_cidrs]
}

run "rejects_bad_authorized_prefix" {
  command = plan

  variables {
    master_authorized_cidrs = ["203.0.113.10/33"]
  }

  expect_failures = [var.master_authorized_cidrs]
}

run "rejects_max_below_min" {
  command = plan

  variables {
    min_node_count = 3
    max_node_count = 2
  }

  expect_failures = [var.max_node_count]
}

run "rejects_zero_max" {
  command = plan

  variables {
    min_node_count = 0
    max_node_count = 0
  }

  expect_failures = [var.max_node_count]
}

run "rejects_negative_min" {
  command = plan

  variables {
    min_node_count = -1
  }

  expect_failures = [var.min_node_count]
}

run "rejects_invalid_location" {
  command = plan

  variables {
    location = "Europe"
  }

  expect_failures = [var.location]
}

run "rejects_location_with_extra_part" {
  command = plan

  variables {
    location = "europe-north1-a-b"
  }

  expect_failures = [var.location]
}

run "rejects_wrong_master_cidr_size" {
  command = plan

  variables {
    master_ipv4_cidr = "172.16.0.0/24"
  }

  expect_failures = [var.master_ipv4_cidr]
}

run "rejects_public_master_cidr" {
  command = plan

  variables {
    master_ipv4_cidr = "8.8.8.0/28"
  }

  expect_failures = [var.master_ipv4_cidr]
}

run "rejects_invalid_release_channel" {
  command = plan

  variables {
    release_channel = "BETA"
  }

  expect_failures = [var.release_channel]
}

run "rejects_invalid_machine_type" {
  command = plan

  variables {
    machine_type = "Large"
  }

  expect_failures = [var.machine_type]
}

run "rejects_invalid_project_id" {
  command = plan

  variables {
    project_id = "Bad_Project"
  }

  expect_failures = [var.project_id]
}

run "rejects_long_cluster_name" {
  command = plan

  variables {
    cluster_name = "this-cluster-name-is-too-long"
  }

  expect_failures = [var.cluster_name]
}

run "rejects_invalid_disk_type" {
  command = plan

  variables {
    disk_type = "local-ssd"
  }

  expect_failures = [var.disk_type]
}

run "rejects_small_disk" {
  command = plan

  variables {
    disk_size_gb = 5
  }

  expect_failures = [var.disk_size_gb]
}

run "rejects_invalid_logging_component" {
  command = plan

  variables {
    logging_components = ["EVERYTHING"]
  }

  expect_failures = [var.logging_components]
}

run "rejects_invalid_maintenance_time" {
  command = plan

  variables {
    maintenance_start_time = "25:00"
  }

  expect_failures = [var.maintenance_start_time]
}

run "rejects_invalid_kms_suffix" {
  command = plan

  variables {
    kms_name_suffix = "Bad Suffix"
  }

  expect_failures = [var.kms_name_suffix]
}
