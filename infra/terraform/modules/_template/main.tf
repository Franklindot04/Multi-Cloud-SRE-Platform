locals {
  name_prefix = "${var.name}-${var.environment}"

  tags = merge(var.tags, {
    environment  = var.environment
    "managed-by" = "terraform"
  })
}

# Resources go here. Name them "${local.name_prefix}-<purpose>" and apply local.tags.
# Take region, account and project values from inputs or data sources, never literals.
