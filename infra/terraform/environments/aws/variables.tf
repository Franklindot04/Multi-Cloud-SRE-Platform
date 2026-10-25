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

variable "vpc_cidr" {
  description = "IPv4 CIDR block of the VPC. AWS uses 10.10.0.0/16 and up; see ADR-0006 for the allocation plan."
  type        = string
  default     = "10.10.0.0/16"
}

variable "nat_mode" {
  description = "NAT gateway layout: single, per_az or none. Single keeps cost down."
  type        = string
  default     = "single"
}

variable "flow_log_retention_days" {
  description = "Retention in days for VPC flow logs."
  type        = number
  default     = 14
}

variable "cluster_name" {
  description = "Optional EKS cluster name used to tag subnets. Leave null until the cluster exists."
  type        = string
  default     = null
}
