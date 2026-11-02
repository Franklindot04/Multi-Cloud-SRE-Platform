data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  # The path the operator may read, and the only one: /<prefix>/<environment>. The seed script
  # (scripts/seed-secrets.sh) writes below it, and nothing in Terraform creates a parameter.
  parameter_path = "/${var.parameter_prefix}/${var.environment}"
  parameter_arn  = "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${local.parameter_path}/*"

  # Decrypting a SecureString that uses the AWS-managed key alias/aws/ssm.
  #
  # The key is created by AWS in an account the first time a SecureString is written in a region, so it does not exist
  # before the seed script has run once. A data source for the alias would fail at plan time on a new account, and
  # Terraform applies this role before the first parameter exists. So the permission is on the keys of this account and
  # region, with kms:ViaService set to SSM in this region: the role can use a key only when SSM asks on its behalf, and
  # a key policy still has to allow it (the key policy of an AWS-managed key allows exactly that for principals of the
  # account). Set kms_key_arn once the key exists to pin the permission to the one key.
  #
  # The parameters use the AWS-managed key and not the Terraform KMS key of the cluster on purpose: that key is destroyed
  # and recreated with every cluster, and parameters encrypted with it would be unreadable after a rebuild. A production
  # setup would use a customer-managed key with its own lifecycle, created outside the cluster stack, and pass its ARN here.
  kms_resource = var.kms_key_arn != "" ? var.kms_key_arn : "arn:${data.aws_partition.current.partition}:kms:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:key/*"

  policy = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadSecretParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = [local.parameter_arn]
      },
      {
        Sid      = "DecryptThroughSsm"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [local.kms_resource]
        Condition = {
          StringEquals = {
            "kms:ViaService" = "ssm.${data.aws_region.current.region}.amazonaws.com"
          }
        }
      },
    ]
  }
}

module "irsa" {
  source = "../aws-irsa"

  role_name            = var.role_name
  environment          = var.environment
  oidc_provider_arn    = var.oidc_provider_arn
  oidc_issuer_host     = var.oidc_issuer_host
  namespace            = var.namespace
  service_account_name = var.service_account_name
  policy_name          = "read-secret-parameters"
  policy_json          = jsonencode(local.policy)
  tags                 = var.tags
}
