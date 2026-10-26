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

variable "domain_name" {
  description = "Domain for the public hosted zone, for example example.com. Empty (the default) creates nothing."
  type        = string
  default     = ""

  validation {
    condition     = var.domain_name == "" || can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", var.domain_name))
    error_message = "domain_name must be empty or a lowercase DNS name without a trailing dot, such as example.com."
  }
}

variable "delegated_subdomains" {
  description = "Subdomains delegated to another DNS provider: a map of subdomain label to the list of name servers. Creates NS records in the zone."
  type        = map(list(string))
  default     = {}

  validation {
    condition     = alltrue([for label in keys(var.delegated_subdomains) : can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", label))])
    error_message = "Delegated subdomain keys must be single lowercase DNS labels, for example gke."
  }

  validation {
    condition     = alltrue([for ns in values(var.delegated_subdomains) : length(ns) >= 1])
    error_message = "Each delegated subdomain needs at least one name server."
  }

  validation {
    condition = alltrue(flatten([
      for ns in values(var.delegated_subdomains) : [
        for n in ns : can(regex("^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\\.)+[a-zA-Z]{2,63}\\.?$", n))
      ]
    ]))
    error_message = "Name servers must be valid host names, for example ns-cloud-a1.googledomains.com."
  }
}

variable "endpoints" {
  description = <<-EOT
    Application endpoints per cloud. Keys are "aws" and "gcp". Each endpoint has exactly one of fqdn (creates a CNAME)
    or ip (creates an A record), plus health check settings. All endpoints must use the same kind. Empty creates no
    records or health checks.
  EOT
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

  validation {
    condition     = alltrue([for k in keys(var.endpoints) : contains(["aws", "gcp"], k)])
    error_message = "endpoints may only contain the keys aws and gcp."
  }

  validation {
    condition     = alltrue([for e in values(var.endpoints) : (e.fqdn != null) != (e.ip != null)])
    error_message = "Each endpoint must set exactly one of fqdn or ip."
  }

  validation {
    condition     = alltrue([for e in values(var.endpoints) : e.fqdn == null || can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", e.fqdn))])
    error_message = "endpoint fqdn values must be lowercase DNS names without a trailing dot."
  }

  validation {
    condition     = alltrue([for e in values(var.endpoints) : e.ip == null || can(cidrhost("${e.ip}/32", 0))])
    error_message = "endpoint ip values must be IPv4 addresses."
  }

  validation {
    condition     = length(distinct([for e in values(var.endpoints) : e.ip == null ? "CNAME" : "A"])) <= 1
    error_message = "All endpoints must use the same kind (all fqdn or all ip): a CNAME cannot share a name with an A record."
  }

  validation {
    condition     = alltrue([for e in values(var.endpoints) : e.port >= 1 && e.port <= 65535])
    error_message = "endpoint port must be between 1 and 65535."
  }

  validation {
    condition     = alltrue([for e in values(var.endpoints) : contains(["HTTPS", "HTTP", "TCP"], e.protocol)])
    error_message = "endpoint protocol must be HTTPS, HTTP or TCP."
  }

  validation {
    condition     = alltrue([for e in values(var.endpoints) : startswith(e.path, "/")])
    error_message = "endpoint path must start with /."
  }

  validation {
    condition     = alltrue([for e in values(var.endpoints) : e.failure_threshold >= 1 && e.failure_threshold <= 10])
    error_message = "endpoint failure_threshold must be between 1 and 10."
  }

  validation {
    condition     = alltrue([for e in values(var.endpoints) : contains([10, 30], e.request_interval)])
    error_message = "endpoint request_interval must be 10 or 30 seconds."
  }
}

variable "enable_health_checks" {
  description = "Create a Route 53 health check for each endpoint and attach it to its record. Health checks bill monthly."
  type        = bool
  default     = true
}

variable "app_hostname" {
  description = "Host label of the application record, for example app for app.example.com."
  type        = string
  default     = "app"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.app_hostname))
    error_message = "app_hostname must be a single lowercase DNS label."
  }
}

variable "routing_policy" {
  description = "How traffic is steered between endpoints: \"weighted\" or \"failover\"."
  type        = string
  default     = "weighted"

  validation {
    condition     = contains(["weighted", "failover"], var.routing_policy)
    error_message = "routing_policy must be weighted or failover."
  }
}

variable "weights" {
  description = "Relative weights per cloud for the weighted policy."
  type = object({
    aws = optional(number, 50)
    gcp = optional(number, 50)
  })
  default = {}

  validation {
    condition     = alltrue([for w in [var.weights.aws, var.weights.gcp] : w >= 0 && w <= 255])
    error_message = "Weights must be between 0 and 255."
  }

  validation {
    condition     = var.weights.aws + var.weights.gcp > 0
    error_message = "At least one weight must be greater than zero."
  }
}

variable "primary_cloud" {
  description = "Cloud that serves traffic under the failover policy; the other is the secondary."
  type        = string
  default     = "aws"

  validation {
    condition     = contains(["aws", "gcp"], var.primary_cloud)
    error_message = "primary_cloud must be aws or gcp."
  }
}

variable "record_ttl" {
  description = "TTL in seconds for the application records. Keep it short so steering changes take effect quickly."
  type        = number
  default     = 60

  validation {
    condition     = var.record_ttl >= 1 && var.record_ttl <= 86400
    error_message = "record_ttl must be between 1 and 86400 seconds."
  }
}

variable "tags" {
  description = "Additional tags merged onto all resources."
  type        = map(string)
  default     = {}
}
