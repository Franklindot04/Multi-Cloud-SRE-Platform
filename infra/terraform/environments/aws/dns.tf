# DNS is off until domain_name is set. The GCP name servers for a delegated subdomain come in as a plain
# input (delegated_subdomains), so this stack never reads the GCP stack's state.
module "dns" {
  source = "../../modules/aws-dns"

  name        = var.project
  environment = var.environment

  domain_name          = var.domain_name
  delegated_subdomains = var.delegated_subdomains

  endpoints            = var.dns_endpoints
  enable_health_checks = var.dns_enable_health_checks
  app_hostname         = var.app_hostname
  routing_policy       = var.routing_policy
  weights              = var.dns_weights
  primary_cloud        = var.primary_cloud
  record_ttl           = var.dns_record_ttl
}
