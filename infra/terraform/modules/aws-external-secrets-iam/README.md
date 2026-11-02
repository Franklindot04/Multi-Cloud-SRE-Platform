# aws-external-secrets-iam

The IAM role for the External Secrets Operator on EKS (IAM roles for service accounts). It wraps [aws-irsa](../aws-irsa) with one policy: read the SecureString parameters below `/<parameter_prefix>/<environment>/` in Systems Manager Parameter Store, and decrypt them through SSM. Nothing here writes or creates a parameter; the values are written by `scripts/seed-secrets.sh` and never pass through Terraform or its state.

## Usage

```hcl
module "external_secrets_irsa" {
  source = "../../modules/aws-external-secrets-iam"

  role_name         = "multi-cloud-sre-dev-external-secrets"
  environment       = "dev"
  parameter_prefix  = "multi-cloud-sre"
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_issuer_host  = module.eks.oidc_issuer_host
}
```

Annotate the operator's service account with the `role_arn` output (`eks.amazonaws.com/role-arn`).

## The policy

| Statement | Actions | Resource | Condition |
| --- | --- | --- | --- |
| `ReadSecretParameters` | `ssm:GetParameter`, `ssm:GetParameters` | `arn:<partition>:ssm:<region>:<account>:parameter/<prefix>/<environment>/*` | none |
| `DecryptThroughSsm` | `kms:Decrypt` | `arn:<partition>:kms:<region>:<account>:key/*`, or `kms_key_arn` when set | `kms:ViaService` equals `ssm.<region>.amazonaws.com` |

No write action, no wildcard action, and nothing outside the prefix. The role trusts only the service account `external-secrets` in the namespace `external-secrets` (both are variables), with the audience `sts.amazonaws.com`.

**Why the key is not looked up.** The parameters use the AWS-managed key `alias/aws/ssm`, which AWS creates in an account when the first SecureString is written in a region. A data source for the alias would fail on a new account, and Terraform creates this role before the first parameter exists. So the permission is on the keys of the account and region, limited to use through SSM in this region, and a key policy still has to allow it. Set `kms_key_arn` once the key exists to pin the permission to it.

**Why not the Terraform KMS key.** That key is destroyed and recreated with every cluster, and parameters encrypted with it would be unreadable after a rebuild. A production setup would use a customer-managed key with its own lifecycle, created outside the cluster stack, and pass its ARN in `kms_key_arn`.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `role_name` | `string` | n/a | IAM role name (3-64 characters). |
| `environment` | `string` | n/a | One of `dev`, `staging`, `prod`; part of the parameter path. |
| `parameter_prefix` | `string` | `"multi-cloud-sre"` | First path segment, lower case letters, digits and hyphens. |
| `oidc_provider_arn` | `string` | n/a | ARN of the cluster's IAM OIDC provider. |
| `oidc_issuer_host` | `string` | n/a | OIDC issuer host and path without `https://`. |
| `namespace` | `string` | `"external-secrets"` | Namespace of the operator's service account. |
| `service_account_name` | `string` | `"external-secrets"` | The operator's service account. |
| `kms_key_arn` | `string` | `""` | Pin the decrypt permission to this key. |
| `tags` | `map(string)` | `{}` | Additional tags. |

## Outputs

| Name | Description |
| --- | --- |
| `role_arn` | Role ARN |
| `role_name` | Role name |
| `service_account_subject` | Trusted subject |
| `parameter_prefix` | Full path, `/<prefix>/<environment>` |
| `policy_json` | The inline policy |
| `trust_policy_json` | The trust policy |

## Tests

Plan-only tests with a mocked provider run without credentials. They check the trust policy subject, the resource scope, the `ViaService` condition and that no write or wildcard action is in the policy:

```bash
terraform init -backend=false
terraform test
```

## Requirements

Terraform 1.11 or later and the AWS provider 6.0 or later.
