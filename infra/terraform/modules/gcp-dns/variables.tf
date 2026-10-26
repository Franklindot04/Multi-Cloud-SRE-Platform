variable "project_id" {
  description = "ID of the GCP project that will contain the zone."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project ID (6-30 characters, lowercase letters, digits and hyphens, starting with a letter)."
  }
}

variable "name" {
  description = "Base name for the zone."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3-32 characters of lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "environment" {
  description = "Environment name."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "dns_name" {
  description = "DNS name of the zone, for example gke.example.com (a trailing dot is optional). Empty (the default) creates nothing."
  type        = string
  default     = ""

  validation {
    condition     = var.dns_name == "" || can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}\\.?$", var.dns_name))
    error_message = "dns_name must be empty or a lowercase DNS name such as gke.example.com."
  }
}

variable "enable_dnssec" {
  description = "Sign the zone with DNSSEC. The DS record must also be added at the parent zone or registrar."
  type        = bool
  default     = false
}

variable "force_destroy" {
  description = "Allow destroying the zone while it still contains record sets that Terraform does not manage."
  type        = bool
  default     = false
}

variable "labels" {
  description = "Additional labels merged onto the zone."
  type        = map(string)
  default     = {}
}
