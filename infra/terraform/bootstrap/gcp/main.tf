# Local state by design: this stack creates the remote backend itself.

provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = {
    project      = var.project
    environment  = var.environment
    "managed-by" = "terraform"
    owner        = var.owner
  }
}

locals {
  bucket_name = coalesce(var.state_bucket_name, "${var.project_id}-tfstate")
}

resource "google_storage_bucket" "state" {
  name          = local.bucket_name
  location      = var.region
  storage_class = "STANDARD"
  force_destroy = var.force_destroy

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  # Keep the newest N noncurrent versions; delete older ones.
  lifecycle_rule {
    condition {
      with_state         = "ARCHIVED"
      num_newer_versions = var.noncurrent_versions_to_keep
    }
    action {
      type = "Delete"
    }
  }

  # Delete any noncurrent version once it is past the retention window.
  lifecycle_rule {
    condition {
      with_state                 = "ARCHIVED"
      days_since_noncurrent_time = var.noncurrent_version_retention_days
    }
    action {
      type = "Delete"
    }
  }
}
