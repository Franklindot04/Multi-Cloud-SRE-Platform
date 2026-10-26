locals {
  name_prefix = "${var.name}-${var.environment}"

  labels = merge(var.labels, {
    environment  = var.environment
    "managed-by" = "terraform"
  })

  enabled = var.dns_name != ""

  # Cloud DNS names must end with a dot; accept the name with or without it.
  zone_dns_name = local.enabled ? "${trimsuffix(var.dns_name, ".")}." : null
}

resource "google_dns_managed_zone" "this" {
  count = local.enabled ? 1 : 0

  project       = var.project_id
  name          = local.name_prefix
  dns_name      = local.zone_dns_name
  description   = "Public zone for ${local.name_prefix}"
  visibility    = "public"
  force_destroy = var.force_destroy

  dnssec_config {
    state = var.enable_dnssec ? "on" : "off"
  }

  labels = local.labels
}
