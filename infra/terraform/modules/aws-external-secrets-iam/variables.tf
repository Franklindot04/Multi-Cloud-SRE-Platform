variable "role_name" {
  description = "Name of the IAM role (at most 64 characters)."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9+=,.@_-]{3,64}$", var.role_name))
    error_message = "role_name must be 3-64 characters of letters, digits and + = , . @ _ -."
  }
}

variable "environment" {
  description = "Environment name. It is part of the parameter path."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "parameter_prefix" {
  description = "First segment of the parameter path: /<parameter_prefix>/<environment>/<component>/<name>."
  type        = string
  default     = "multi-cloud-sre"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$", var.parameter_prefix))
    error_message = "parameter_prefix must be one lower-case path segment of letters, digits and hyphens, such as multi-cloud-sre."
  }
}

variable "oidc_provider_arn" {
  description = "ARN of the cluster's IAM OIDC provider, from the aws-eks module."
  type        = string
}

variable "oidc_issuer_host" {
  description = "OIDC issuer without the https:// scheme, from the aws-eks module's oidc_issuer_host output."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace of the External Secrets Operator's service account."
  type        = string
  default     = "external-secrets"
}

variable "service_account_name" {
  description = "Name of the External Secrets Operator's service account."
  type        = string
  default     = "external-secrets"
}

variable "kms_key_arn" {
  description = "ARN of the AWS-managed SSM key (alias/aws/ssm) to pin the decrypt permission to. Empty means any key in this account and region, used through SSM only; see the comment in main.tf."
  type        = string
  default     = ""

  validation {
    condition     = var.kms_key_arn == "" || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[0-9a-f-]{36}$", var.kms_key_arn))
    error_message = "kms_key_arn must be empty or the ARN of a KMS key."
  }
}

variable "tags" {
  description = "Additional tags merged onto all resources."
  type        = map(string)
  default     = {}
}
