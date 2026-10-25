output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "ARN of the EKS cluster."
  value       = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded certificate authority data of the cluster."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "ID of the security group EKS created for the cluster."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider used for IAM roles for service accounts."
  value       = aws_iam_openid_connect_provider.this.arn
}

output "oidc_issuer" {
  description = "OIDC issuer URL of the cluster (with https://)."
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "oidc_issuer_host" {
  description = "OIDC issuer without the scheme, as used in IAM trust policy condition keys."
  value       = local.oidc_issuer_host
}

output "node_role_arn" {
  description = "ARN of the IAM role used by the managed node group."
  value       = aws_iam_role.node.arn
}

output "node_group_name" {
  description = "Name of the managed node group."
  value       = aws_eks_node_group.default.node_group_name
}

output "kms_key_arn" {
  description = "ARN of the KMS key encrypting Kubernetes secrets (null when encryption is disabled)."
  value       = one(aws_kms_key.secrets[*].arn)
}
