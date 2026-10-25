# GCP environment stack

Root Terraform stack for the GCP side of the platform. It currently contains only backend, provider and variable definitions; resources arrive in later changes by composing modules from [`../../modules`](../../modules).

## Files

| File | Purpose |
| --- | --- |
| `backend.tf` | GCS backend, partial configuration |
| `backend.hcl.example` | Template for the per-environment backend values |
| `providers.tf` | Google provider with default labels |
| `versions.tf` | Terraform and provider version constraints |
| `variables.tf` | Inputs (`project_id` and `environment` are required) |

Default labels applied to every resource: `project`, `environment`, `managed-by`, `owner`.

## Backend placeholders

The bucket and state prefix are supplied at init time:

| Placeholder | Meaning |
| --- | --- |
| `<STATE_BUCKET_NAME>` | Output `state_bucket_name` of [`bootstrap/gcp`](../../bootstrap/gcp) |
| `<ENVIRONMENT>` | `dev`, `staging` or `prod`; used as the state prefix |

The real backend file (`backend.<environment>.hcl`) is local only and ignored by Git. Create it by copying the tracked `backend.hcl.example`:

```bash
cp backend.hcl.example backend.dev.hcl   # replace the placeholders
terraform init -backend-config=backend.dev.hcl
terraform plan -var environment=dev -var project_id=<PROJECT_ID>
```

## Validate without a backend

```bash
terraform init -backend=false
terraform validate
```
