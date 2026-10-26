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

output "dns_zone_id" {
  description = "ID of the Route 53 hosted zone (null when no domain is set)."
  value       = module.dns.zone_id
}

output "dns_name_servers" {
  description = "Route 53 name servers to set at the domain registrar."
  value       = module.dns.name_servers
}

output "dns_health_check_ids" {
  description = "IDs of the Route 53 health checks, keyed by cloud."
  value       = module.dns.health_check_ids
}

output "app_fqdn" {
  description = "Fully qualified name of the application record (null when no domain is set)."
  value       = module.dns.app_fqdn
}

output "aws_load_balancer_controller_role_arn" {
  description = "IAM role ARN for the AWS Load Balancer Controller service account annotation (null when disabled)."
  value       = one(module.lbc_irsa[*].role_arn)
}

output "external_dns_role_arn" {
  description = "IAM role ARN for the external-dns service account annotation (null when disabled)."
  value       = one(module.external_dns_irsa[*].role_arn)
}

output "cert_manager_role_arn" {
  description = "IAM role ARN for the cert-manager service account annotation (null when disabled)."
  value       = one(module.cert_manager_irsa[*].role_arn)
}

output "region" {
  description = "AWS region of this stack."
  value       = var.region
}

output "account_id" {
  description = "ID of the AWS account this stack runs in. Used by the Argo CD bootstrap to confirm it is talking to the right account."
  value       = data.aws_caller_identity.current.account_id
}
