output "name_prefix" {
  description = "Prefix applied to resource names created by this module."
  value       = local.name_prefix
}

output "tags" {
  description = "Tags or labels applied to resources created by this module."
  value       = local.tags
}
