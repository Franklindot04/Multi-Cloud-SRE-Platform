# Plan-only tests using a mocked Google provider: no credentials or network access required.

mock_provider "google" {}

variables {
  project_id  = "test-project-123"
  region      = "europe-north1"
  name        = "test"
  environment = "dev"
  vpc_cidr    = "10.20.0.0/16"
}

run "defaults" {
  command = plan

  assert {
    condition     = google_compute_network.this.auto_create_subnetworks == false && google_compute_network.this.routing_mode == "REGIONAL"
    error_message = "The VPC must be custom mode with regional routing."
  }

  assert {
    condition     = google_compute_subnetwork.nodes.private_ip_google_access == true
    error_message = "Private Google access must be enabled on the node subnet."
  }

  assert {
    condition     = length(google_compute_subnetwork.nodes.secondary_ip_range) == 2
    error_message = "The node subnet needs secondary ranges for pods and services."
  }

  assert {
    condition     = google_compute_subnetwork.nodes.log_config[0].flow_sampling == 0.5 && google_compute_subnetwork.nodes.log_config[0].aggregation_interval == "INTERVAL_5_MIN"
    error_message = "Flow logs should default to 0.5 sampling with a 5 minute interval."
  }

  assert {
    condition     = length(google_compute_router.this) == 1 && length(google_compute_router_nat.this) == 1
    error_message = "A Cloud Router and Cloud NAT are expected by default."
  }

  assert {
    condition     = google_compute_router_nat.this[0].nat_ip_allocate_option == "AUTO_ONLY" && google_compute_router_nat.this[0].log_config[0].filter == "ERRORS_ONLY"
    error_message = "NAT should use auto-allocated IPs and log errors only."
  }

  assert {
    condition     = toset(google_compute_firewall.allow_iap_ssh.source_ranges) == toset(["35.235.240.0/20"])
    error_message = "SSH must be allowed only from the IAP range."
  }

  assert {
    condition     = toset(google_compute_firewall.allow_health_checks.source_ranges) == toset(["130.211.0.0/22", "35.191.0.0/16"])
    error_message = "Health check ranges are incorrect."
  }

  assert {
    condition     = google_compute_firewall.deny_all_ingress.priority == 65534 && google_compute_firewall.allow_internal.priority < google_compute_firewall.deny_all_ingress.priority
    error_message = "The explicit deny must be the lowest-priority ingress rule."
  }

  assert {
    condition     = length(google_compute_firewall.allow_internal.source_ranges) == 3
    error_message = "Internal traffic should be allowed from the node, pod and service ranges."
  }
}

run "derived_ranges_for_default_cidr" {
  command = plan

  assert {
    condition     = output.node_cidr == "10.20.0.0/20" && output.services_cidr == "10.20.16.0/20" && output.pods_cidr == "10.20.64.0/18"
    error_message = "Ranges for 10.20.0.0/16 should be 10.20.0.0/20, 10.20.16.0/20 and 10.20.64.0/18."
  }

  assert {
    condition     = output.pods_range_name == "test-dev-pods" && output.services_range_name == "test-dev-services"
    error_message = "Secondary range names should be derived from name and environment."
  }
}

run "derived_ranges_follow_vpc_cidr" {
  command = plan

  variables {
    vpc_cidr = "10.21.0.0/16"
  }

  assert {
    condition     = output.node_cidr == "10.21.0.0/20" && output.services_cidr == "10.21.16.0/20" && output.pods_cidr == "10.21.64.0/18"
    error_message = "Ranges should follow the VPC CIDR."
  }
}

run "no_nat" {
  command = plan

  variables {
    nat_mode = "none"
  }

  assert {
    condition     = length(google_compute_router.this) == 0 && length(google_compute_router_nat.this) == 0
    error_message = "nat_mode none must not create a router or NAT."
  }

  assert {
    condition     = output.nat_name == null && output.router_name == null
    error_message = "NAT and router outputs should be null when NAT is disabled."
  }
}

run "flow_logs_disabled_at_zero_sampling" {
  command = plan

  variables {
    flow_log_sampling = 0
  }

  assert {
    condition     = length(google_compute_subnetwork.nodes.log_config) == 0
    error_message = "No log_config is expected when sampling is zero."
  }
}

run "custom_flow_log_sampling" {
  command = plan

  variables {
    flow_log_sampling = 0.1
  }

  assert {
    condition     = google_compute_subnetwork.nodes.log_config[0].flow_sampling == 0.1
    error_message = "flow_log_sampling should be passed through."
  }
}

run "rejects_invalid_project_id" {
  command = plan

  variables {
    project_id = "Bad_Project"
  }

  expect_failures = [var.project_id]
}

run "rejects_invalid_cidr" {
  command = plan

  variables {
    vpc_cidr = "not-a-cidr"
  }

  expect_failures = [var.vpc_cidr]
}

run "rejects_public_cidr" {
  command = plan

  variables {
    vpc_cidr = "8.8.0.0/16"
  }

  expect_failures = [var.vpc_cidr]
}

run "rejects_non_slash_16" {
  command = plan

  variables {
    vpc_cidr = "10.20.0.0/20"
  }

  expect_failures = [var.vpc_cidr]
}

run "rejects_invalid_nat_mode" {
  command = plan

  variables {
    nat_mode = "single"
  }

  expect_failures = [var.nat_mode]
}

run "rejects_sampling_above_one" {
  command = plan

  variables {
    flow_log_sampling = 1.5
  }

  expect_failures = [var.flow_log_sampling]
}

run "rejects_negative_sampling" {
  command = plan

  variables {
    flow_log_sampling = -0.1
  }

  expect_failures = [var.flow_log_sampling]
}

run "rejects_invalid_region" {
  command = plan

  variables {
    region = "Europe"
  }

  expect_failures = [var.region]
}

run "rejects_invalid_name" {
  command = plan

  variables {
    name = "Bad Name"
  }

  expect_failures = [var.name]
}

run "rejects_invalid_environment" {
  command = plan

  variables {
    environment = "test"
  }

  expect_failures = [var.environment]
}
