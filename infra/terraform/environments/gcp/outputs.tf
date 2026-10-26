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
