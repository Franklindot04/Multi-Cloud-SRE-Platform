variable "project_id" {
  description = "ID of the GCP project that will contain the cluster."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project ID (6-30 characters, lowercase letters, digits and hyphens, starting with a letter)."
  }
}

variable "cluster_name" {
  description = "Name of the GKE cluster. Also the prefix for the node pool, service account and key names."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,22}[a-z0-9]$", var.cluster_name))
    error_message = "cluster_name must be 3-24 characters of lowercase letters, digits and hyphens, starting with a letter (it is also used in a 30-character service account ID)."
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

variable "location" {
  description = "A zone (for example europe-north1-a) for a zonal cluster, or a region (europe-north1) for a regional cluster. Must be in the region of the subnet."
  type        = string

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+(-[a-z])?$", var.location))
    error_message = "location must be a GCP zone such as europe-north1-a or a region such as europe-north1."
  }
}

# --- Network ---

variable "network_name" {
  description = "Name of the VPC network, from the gcp-network module."
  type        = string
}

variable "subnet_name" {
  description = "Name of the node subnet, from the gcp-network module."
  type        = string
}

variable "pods_range_name" {
  description = "Name of the subnet secondary range for pods, from the gcp-network module."
  type        = string
}

variable "services_range_name" {
  description = "Name of the subnet secondary range for services, from the gcp-network module."
  type        = string
}

# --- Control plane access ---

variable "enable_private_endpoint" {
  description = "Disable the public control plane endpoint entirely. When false (default) the public endpoint is reachable only from master_authorized_cidrs."
  type        = bool
  default     = false
}

variable "master_authorized_cidrs" {
  description = "CIDR blocks allowed to reach the public control plane endpoint. Empty means only the cluster's own network can reach it. Add your own /32 to use kubectl from a workstation."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.master_authorized_cidrs : can(cidrhost(c, 0))])
    error_message = "Every entry in master_authorized_cidrs must be a valid CIDR block, for example 203.0.113.10/32."
  }
}

variable "master_ipv4_cidr" {
  description = "Private /28 range for the control plane. Must not overlap the VPC or any peered network."
  type        = string
  default     = "172.16.0.0/28"

  validation {
    condition     = can(cidrhost(var.master_ipv4_cidr, 0))
    error_message = "master_ipv4_cidr must be a valid IPv4 CIDR block."
  }

  validation {
    condition     = can(regex("^(10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.)", var.master_ipv4_cidr))
    error_message = "master_ipv4_cidr must be within a private range: 10.0.0.0/8, 172.16.0.0/12 or 192.168.0.0/16."
  }

  validation {
    condition     = try(tonumber(split("/", var.master_ipv4_cidr)[1]) == 28, false)
    error_message = "master_ipv4_cidr must be a /28."
  }
}

variable "release_channel" {
  description = "GKE release channel: RAPID, REGULAR or STABLE."
  type        = string
  default     = "REGULAR"

  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE"], var.release_channel)
    error_message = "release_channel must be one of: RAPID, REGULAR, STABLE."
  }
}

variable "maintenance_start_time" {
  description = "Start of the daily four-hour maintenance window, in UTC as HH:MM."
  type        = string
  default     = "02:00"

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", var.maintenance_start_time))
    error_message = "maintenance_start_time must be a 24-hour UTC time formatted HH:MM."
  }
}

variable "deletion_protection" {
  description = "Protect the cluster from deletion through Terraform and the API. Leave false for short-lived clusters."
  type        = bool
  default     = false
}

# --- Secrets encryption ---

variable "enable_secrets_encryption" {
  description = "Encrypt Kubernetes secrets at the application layer with a Cloud KMS key created by this module."
  type        = bool
  default     = true
}

variable "kms_rotation_period_days" {
  description = "Rotation period of the KMS key in days."
  type        = number
  default     = 90

  validation {
    condition     = var.kms_rotation_period_days >= 1 && var.kms_rotation_period_days <= 3650 && floor(var.kms_rotation_period_days) == var.kms_rotation_period_days
    error_message = "kms_rotation_period_days must be a whole number between 1 and 3650."
  }
}

