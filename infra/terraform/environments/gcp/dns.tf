# DNS is off until dns_name is set. This stack only creates the zone; its name servers are an output
# that is passed to the AWS stack as an input, so the stacks never depend on each other's state.
module "dns" {
  source = "../../modules/gcp-dns"

  project_id  = var.project_id
  name        = var.project
  environment = var.environment

  dns_name      = var.dns_name
  enable_dnssec = var.dns_enable_dnssec
  force_destroy = var.dns_force_destroy

  labels = {
    project = var.project
    owner   = var.owner
  }
}
