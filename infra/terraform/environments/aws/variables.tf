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

variable "domain_name" {
  description = "Domain for the Route 53 hosted zone, for example example.com. Empty (the default) creates no DNS resources."
  type        = string
  default     = ""
}

variable "delegated_subdomains" {
  description = "Subdomain label to name servers, delegating the subdomain to another cloud. Use the dns_name_servers output of the GCP stack."
  type        = map(list(string))
  default     = {}
}

variable "dns_endpoints" {
  description = "Application endpoints keyed aws and gcp, each with fqdn or ip and optional health check settings. Empty creates no records or health checks."
  type = map(object({
    fqdn              = optional(string)
    ip                = optional(string)
    port              = optional(number, 443)
    protocol          = optional(string, "HTTPS")
    path              = optional(string, "/healthz")
    failure_threshold = optional(number, 3)
    request_interval  = optional(number, 30)
  }))
  default = {}
}

variable "dns_enable_health_checks" {
  description = "Create Route 53 health checks for the endpoints. They bill monthly."
  type        = bool
  default     = true
}

variable "app_hostname" {
  description = "Host label of the application record, for example app for app.example.com."
  type        = string
  default     = "app"
}

variable "routing_policy" {
  description = "Traffic steering between clouds: weighted (normal operation) or failover (disaster recovery)."
  type        = string
  default     = "weighted"
}

variable "dns_weights" {
  description = "Relative weights per cloud for the weighted policy."
  type = object({
    aws = optional(number, 50)
    gcp = optional(number, 50)
  })
  default = {}
}

variable "primary_cloud" {
  description = "Cloud that serves traffic under the failover policy."
  type        = string
  default     = "aws"
}

variable "dns_record_ttl" {
  description = "TTL in seconds for the application records."
  type        = number
  default     = 60
}

variable "enable_load_balancer_controller_iam" {
  description = "Create the IAM role for the AWS Load Balancer Controller add-on."
  type        = bool
  default     = true
}

variable "enable_external_dns_iam" {
  description = "Create the IAM role for the external-dns add-on. Needs a hosted zone (domain_name or addons_hosted_zone_id)."
  type        = bool
  default     = false
}

variable "enable_cert_manager_iam" {
  description = "Create the IAM role for cert-manager Route 53 DNS-01 challenges. Needs a hosted zone (domain_name or addons_hosted_zone_id)."
  type        = bool
  default     = false
}

variable "addons_hosted_zone_id" {
  description = "Route 53 hosted zone ID the DNS add-on roles may change. Defaults to the zone created from domain_name."
  type        = string
  default     = ""

  validation {
    condition     = var.addons_hosted_zone_id != "" || var.domain_name != "" || !(var.enable_external_dns_iam || var.enable_cert_manager_iam)
    error_message = "The DNS add-on roles need a hosted zone: set domain_name or addons_hosted_zone_id, or disable enable_external_dns_iam and enable_cert_manager_iam."
  }

  validation {
    condition     = var.addons_hosted_zone_id == "" || can(regex("^Z[A-Z0-9]{6,31}$", var.addons_hosted_zone_id))
    error_message = "addons_hosted_zone_id must be a Route 53 hosted zone ID such as Z0123456789ABCDEFGHIJ."
  }
}
