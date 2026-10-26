output "network_name" {
  description = "Name of the VPC network."
  value       = module.network.network_name
}

output "network_id" {
  description = "ID of the VPC network."
  value       = module.network.network_id
}

output "subnet_name" {
  description = "Name of the node subnet."
  value       = module.network.subnet_name
}

output "pods_range_name" {
  description = "Secondary range name for GKE pods."
  value       = module.network.pods_range_name
}

output "services_range_name" {
  description = "Secondary range name for GKE services."
  value       = module.network.services_range_name
}

output "node_cidr" {
  description = "CIDR range of the node subnet."
  value       = module.network.node_cidr
}

output "pods_cidr" {
  description = "CIDR range of the pods secondary range."
  value       = module.network.pods_cidr
}

output "services_cidr" {
  description = "CIDR range of the services secondary range."
  value       = module.network.services_cidr
}

output "nat_name" {
  description = "Name of the Cloud NAT gateway (null when disabled)."
  value       = module.network.nat_name
}

output "cluster_name" {
  description = "Name of the GKE cluster."
  value       = module.gke.cluster_name
}

output "cluster_endpoint" {
  description = "GKE control plane endpoint."
  value       = module.gke.cluster_endpoint
}

output "cluster_location" {
  description = "Zone or region of the GKE cluster."
  value       = module.gke.location
}

output "workload_pool" {
  description = "Workload Identity pool of the cluster."
  value       = module.gke.workload_pool
}

output "node_service_account_email" {
  description = "Email of the dedicated GKE node service account."
  value       = module.gke.node_service_account_email
}

output "kms_key_id" {
  description = "ID of the KMS key encrypting Kubernetes secrets."
  value       = module.gke.kms_key_id
}

output "get_credentials_command" {
  description = "Command that writes this cluster's credentials into your kubeconfig."
  value       = module.gke.get_credentials_command
}

output "dns_zone_name" {
  description = "Name of the Cloud DNS zone (null when no DNS name is set)."
  value       = module.dns.zone_name
}

output "dns_zone_id" {
  description = "ID of the Cloud DNS zone (null when no DNS name is set)."
  value       = module.dns.zone_id
}

output "dns_name_servers" {
  description = "Cloud DNS name servers. Pass these to the AWS stack as delegated_subdomains."
  value       = module.dns.name_servers
}

output "external_dns_service_account_email" {
  description = "Google service account email for the external-dns service account annotation (null when disabled)."
  value       = one(google_service_account.external_dns[*].email)
}

output "cert_manager_service_account_email" {
  description = "Google service account email for the cert-manager service account annotation (null when disabled)."
  value       = one(google_service_account.cert_manager[*].email)
}
