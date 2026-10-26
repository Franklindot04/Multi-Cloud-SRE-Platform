# GCP environment stack

Root Terraform stack for the GCP side of the platform. It currently provisions the VPC network by composing the [`gcp-network`](../../modules/gcp-network) module; GKE and other resources arrive in later changes.

## Files

| File | Purpose |
| --- | --- |
| `backend.tf` | GCS backend, partial configuration |
| `backend.hcl.example` | Template for the per-environment backend values |
| `network.tf` | VPC network via the `gcp-network` module |
| `outputs.tf` | Network, subnet, secondary range and NAT outputs |
| `providers.tf` | Google provider with default labels |
| `versions.tf` | Terraform and provider version constraints |
| `variables.tf` | Inputs (`project_id` and `environment` are required; network inputs have defaults) |

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

## Network inputs

| Variable | Default | Notes |
| --- | --- | --- |
| `cluster_name` | `<project>-<environment>` | Names the network and its secondary ranges; reused by GKE later |
| `vpc_cidr` | `10.20.0.0/16` | A private `/16`; use a different one for each environment ([ADR-0006](../../../../docs/adr/0006-aws-network-design.md)) |
| `nat_mode` | `enabled` | `enabled` or `none`; Cloud NAT is the main network cost |
| `flow_log_sampling` | `0.5` | 0 to 1; 0 turns subnet flow logs off |

Derived ranges for `10.20.0.0/16`: nodes `10.20.0.0/20`, services `10.20.16.0/20`, pods `10.20.64.0/18`. Prerequisites, apply and destroy steps, and the cost note are in the [GCP network runbook](../../../../docs/runbooks/gcp-network.md).

## Validate without a backend

```bash
terraform init -backend=false
terraform validate
```
