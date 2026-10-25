variable "region" {
  description = "AWS region for the state bucket."
  type        = string
  default     = "eu-north-1"
}

variable "project" {
  description = "Project name, used for the default bucket name and tags."
  type        = string
  default     = "multi-cloud-sre"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.project))
    error_message = "project must be 3-32 characters of lowercase letters, digits and hyphens."
  }
}

variable "environment" {
  description = "Environment tag value for the bootstrap resources."
  type        = string
  default     = "bootstrap"
}

variable "owner" {
  description = "Owner tag value (team or individual responsible)."
  type        = string
  default     = "platform-team"
}

variable "state_bucket_name" {
  description = "Globally unique bucket name. Defaults to <project>-tfstate-<account id>-<region>."
  type        = string
  default     = null

  validation {
    condition     = var.state_bucket_name == null || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "state_bucket_name must be a valid S3 bucket name (3-63 characters, lowercase)."
  }
}

variable "noncurrent_version_retention_days" {
  description = "Days to keep noncurrent state versions once they exceed the retained count."
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
    condition     = var.noncurrent_versions_to_keep >= 0
    error_message = "noncurrent_versions_to_keep must be zero or greater."
  }
}

variable "force_destroy" {
  description = "Allow destroying the bucket while it still contains objects. Leave false except during teardown."
  type        = bool
  default     = false
}
