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

variable "cluster_name" {
  description = "GKE cluster name. Defaults to <project>-<environment>. Also used to name the network and its secondary ranges."
  type        = string
  default     = null
}

variable "vpc_cidr" {
  description = "IPv4 /16 for the VPC. GCP uses 10.20.0.0/16 and up; see ADR-0006 for the allocation plan."
  type        = string
  default     = "10.20.0.0/16"
}

variable "nat_mode" {
  description = "Cloud NAT layout: enabled or none. Disabling NAT removes the main fixed network cost."
  type        = string
  default     = "enabled"
}

variable "flow_log_sampling" {
  description = "Fraction of packets sampled by subnet flow logs (0 to 1). Zero turns flow logs off."
  type        = number
  default     = 0.5
}
