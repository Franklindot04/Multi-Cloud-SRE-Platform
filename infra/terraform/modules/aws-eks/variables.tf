variable "cluster_name" {
  description = "Name of the EKS cluster. Also used as the prefix for IAM roles and other resources."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,38}[a-z0-9]$", var.cluster_name))
    error_message = "cluster_name must be 3-40 characters of lowercase letters, digits and hyphens, starting with a letter."
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

variable "kubernetes_version" {
  description = "Kubernetes minor version for the control plane, for example \"1.37\". Choose a version in EKS standard support."
  type        = string

  validation {
    condition     = can(regex("^1\\.[0-9]{2}$", var.kubernetes_version))
    error_message = "kubernetes_version must be a minor version such as \"1.37\"."
  }
}

variable "control_plane_subnet_ids" {
  description = "Subnets for the control plane network interfaces (at least two, in different zones). Public and private subnets may be mixed."
  type        = list(string)

  validation {
    condition     = length(var.control_plane_subnet_ids) >= 2
    error_message = "control_plane_subnet_ids must contain at least two subnets."
  }
}

variable "node_subnet_ids" {
  description = "Private subnets for worker nodes (at least two, in different zones)."
  type        = list(string)

  validation {
    condition     = length(var.node_subnet_ids) >= 2
    error_message = "node_subnet_ids must contain at least two subnets."
  }
}

# --- Endpoint access ---

variable "endpoint_public_access" {
  description = "Whether the Kubernetes API endpoint is reachable from the internet. The private endpoint is always enabled."
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public API endpoint. Restrict this to your own address (a /32) whenever possible."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.public_access_cidrs) >= 1
    error_message = "public_access_cidrs must contain at least one CIDR block."
  }

  validation {
    condition     = alltrue([for c in var.public_access_cidrs : can(cidrhost(c, 0))])
    error_message = "Every entry in public_access_cidrs must be a valid CIDR block."
  }
}

# --- Access ---

variable "admin_principal_arns" {
  description = "IAM user or role ARNs granted cluster admin through EKS access entries. For roles, use the plain role ARN without a path."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.admin_principal_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(user|role)/.+$", a))])
    error_message = "Every entry in admin_principal_arns must be an IAM user or role ARN."
  }
}

variable "bootstrap_cluster_creator_admin_permissions" {
  description = "Grant the identity that creates the cluster admin access. Keep true until admin_principal_arns is in use."
  type        = bool
  default     = true
}

# --- Secrets encryption and logging ---

variable "enable_secrets_encryption" {
  description = "Encrypt Kubernetes secrets with a dedicated KMS key (rotation enabled)."
  type        = bool
  default     = true
}

variable "kms_deletion_window_days" {
  description = "Days the KMS key stays in pending deletion after it is destroyed."
  type        = number
  default     = 7

  validation {
    condition     = var.kms_deletion_window_days >= 7 && var.kms_deletion_window_days <= 30
    error_message = "kms_deletion_window_days must be between 7 and 30."
  }
}

variable "enabled_log_types" {
  description = "Control plane log types sent to CloudWatch Logs."
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  validation {
    condition     = alltrue([for t in var.enabled_log_types : contains(["api", "audit", "authenticator", "controllerManager", "scheduler"], t)])
    error_message = "enabled_log_types may only contain: api, audit, authenticator, controllerManager, scheduler."
  }
}

variable "log_retention_days" {
  description = "Retention in days for the control plane log group. Must be a value CloudWatch Logs supports."
  type        = number
  default     = 14

  validation {
    condition = contains(
      [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
      var.log_retention_days,
    )
    error_message = "log_retention_days must be a retention period supported by CloudWatch Logs (for example 7, 14, 30, 90)."
  }
}

# --- Managed node group ---

variable "instance_types" {
  description = "Instance types for the managed node group. List several for Spot to improve capacity availability."
  type        = list(string)
  default     = ["t3.large", "m5.large"]

  validation {
    condition     = length(var.instance_types) >= 1 && alltrue([for t in var.instance_types : can(regex("^[a-z][a-z0-9-]*[0-9]*[a-z]*\\.[a-z0-9]+$", t))])
    error_message = "instance_types must be a non-empty list of EC2 instance types such as \"t3.large\"."
  }
}

variable "capacity_type" {
  description = "Node capacity type: SPOT (cheap, can be interrupted) or ON_DEMAND."
  type        = string
  default     = "SPOT"

  validation {
    condition     = contains(["SPOT", "ON_DEMAND"], var.capacity_type)
    error_message = "capacity_type must be SPOT or ON_DEMAND."
  }
}

variable "ami_type" {
  description = "Node AMI type. Amazon Linux 2023 is the only family offered for current Kubernetes versions."
  type        = string
  default     = "AL2023_x86_64_STANDARD"

  validation {
    condition     = contains(["AL2023_x86_64_STANDARD", "AL2023_ARM_64_STANDARD"], var.ami_type)
    error_message = "ami_type must be AL2023_x86_64_STANDARD or AL2023_ARM_64_STANDARD."
  }
}

variable "min_size" {
  description = "Minimum number of nodes."
  type        = number
  default     = 1

  validation {
    condition     = var.min_size >= 0 && floor(var.min_size) == var.min_size
    error_message = "min_size must be a whole number of zero or more."
  }
}

variable "desired_size" {
  description = "Desired number of nodes. Must be between min_size and max_size."
  type        = number
  default     = 2

  validation {
    condition     = var.desired_size >= var.min_size && var.desired_size <= var.max_size && floor(var.desired_size) == var.desired_size
    error_message = "desired_size must be a whole number between min_size and max_size."
  }
}

variable "max_size" {
  description = "Maximum number of nodes."
  type        = number
  default     = 4

  validation {
    condition     = var.max_size >= 1 && var.max_size >= var.min_size && floor(var.max_size) == var.max_size
    error_message = "max_size must be a whole number of at least 1 and not less than min_size."
  }
}

variable "disk_size_gb" {
  description = "Root volume size in GiB for each node."
  type        = number
  default     = 30

  validation {
    condition     = var.disk_size_gb >= 20 && var.disk_size_gb <= 500
    error_message = "disk_size_gb must be between 20 and 500."
  }
}

variable "node_labels" {
  description = "Kubernetes labels applied to the nodes."
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Additional tags merged onto all resources."
  type        = map(string)
  default     = {}
}
