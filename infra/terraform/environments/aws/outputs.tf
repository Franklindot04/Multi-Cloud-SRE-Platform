output "vpc_id" {
  description = "ID of the VPC."
  value       = module.network.vpc_id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC."
  value       = module.network.vpc_cidr_block
}

output "availability_zones" {
  description = "Availability zones used by the network."
  value       = module.network.availability_zones
}

output "public_subnet_ids" {
  description = "IDs of the public subnets."
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "IDs of the private subnets."
  value       = module.network.private_subnet_ids
}

output "nat_public_ips" {
  description = "Public IP addresses of the NAT gateways."
  value       = module.network.nat_public_ips
}

output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider for IAM roles for service accounts."
  value       = module.eks.oidc_provider_arn
}

output "node_role_arn" {
  description = "ARN of the node IAM role."
  value       = module.eks.node_role_arn
}

output "kms_key_arn" {
  description = "ARN of the KMS key encrypting Kubernetes secrets."
  value       = module.eks.kms_key_arn
}

output "kubeconfig_command" {
  description = "Command that writes this cluster's credentials into your kubeconfig."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}