variable "kms_name_suffix" {
  description = "Optional suffix for the key ring name. Key rings cannot be deleted, so set a new suffix (for example \"-2\") to recreate the cluster after a destroy."
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^[a-z0-9-]{0,16}$", var.kms_name_suffix))
    error_message = "kms_name_suffix must be at most 16 characters of lowercase letters, digits and hyphens."
  }
}

# --- Logging and monitoring ---

variable "logging_components" {
  description = "Components that send logs to Cloud Logging."
  type        = list(string)
  default     = ["SYSTEM_COMPONENTS"]

  validation {
    condition     = length(var.logging_components) >= 1 && alltrue([for c in var.logging_components : contains(["SYSTEM_COMPONENTS", "APISERVER", "SCHEDULER", "CONTROLLER_MANAGER", "WORKLOADS"], c)])
    error_message = "logging_components must be a non-empty list of: SYSTEM_COMPONENTS, APISERVER, SCHEDULER, CONTROLLER_MANAGER, WORKLOADS."
  }
}

variable "monitoring_components" {
  description = "Components that send metrics to Cloud Monitoring."
  type        = list(string)
  default     = ["SYSTEM_COMPONENTS"]

  validation {
    condition = length(var.monitoring_components) >= 1 && alltrue([
      for c in var.monitoring_components : contains(
        ["SYSTEM_COMPONENTS", "APISERVER", "SCHEDULER", "CONTROLLER_MANAGER", "STORAGE", "HPA", "POD", "DAEMONSET", "DEPLOYMENT", "STATEFULSET", "KUBELET", "CADVISOR"],
        c,
      )
    ])
    error_message = "monitoring_components contains an unsupported component."
  }
}

variable "enable_managed_prometheus" {
  description = "Enable Google Cloud Managed Service for Prometheus."
  type        = bool
  default     = false
}

# --- Node pool ---

variable "machine_type" {
  description = "Machine type of the nodes."
  type        = string
  default     = "e2-standard-2"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]*-[a-z0-9-]+$", var.machine_type))
    error_message = "machine_type must look like a Compute Engine machine type, for example e2-standard-2."
  }
}

variable "spot" {
  description = "Use Spot VMs for the nodes. Cheap, but they can be reclaimed at any time."
  type        = bool
  default     = true
}

variable "min_node_count" {
  description = "Minimum nodes per zone for the autoscaler."
  type        = number
  default     = 1

  validation {
    condition     = var.min_node_count >= 0 && floor(var.min_node_count) == var.min_node_count
    error_message = "min_node_count must be a whole number of zero or more."
  }
}

variable "max_node_count" {
  description = "Maximum nodes per zone for the autoscaler."
  type        = number
  default     = 3

  validation {
    condition     = var.max_node_count >= 1 && var.max_node_count >= var.min_node_count && floor(var.max_node_count) == var.max_node_count
    error_message = "max_node_count must be a whole number of at least 1 and not less than min_node_count."
  }
}

variable "disk_size_gb" {
  description = "Boot disk size in GiB for each node."
  type        = number
  default     = 50

  validation {
    condition     = var.disk_size_gb >= 20 && var.disk_size_gb <= 1000
    error_message = "disk_size_gb must be between 20 and 1000."
  }
}

variable "disk_type" {
  description = "Boot disk type for each node."
  type        = string
  default     = "pd-balanced"

  validation {
    condition     = contains(["pd-standard", "pd-balanced", "pd-ssd"], var.disk_type)
    error_message = "disk_type must be one of: pd-standard, pd-balanced, pd-ssd."
  }
}

variable "node_labels" {
  description = "Kubernetes labels applied to the nodes."
  type        = map(string)
  default     = {}
}

variable "labels" {
  description = "Additional resource labels merged onto the cluster and nodes."
  type        = map(string)
  default     = {}
}
