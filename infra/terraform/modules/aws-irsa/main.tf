locals {
  tags = merge(var.tags, {
    environment  = var.environment
    "managed-by" = "terraform"
  })

  subject = "system:serviceaccount:${var.namespace}:${var.service_account_name}"
}

resource "aws_iam_role" "this" {
  name = var.role_name

  # Only the named service account in the named namespace, on this cluster, can assume the role.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_issuer_host}:aud" = "sts.amazonaws.com"
          "${var.oidc_issuer_host}:sub" = local.subject
        }
      }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "this" {
  name   = var.policy_name
  role   = aws_iam_role.this.id
  policy = var.policy_json
}
