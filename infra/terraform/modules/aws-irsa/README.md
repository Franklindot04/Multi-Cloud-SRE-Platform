# aws-irsa

A generic IAM role for a Kubernetes service account on EKS (IAM roles for service accounts). The role trusts the cluster's OIDC provider for exactly one namespace and service account, and carries one inline policy.

## Usage

```hcl
module "external_dns_irsa" {
  source = "../../modules/aws-irsa"

  role_name            = "multi-cloud-sre-dev-external-dns"
  environment          = "dev"
  oidc_provider_arn    = module.eks.oidc_provider_arn
  oidc_issuer_host     = module.eks.oidc_issuer_host
  namespace            = "external-dns"
  service_account_name = "external-dns"
  policy_json          = file("${path.module}/policies/external-dns.json")
}
```

Annotate the service account with the `service_account_annotations` output (`eks.amazonaws.com/role-arn`).

## Trust policy

The role can be assumed with `sts:AssumeRoleWithWebIdentity` only when the token's audience is `sts.amazonaws.com` and its subject is `system:serviceaccount:<namespace>:<service account>`. There is no wildcard.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `role_name` | `string` | n/a | IAM role name (3-64 characters). |
| `environment` | `string` | n/a | One of `dev`, `staging`, `prod`. |
| `oidc_provider_arn` | `string` | n/a | ARN of the cluster's IAM OIDC provider. |
| `oidc_issuer_host` | `string` | n/a | OIDC issuer host and path without `https://`. |
| `namespace` | `string` | n/a | Kubernetes namespace of the service account. |
| `service_account_name` | `string` | n/a | Kubernetes service account name. |
| `policy_json` | `string` | n/a | Inline policy document (valid JSON with a `Statement`). |
| `policy_name` | `string` | `"permissions"` | Inline policy name. |
| `tags` | `map(string)` | `{}` | Additional tags. |

## Outputs

| Name | Description |
| --- | --- |
| `role_arn` | Role ARN |
| `role_name` | Role name |
| `service_account_subject` | Trusted subject (`system:serviceaccount:<ns>:<name>`) |
| `service_account_annotations` | Annotation map for the service account |

## Tests

Plan-only tests with a mocked provider run without credentials:

```bash
terraform init -backend=false
terraform test
```

## Requirements

Terraform 1.11 or later; AWS provider 6.0 or later.
