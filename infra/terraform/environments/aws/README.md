# AWS environment stack

Root Terraform stack for the AWS side of the platform. It currently contains only backend, provider and variable definitions; resources arrive in later changes by composing modules from [`../../modules`](../../modules).

## Files

| File | Purpose |
| --- | --- |
| `backend.tf` | S3 backend, partial configuration |
| `backend.hcl.example` | Template for the per-environment backend values |
| `providers.tf` | AWS provider with default tags |
| `versions.tf` | Terraform and provider version constraints |
| `variables.tf` | Inputs (`environment` is required) |

Default tags applied to every resource: `project`, `environment`, `managed-by`, `owner`.

## Backend placeholders

`backend.tf` fixes the region (`eu-north-1`), encryption and native locking. The bucket and state key are supplied at init time:

| Placeholder | Meaning |
| --- | --- |
| `<STATE_BUCKET_NAME>` | Output `state_bucket_name` of [`bootstrap/aws`](../../bootstrap/aws) |
| `<ENVIRONMENT>` | `dev`, `staging` or `prod`; used in the state key |

The real backend file (`backend.<environment>.hcl`) is local only and ignored by Git. Create it by copying the tracked `backend.hcl.example`:

```bash
cp backend.hcl.example backend.dev.hcl   # replace the placeholders
terraform init -backend-config=backend.dev.hcl
terraform plan -var environment=dev
```

## Validate without a backend

```bash
terraform init -backend=false
terraform validate
```
