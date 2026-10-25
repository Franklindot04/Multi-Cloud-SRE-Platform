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
  description = "EKS cluster name. Defaults to <project>-<environment>. Also used to tag the shared subnets."
  type        = string
  default     = null
}

variable "kubernetes_version" {
  description = "Kubernetes minor version for the EKS cluster. Newest version in EKS standard support at the time of writing."
  type        = string
  default     = "1.37"
}

variable "public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public Kubernetes API endpoint. Restrict to your own /32."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "admin_principal_arns" {
  description = "IAM user or role ARNs granted cluster admin through EKS access entries."
  type        = list(string)
  default     = []
}

variable "node_instance_types" {
  description = "Instance types for the managed node group."
  type        = list(string)
  default     = ["t3.large", "m5.large"]
}

variable "node_capacity_type" {
  description = "Node capacity type: SPOT or ON_DEMAND."
  type        = string
  default     = "SPOT"
}

variable "node_desired_size" {
  description = "Desired number of nodes."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of nodes."
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of nodes."
  type        = number
  default     = 4
}

variable "node_disk_size_gb" {
  description = "Root volume size in GiB for each node."
  type        = number
  default     = 30
}
