# GCP environment stack

Root Terraform stack for the GCP side of the platform. It currently provisions the VPC network and the GKE cluster by composing the [`gcp-network`](../../modules/gcp-network) and [`gcp-gke`](../../modules/gcp-gke) modules; other resources arrive in later changes.

## Files

| File | Purpose |
| --- | --- |
| `backend.tf` | GCS backend, partial configuration |
| `backend.hcl.example` | Template for the per-environment backend values |
| `network.tf` | VPC network via the `gcp-network` module |
| `gke.tf` | GKE cluster via the `gcp-gke` module |
| `outputs.tf` | Network, cluster and credentials outputs, including a `get-credentials` command |
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
| `cluster_name` | `<project>-<environment>` | Names the network, its secondary ranges and the GKE cluster (max 24 characters) |
| `vpc_cidr` | `10.20.0.0/16` | A private `/16`; use a different one for each environment ([ADR-0006](../../../../docs/adr/0006-aws-network-design.md)) |
| `nat_mode` | `enabled` | `enabled` or `none`; Cloud NAT is the main network cost |
| `flow_log_sampling` | `0.5` | 0 to 1; 0 turns subnet flow logs off |

Derived ranges for `10.20.0.0/16`: nodes `10.20.0.0/20`, services `10.20.16.0/20`, pods `10.20.64.0/18`. Prerequisites, apply and destroy steps, and the cost note are in the [GCP network runbook](../../../../docs/runbooks/gcp-network.md).

## Cluster inputs

| Variable | Default | Notes |
| --- | --- | --- |
| `gke_location` | `europe-north1-a` | A zone for a zonal cluster (cheaper) or a region for a regional one; must be in `region` |
| `gke_release_channel` | `REGULAR` | `RAPID`, `REGULAR` or `STABLE` |
| `master_authorized_cidrs` | `[]` | CIDRs allowed to reach the public control plane endpoint; add your own `/32` |
| `gke_machine_type` | `e2-standard-2` | |
| `gke_spot` | `true` | Spot VMs for the nodes |
| `gke_min_node_count`, `gke_max_node_count` | `1`, `3` | Autoscaling bounds per zone |
| `gke_disk_size_gb` | `50` | |
| `gke_deletion_protection` | `false` | |
| `gke_kms_name_suffix` | `""` | Set a new suffix (for example `-2`) to re-create the cluster after a destroy, since KMS key rings cannot be deleted |

The cluster name is shared with the network (`cluster_name`, at most 24 characters), so the secondary range names always match. Prerequisites, apply and destroy steps, and the cost note are in the [GCP GKE runbook](../../../../docs/runbooks/gcp-gke.md).

## Validate without a backend

```bash
terraform init -backend=false
terraform validate
```
