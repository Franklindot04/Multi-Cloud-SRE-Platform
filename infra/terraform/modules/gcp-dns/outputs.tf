output "zone_name" {
  description = "Name of the managed zone (null when no DNS name is set)."
  value       = one(google_dns_managed_zone.this[*].name)
}

output "zone_id" {
  description = "ID of the managed zone (null when no DNS name is set)."
  value       = one(google_dns_managed_zone.this[*].id)
}

output "dns_name" {
  description = "DNS name of the zone with a trailing dot (null when no DNS name is set)."
  value       = local.zone_dns_name
}

output "name_servers" {
  description = "Name servers of the zone, to be used for delegation from the parent zone. Empty when no DNS name is set."
  value       = one(google_dns_managed_zone.this[*].name_servers) == null ? [] : one(google_dns_managed_zone.this[*].name_servers)
}
