# IAM roles for the cluster add-ons (IAM roles for service accounts). The role ARNs are outputs to paste
# into the add-on values files under platform/addons. Nothing here installs the add-ons.

data "aws_partition" "current" {}

locals {
  # Hosted zone the DNS add-ons may change: an explicit ID, or the zone created by this stack.
  addons_hosted_zone_id = var.addons_hosted_zone_id != "" ? var.addons_hosted_zone_id : module.dns.zone_id
  hosted_zone_arn       = "arn:${data.aws_partition.current.partition}:route53:::hostedzone/${coalesce(local.addons_hosted_zone_id, "unset")}"

  external_dns_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets"]
        Resource = [local.hosted_zone_arn]
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ListHostedZones", "route53:ListResourceRecordSets", "route53:ListTagsForResource"]
        Resource = ["*"]
      },
    ]
  })

  cert_manager_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["route53:GetChange"]
        Resource = ["arn:${data.aws_partition.current.partition}:route53:::change/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"]
        Resource = [local.hosted_zone_arn]
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ListHostedZonesByName"]
        Resource = ["*"]
      },
    ]
  })
}

# --- AWS Load Balancer Controller (official policy, vendored) ---

module "lbc_irsa" {
  count  = var.enable_load_balancer_controller_iam ? 1 : 0
  source = "../../modules/aws-irsa"

  role_name            = "${local.cluster_name}-lbc"
  environment          = var.environment
  oidc_provider_arn    = module.eks.oidc_provider_arn
  oidc_issuer_host     = module.eks.oidc_issuer_host
  namespace            = "kube-system"
  service_account_name = "aws-load-balancer-controller"
  policy_json          = file("${path.module}/policies/aws-load-balancer-controller.json")
}

# --- external-dns (Route 53, one hosted zone) ---

module "external_dns_irsa" {
  count  = var.enable_external_dns_iam ? 1 : 0
  source = "../../modules/aws-irsa"

  role_name            = "${local.cluster_name}-external-dns"
  environment          = var.environment
  oidc_provider_arn    = module.eks.oidc_provider_arn
  oidc_issuer_host     = module.eks.oidc_issuer_host
  namespace            = "external-dns"
  service_account_name = "external-dns"
  policy_json          = local.external_dns_policy
}

# --- cert-manager (Route 53 DNS-01, one hosted zone) ---

module "cert_manager_irsa" {
  count  = var.enable_cert_manager_iam ? 1 : 0
  source = "../../modules/aws-irsa"

  role_name            = "${local.cluster_name}-cert-manager"
  environment          = var.environment
  oidc_provider_arn    = module.eks.oidc_provider_arn
  oidc_issuer_host     = module.eks.oidc_issuer_host
  namespace            = "cert-manager"
  service_account_name = "cert-manager"
  policy_json          = local.cert_manager_policy
}
