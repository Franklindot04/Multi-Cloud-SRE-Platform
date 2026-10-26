locals {
  name_prefix = "${var.name}-${var.environment}"

  tags = merge(var.tags, {
    environment  = var.environment
    "managed-by" = "terraform"
  })

  enabled = var.domain_name != ""

  app_fqdn = local.enabled ? "${var.app_hostname}.${var.domain_name}" : null

  # Records and health checks exist only when a domain is set and endpoints are supplied.
  endpoints = local.enabled ? var.endpoints : {}

  health_check_endpoints = var.enable_health_checks ? local.endpoints : {}

  weights = {
    aws = var.weights.aws
    gcp = var.weights.gcp
  }
}

resource "aws_route53_zone" "this" {
  count = local.enabled ? 1 : 0

  name    = var.domain_name
  comment = "Public zone for ${local.name_prefix}"

  tags = merge(local.tags, { Name = local.name_prefix })
}

# --- Delegated subdomains (for example a Cloud DNS zone) ---

resource "aws_route53_record" "delegation" {
  for_each = local.enabled ? var.delegated_subdomains : {}

  zone_id = aws_route53_zone.this[0].zone_id
  name    = "${each.key}.${var.domain_name}"
  type    = "NS"
  ttl     = 300
  records = each.value
}

# --- Health checks ---

resource "aws_route53_health_check" "this" {
  for_each = local.health_check_endpoints

  type              = each.value.protocol
  fqdn              = coalesce(each.value.fqdn, local.app_fqdn)
  ip_address        = each.value.ip
  port              = each.value.port
  resource_path     = each.value.protocol == "TCP" ? null : each.value.path
  failure_threshold = each.value.failure_threshold
  request_interval  = each.value.request_interval
  enable_sni        = each.value.protocol == "HTTPS" ? true : null

  tags = merge(local.tags, { Name = "${local.name_prefix}-${each.key}" })
}

# --- Application records ---

resource "aws_route53_record" "app" {
  for_each = local.endpoints

  zone_id        = aws_route53_zone.this[0].zone_id
  name           = local.app_fqdn
  type           = each.value.ip == null ? "CNAME" : "A"
  ttl            = var.record_ttl
  records        = [coalesce(each.value.ip, each.value.fqdn)]
  set_identifier = each.key

  health_check_id = var.enable_health_checks ? aws_route53_health_check.this[each.key].id : null

  dynamic "weighted_routing_policy" {
    for_each = var.routing_policy == "weighted" ? [1] : []

    content {
      weight = local.weights[each.key]
    }
  }

  dynamic "failover_routing_policy" {
    for_each = var.routing_policy == "failover" ? [1] : []

    content {
      type = each.key == var.primary_cloud ? "PRIMARY" : "SECONDARY"
    }
  }
}
