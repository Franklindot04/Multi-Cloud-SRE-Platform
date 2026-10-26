variable "role_name" {
  description = "Name of the IAM role (at most 64 characters)."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9+=,.@_-]{3,64}$", var.role_name))
    error_message = "role_name must be 3-64 characters of letters, digits and + = , . @ _ -."
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

variable "oidc_provider_arn" {
  description = "ARN of the cluster's IAM OIDC provider, from the aws-eks module."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:oidc-provider/.+$", var.oidc_provider_arn))
    error_message = "oidc_provider_arn must be the ARN of an IAM OIDC provider."
  }
}

variable "oidc_issuer_host" {
  description = "OIDC issuer without the https:// scheme, as used in trust policy condition keys (the aws-eks module's oidc_issuer_host output)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9.-]+\\.amazonaws\\.com(\\.cn)?/id/[A-Za-z0-9]+$", var.oidc_issuer_host))
    error_message = "oidc_issuer_host must be an EKS OIDC issuer host and path without a scheme, for example oidc.eks.eu-north-1.amazonaws.com/id/EXAMPLE."
  }
}

variable "namespace" {
  description = "Kubernetes namespace of the service account allowed to assume the role."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", var.namespace))
    error_message = "namespace must be a valid Kubernetes namespace name."
  }
}

variable "service_account_name" {
  description = "Name of the Kubernetes service account allowed to assume the role."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$", var.service_account_name))
    error_message = "service_account_name must be a valid Kubernetes service account name."
  }
}

variable "policy_json" {
  description = "IAM policy document (JSON) attached to the role as an inline policy."
  type        = string

  validation {
    condition     = can(jsondecode(var.policy_json))
    error_message = "policy_json must be valid JSON."
  }

  validation {
    condition     = try(contains(keys(jsondecode(var.policy_json)), "Statement"), false)
    error_message = "policy_json must be an IAM policy document with a Statement element."
  }
}

variable "policy_name" {
  description = "Name of the inline policy."
  type        = string
  default     = "permissions"

  validation {
    condition     = can(regex("^[a-zA-Z0-9+=,.@_-]{1,128}$", var.policy_name))
    error_message = "policy_name must be 1-128 characters of letters, digits and + = , . @ _ -."
  }
}

variable "tags" {
  description = "Additional tags merged onto all resources."
  type        = map(string)
  default     = {}
}
