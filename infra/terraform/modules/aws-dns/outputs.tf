output "zone_id" {
  description = "ID of the public hosted zone (null when no domain is set)."
  value       = one(aws_route53_zone.this[*].zone_id)
}

output "name_servers" {
  description = "Name servers of the hosted zone. Set these at the domain registrar. Empty when no domain is set."
  value       = one(aws_route53_zone.this[*].name_servers) == null ? [] : one(aws_route53_zone.this[*].name_servers)
}

output "health_check_ids" {
  description = "IDs of the health checks, keyed by cloud."
  value       = { for k, h in aws_route53_health_check.this : k => h.id }
}

output "app_fqdn" {
  description = "Fully qualified name of the application record (null when no domain is set)."
  value       = local.app_fqdn
}
