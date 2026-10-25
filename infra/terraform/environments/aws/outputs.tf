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
