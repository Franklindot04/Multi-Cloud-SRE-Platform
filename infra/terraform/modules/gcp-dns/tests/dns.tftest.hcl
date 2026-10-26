# Plan-only tests using a mocked Google provider: no credentials or network access required.

mock_provider "google" {}

variables {
  project_id  = "test-project-123"
  name        = "test"
  environment = "dev"
}

run "disabled_by_default" {
  command = plan

  assert {
    condition     = length(google_dns_managed_zone.this) == 0
    error_message = "An empty dns_name must create nothing."
  }

  assert {
    condition     = output.zone_name == null && output.zone_id == null && output.dns_name == null && length(output.name_servers) == 0
    error_message = "Outputs should be empty when no DNS name is set."
  }
}

run "enabled_zone" {
  command = plan

  variables {
    dns_name = "gke.example.com"
  }

  assert {
    condition     = length(google_dns_managed_zone.this) == 1 && google_dns_managed_zone.this[0].name == "test-dev"
    error_message = "A zone named after the module inputs is expected."
  }

  assert {
    condition     = google_dns_managed_zone.this[0].dns_name == "gke.example.com." && google_dns_managed_zone.this[0].visibility == "public"
    error_message = "The zone should be public with a trailing dot added to the DNS name."
  }

  assert {
    condition     = google_dns_managed_zone.this[0].dnssec_config[0].state == "off"
    error_message = "DNSSEC should be off by default."
  }

  assert {
    condition     = google_dns_managed_zone.this[0].force_destroy == false
    error_message = "force_destroy should default to false."
  }

  assert {
    condition     = output.dns_name == "gke.example.com."
    error_message = "The dns_name output should include the trailing dot."
  }
}

run "trailing_dot_is_not_doubled" {
  command = plan

  variables {
    dns_name = "gke.example.com."
  }

  assert {
    condition     = google_dns_managed_zone.this[0].dns_name == "gke.example.com."
    error_message = "A name that already ends in a dot must not get a second dot."
  }
}

run "dnssec_on" {
  command = plan

  variables {
    dns_name      = "gke.example.com"
    enable_dnssec = true
  }

  assert {
    condition     = google_dns_managed_zone.this[0].dnssec_config[0].state == "on"
    error_message = "enable_dnssec should turn DNSSEC on."
  }
}

run "labels_are_merged" {
  command = plan

  variables {
    dns_name = "gke.example.com"
    labels   = { owner = "platform-team" }
  }

  assert {
    condition     = google_dns_managed_zone.this[0].labels["owner"] == "platform-team" && google_dns_managed_zone.this[0].labels["environment"] == "dev" && google_dns_managed_zone.this[0].labels["managed-by"] == "terraform"
    error_message = "Zone labels should include the module and caller labels."
  }
}

run "force_destroy" {
  command = plan

  variables {
    dns_name      = "gke.example.com"
    force_destroy = true
  }

  assert {
    condition     = google_dns_managed_zone.this[0].force_destroy == true
    error_message = "force_destroy should be passed through."
  }
}

run "rejects_uppercase_dns_name" {
  command = plan

  variables {
    dns_name = "GKE.example.com"
  }

  expect_failures = [var.dns_name]
}

run "rejects_single_label_dns_name" {
  command = plan

  variables {
    dns_name = "localhost"
  }

  expect_failures = [var.dns_name]
}

run "rejects_dns_name_with_scheme" {
  command = plan

  variables {
    dns_name = "https://gke.example.com"
  }

  expect_failures = [var.dns_name]
}

run "rejects_invalid_project_id" {
  command = plan

  variables {
    project_id = "Bad_Project"
  }

  expect_failures = [var.project_id]
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
