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
  description = "GKE cluster name, at most 24 characters. Defaults to <project>-<environment>. The network is named <project>-<environment> independently of this value."
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

variable "gke_location" {
  description = "Zone (zonal cluster, cheaper) or region (regional cluster, highly available) for GKE. Must be in var.region."
  type        = string
  default     = "europe-north1-a"
}

variable "gke_release_channel" {
  description = "GKE release channel: RAPID, REGULAR or STABLE."
  type        = string
  default     = "REGULAR"
}

variable "master_authorized_cidrs" {
  description = "CIDR blocks allowed to reach the public GKE control plane endpoint. Add your own /32; empty means only the cluster's network can reach it."
  type        = list(string)
  default     = []
}

variable "gke_machine_type" {
  description = "Machine type of the GKE nodes."
  type        = string
  default     = "e2-standard-2"
}

variable "gke_spot" {
  description = "Use Spot VMs for the GKE nodes."
  type        = bool
  default     = true
}

variable "gke_min_node_count" {
  description = "Minimum nodes per zone."
  type        = number
  default     = 1
}

variable "gke_max_node_count" {
  description = "Maximum nodes per zone."
  type        = number
  default     = 3
}

variable "gke_disk_size_gb" {
  description = "Boot disk size in GiB for each GKE node."
  type        = number
  default     = 50
}

variable "gke_deletion_protection" {
  description = "Protect the GKE cluster from deletion. Leave false for short-lived clusters."
  type        = bool
  default     = false
}

variable "gke_kms_name_suffix" {
  description = "Suffix for the KMS key ring name. Key rings cannot be deleted, so set a new value (for example \"-2\") to re-create the cluster after a destroy."
  type        = string
  default     = ""
}

variable "dns_name" {
  description = "DNS name of the Cloud DNS zone, for example gke.example.com, typically a subdomain delegated from the AWS zone. Empty (the default) creates no DNS resources."
  type        = string
  default     = ""
}

variable "dns_enable_dnssec" {
  description = "Sign the zone with DNSSEC. Add the DS record at the parent zone before enabling."
  type        = bool
  default     = false
}

variable "dns_force_destroy" {
  description = "Allow destroying the zone while it contains record sets that Terraform does not manage."
  type        = bool
  default     = false
}

variable "enable_external_dns_iam" {
  description = "Create the Google service account and Workload Identity binding for the external-dns add-on. Needs dns_name."
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_external_dns_iam || var.dns_name != ""
    error_message = "enable_external_dns_iam needs a Cloud DNS zone: set dns_name."
  }
}

variable "enable_cert_manager_iam" {
  description = "Create the Google service account and Workload Identity binding for cert-manager Cloud DNS DNS-01 challenges. Needs dns_name."
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_cert_manager_iam || var.dns_name != ""
    error_message = "enable_cert_manager_iam needs a Cloud DNS zone: set dns_name."
  }
}
