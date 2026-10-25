variable "region" {
  description = "AWS region for this environment."
  type        = string
  default     = "eu-north-1"
}

variable "project" {
  description = "Project name used in tags and resource names."
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
  description = "Owner tag value (team or individual responsible)."
  type        = string
  default     = "platform-team"
}
