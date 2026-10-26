output "network_id" {
  description = "ID of the VPC network."
  value       = google_compute_network.this.id
}

output "network_name" {
  description = "Name of the VPC network."
  value       = google_compute_network.this.name
}

output "subnet_id" {
  description = "ID of the node subnet."
  value       = google_compute_subnetwork.nodes.id
}

output "subnet_name" {
  description = "Name of the node subnet."
  value       = google_compute_subnetwork.nodes.name
}

output "pods_range_name" {
  description = "Name of the secondary range for GKE pods."
  value       = local.pods_range_name
}

output "services_range_name" {
  description = "Name of the secondary range for GKE services."
  value       = local.services_range_name
}

output "router_name" {
  description = "Name of the Cloud Router (null when nat_mode is none)."
  value       = one(google_compute_router.this[*].name)
}

output "nat_name" {
  description = "Name of the Cloud NAT gateway (null when nat_mode is none)."
  value       = one(google_compute_router_nat.this[*].name)
}

output "node_cidr" {
  description = "CIDR range of the node subnet."
  value       = local.node_cidr
}

output "pods_cidr" {
  description = "CIDR range of the pods secondary range."
  value       = local.pods_cidr
}

output "services_cidr" {
  description = "CIDR range of the services secondary range."
  value       = local.services_cidr
}
