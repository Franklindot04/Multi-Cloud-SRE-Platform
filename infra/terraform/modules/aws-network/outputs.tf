output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "availability_zones" {
  description = "Availability zones used, in the same order as the subnet lists."
  value       = local.azs
}

output "public_subnet_ids" {
  description = "IDs of the public subnets, one per availability zone."
  value       = [for az in local.azs : aws_subnet.public[az].id]
}

output "private_subnet_ids" {
  description = "IDs of the private subnets, one per availability zone."
  value       = [for az in local.azs : aws_subnet.private[az].id]
}

output "public_route_table_id" {
  description = "ID of the public route table."
  value       = aws_route_table.public.id
}

output "private_route_table_ids" {
  description = "IDs of the private route tables, one per availability zone."
  value       = [for az in local.azs : aws_route_table.private[az].id]
}

output "nat_public_ips" {
  description = "Public IP addresses of the NAT gateways (empty when nat_mode is none)."
  value       = [for az in local.nat_azs : aws_eip.nat[az].public_ip]
}

output "s3_endpoint_id" {
  description = "ID of the S3 gateway endpoint."
  value       = aws_vpc_endpoint.s3.id
}

output "flow_log_group_name" {
  description = "Name of the CloudWatch log group receiving VPC flow logs."
  value       = aws_cloudwatch_log_group.flow_logs.name
}
