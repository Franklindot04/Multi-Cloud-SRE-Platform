variable "project_id" {
  description = "ID of the GCP project for this environment."
  type        = string
}

variable "region" {
  description = "GCP region for this environment."
  type        = string
  default     = "europe-north1"
}

variable "project" {
  description = "Project name used in labels and resource names."
  type        = string
  default     = "multi-cloud-sre"
}

variable "environment" {
  description = "Environment name."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "owner" {
  description = "Owner label value (team or individual responsible)."
  type        = string
  default     = "platform-team"
}
