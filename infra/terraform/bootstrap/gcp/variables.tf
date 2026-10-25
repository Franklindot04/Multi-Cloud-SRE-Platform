variable "project_id" {
  description = "ID of the GCP project that will hold the state bucket."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project ID (6-30 characters, lowercase letters, digits and hyphens)."
  }
}

variable "region" {
  description = "GCP region (bucket location) for the state bucket."
  type        = string
  default     = "europe-north1"
}

variable "project" {
  description = "Project name, used for labels."
  type        = string
  default     = "multi-cloud-sre"
}

variable "environment" {
  description = "Environment label value for the bootstrap resources."
  type        = string
  default     = "bootstrap"
}

variable "owner" {
  description = "Owner label value (team or individual responsible)."
  type        = string
  default     = "platform-team"
}

variable "state_bucket_name" {
  description = "Globally unique bucket name. Defaults to <project_id>-tfstate."
  type        = string
  default     = null

  validation {
    condition     = var.state_bucket_name == null || can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "state_bucket_name must be a valid GCS bucket name (3-63 characters, lowercase)."
  }
}

variable "noncurrent_version_retention_days" {
  description = "Days to keep noncurrent state versions before deletion."
  type        = number
  default     = 90

  validation {
    condition     = var.noncurrent_version_retention_days >= 1
    error_message = "noncurrent_version_retention_days must be at least 1."
  }
}

variable "noncurrent_versions_to_keep" {
  description = "Number of newest noncurrent versions to keep regardless of age."
  type        = number
  default     = 10

  validation {
    condition     = var.noncurrent_versions_to_keep >= 1
    error_message = "noncurrent_versions_to_keep must be at least 1."
  }
}

variable "force_destroy" {
  description = "Allow destroying the bucket while it still contains objects. Leave false except during teardown."
  type        = bool
  default     = false
}
