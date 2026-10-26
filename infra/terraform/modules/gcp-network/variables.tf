variable "project_id" {
  description = "ID of the GCP project that will contain the network."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project ID (6-30 characters, lowercase letters, digits and hyphens, starting with a letter)."
  }
}

variable "region" {
  description = "GCP region for the subnet, router and NAT."
  type        = string

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region))
    error_message = "region must be a GCP region name such as europe-north1."
  }
}

variable "name" {
  description = "Base name for resources created by this module (typically the cluster name)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,38}[a-z0-9]$", var.name))
    error_message = "name must be 3-40 characters of lowercase letters, digits and hyphens, starting with a letter."
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

variable "vpc_cidr" {
  description = "IPv4 CIDR block that all subnet and secondary ranges are carved from. Must be a private (RFC 1918) /16."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }

  validation {
    condition     = can(regex("^(10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.)", var.vpc_cidr))
    error_message = "vpc_cidr must be within a private range: 10.0.0.0/8, 172.16.0.0/12 or 192.168.0.0/16."
  }

  validation {
    condition     = try(tonumber(split("/", var.vpc_cidr)[1]) == 16, false)
    error_message = "vpc_cidr must be a /16."
  }
}

variable "nat_mode" {
  description = "Cloud NAT layout: \"enabled\" (router and NAT gateway) or \"none\" (no outbound internet access for private nodes)."
  type        = string
  default     = "enabled"

  validation {
    condition     = contains(["enabled", "none"], var.nat_mode)
    error_message = "nat_mode must be one of: enabled, none."
  }
}

variable "flow_log_sampling" {
  description = "Fraction of packets sampled by subnet flow logs, from 0 to 1. Zero turns flow logs off."
  type        = number
  default     = 0.5

  validation {
    condition     = var.flow_log_sampling >= 0 && var.flow_log_sampling <= 1
    error_message = "flow_log_sampling must be between 0 and 1."
  }
}
