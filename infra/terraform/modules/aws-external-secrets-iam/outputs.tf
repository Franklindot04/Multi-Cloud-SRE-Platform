output "role_arn" {
  description = "ARN of the IAM role. Set it as the eks.amazonaws.com/role-arn annotation on the External Secrets Operator's service account."
  value       = module.irsa.role_arn
}

output "role_name" {
  description = "Name of the IAM role."
  value       = module.irsa.role_name
}

output "service_account_subject" {
  description = "Subject the role trusts, in the form system:serviceaccount:<namespace>:<name>."
  value       = module.irsa.service_account_subject
}

output "parameter_prefix" {
  description = "Full parameter path the role may read and scripts/seed-secrets.sh writes to, in the form /<prefix>/<environment>."
  value       = local.parameter_path
}

output "policy_json" {
  description = "The inline policy of the role."
  value       = jsonencode(local.policy)
}

output "trust_policy_json" {
  description = "Trust policy of the role (JSON)."
  value       = module.irsa.assume_role_policy
}
