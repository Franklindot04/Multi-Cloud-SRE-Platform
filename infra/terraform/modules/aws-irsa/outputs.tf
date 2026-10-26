output "role_arn" {
  description = "ARN of the IAM role. Set it as the eks.amazonaws.com/role-arn annotation on the service account."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "Name of the IAM role."
  value       = aws_iam_role.this.name
}

output "service_account_subject" {
  description = "Subject the role trusts, in the form system:serviceaccount:<namespace>:<name>."
  value       = local.subject
}

output "service_account_annotations" {
  description = "Annotations to set on the Kubernetes service account."
  value       = { "eks.amazonaws.com/role-arn" = aws_iam_role.this.arn }
}
