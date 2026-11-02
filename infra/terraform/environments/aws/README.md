# AWS environment stack

Root Terraform stack for the AWS side of the platform. It currently provisions the VPC network and the EKS cluster by composing the [`aws-network`](../../modules/aws-network) and [`aws-eks`](../../modules/aws-eks) modules; other resources arrive in later changes.

## Files

| File | Purpose |
| --- | --- |
| `backend.tf` | S3 backend, partial configuration |
| `backend.hcl.example` | Template for the per-environment backend values |
| `network.tf` | VPC network via the `aws-network` module |
| `eks.tf` | EKS cluster via the `aws-eks` module |
| `addons-iam.tf` | IAM roles for the cluster add-ons (IRSA) via the `aws-irsa` module |
| `policies/` | Vendored official load balancer controller IAM policy, with its source and version |
| `dns.tf` | Optional Route 53 zone, delegation and traffic steering via the `aws-dns` module |
| `outputs.tf` | VPC, subnet, NAT and cluster outputs, including a kubeconfig command |
| `providers.tf` | AWS provider with default tags |
| `versions.tf` | Terraform and provider version constraints |
| `variables.tf` | Inputs (`environment` is required; network inputs have defaults) |

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

## Network inputs

| Variable | Default | Notes |
| --- | --- | --- |
| `vpc_cidr` | `10.10.0.0/16` | Use a different `/16` for each environment ([ADR-0006](../../../../docs/adr/0006-aws-network-design.md)) |
| `nat_mode` | `single` | `single`, `per_az` or `none`; NAT is the main cost |
| `flow_log_retention_days` | `14` | CloudWatch Logs retention |
| `cluster_name` | `null` | Set once the EKS cluster exists to tag subnets |

Apply and destroy steps, with cost notes, are in the [AWS network runbook](../../../../docs/runbooks/aws-network.md).

## Cluster inputs

| Variable | Default | Notes |
| --- | --- | --- |
| `cluster_name` | `<project>-<environment>` | Also used for the shared subnet tag, so the network and cluster always agree |
| `kubernetes_version` | `1.37` | Newest EKS standard-support version when written; check the EKS version calendar before changing |
| `public_access_cidrs` | `["0.0.0.0/0"]` | Restrict to your own `/32` |
| `admin_principal_arns` | `[]` | IAM users or roles granted cluster admin; the creator is admin by default |
| `node_instance_types` | `["t3.large", "m5.large"]` | |
| `node_capacity_type` | `SPOT` | `SPOT` or `ON_DEMAND` |
| `node_desired_size`, `node_min_size`, `node_max_size` | `2`, `1`, `4` | |
| `node_disk_size_gb` | `30` | |
| `enable_network_policy` | `true` | Turns on network policy enforcement in the `vpc-cni` add-on; see [network policies](../../../../docs/runbooks/aws-eks.md#network-policy-enforcement) |

Apply and destroy steps, with cost notes, are in the [AWS EKS runbook](../../../../docs/runbooks/aws-eks.md). The control plane bills hourly while the cluster exists.

## DNS inputs

DNS is off by default: an empty `domain_name` creates nothing. Hosted zones and health checks bill monthly.

| Variable | Default | Notes |
| --- | --- | --- |
| `domain_name` | `""` | Domain for the Route 53 hosted zone, for example `example.com` |
| `delegated_subdomains` | `{}` | Subdomain to name servers, for example `{ gke = [...] }`, from the GCP stack's `dns_name_servers` output |
| `dns_endpoints` | `{}` | Endpoints keyed `aws` and `gcp`, each with `fqdn` or `ip` and optional health check settings; empty creates no records |
| `dns_enable_health_checks` | `true` | Health checks bill monthly |
| `app_hostname` | `app` | Creates `app.<domain>` |
| `routing_policy` | `weighted` | `weighted` for normal operation, `failover` for disaster recovery |
| `dns_weights` | `{aws=50, gcp=50}` | Weights for the weighted policy |
| `primary_cloud` | `aws` | Primary under the failover policy |
| `dns_record_ttl` | `60` | Seconds |

Apply the GCP stack first and pass its name servers here as `delegated_subdomains`; the stacks never read each other's state. See the [global DNS runbook](../../../../docs/runbooks/global-dns.md).

## Add-on IAM inputs

Roles for the cluster add-ons in [`platform/addons`](../../../../platform/addons). Nothing is installed by Terraform.

| Variable | Default | Notes |
| --- | --- | --- |
| `enable_load_balancer_controller_iam` | `true` | Role for the AWS Load Balancer Controller, using the vendored official policy |
| `enable_external_dns_iam` | `false` | Route 53 role scoped to one hosted zone; needs `domain_name` or `addons_hosted_zone_id` |
| `enable_cert_manager_iam` | `false` | Route 53 DNS-01 role scoped to one hosted zone; same requirement |
| `addons_hosted_zone_id` | `""` | Hosted zone the DNS roles may change; defaults to the zone from `domain_name` |

Outputs `aws_load_balancer_controller_role_arn`, `external_dns_role_arn` and `cert_manager_role_arn` go into the `eks.amazonaws.com/role-arn` annotations in the add-on values files. See the [cluster add-ons runbook](../../../../docs/runbooks/cluster-addons.md).

## Validate without a backend

```bash
terraform init -backend=false
terraform validate
```
