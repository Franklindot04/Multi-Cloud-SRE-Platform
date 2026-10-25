variable "name" {
  description = "Base name for resources created by this module."
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

variable "vpc_cidr" {
  description = "IPv4 CIDR block of the VPC. Must be a private (RFC 1918) range between /16 and /20."
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
    condition     = try(tonumber(split("/", var.vpc_cidr)[1]) >= 16 && tonumber(split("/", var.vpc_cidr)[1]) <= 20, false)
    error_message = "vpc_cidr prefix length must be between /16 and /20."
  }
}

variable "nat_mode" {
  description = "NAT gateway layout: \"single\" (one shared gateway), \"per_az\" (one per availability zone) or \"none\"."
  type        = string
  default     = "single"

  validation {
    condition     = contains(["single", "per_az", "none"], var.nat_mode)
    error_message = "nat_mode must be one of: single, per_az, none."
  }
}

variable "flow_log_retention_days" {
  description = "Retention in days for the VPC flow log group. Must be a value CloudWatch Logs supports."
  type        = number
  default     = 14

  validation {
    condition = contains(
      [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
      var.flow_log_retention_days,
    )
    error_message = "flow_log_retention_days must be a retention period supported by CloudWatch Logs (for example 7, 14, 30, 90)."
  }
}

variable "cluster_name" {
  description = "Optional EKS cluster name. When set, subnets get the kubernetes.io/cluster/<name> = shared tag."
  type        = string
  default     = null

  validation {
    condition     = var.cluster_name == null || can(regex("^[0-9A-Za-z][0-9A-Za-z_-]{0,99}$", var.cluster_name))
    error_message = "cluster_name must be 1-100 characters of letters, digits, hyphens and underscores, starting with a letter or digit."
  }
}

variable "tags" {
  description = "Additional tags merged onto all resources."
  type        = map(string)
  default     = {}
}
