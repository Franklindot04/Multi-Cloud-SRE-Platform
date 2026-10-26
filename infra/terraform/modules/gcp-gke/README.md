# gcp-gke

A standard (not Autopilot) VPC-native GKE cluster with private nodes, Workload Identity, Dataplane V2, a dedicated node service account, Cloud KMS secrets encryption and one autoscaled Spot node pool. It is designed to sit on the [`gcp-network`](../gcp-network) module. Design rationale is in [ADR-0009](../../../../docs/adr/0009-gke-cluster-design.md).

## What it creates

- GKE standard cluster, zonal or regional depending on `location`, VPC-native using the network's pod and service secondary ranges
- Private nodes; the control plane has a public endpoint limited by `master_authorized_cidrs` (or a private-only endpoint with `enable_private_endpoint`)
- Workload Identity (`PROJECT.svc.id.goog`), Dataplane V2 (`ADVANCED_DATAPATH`), shielded nodes, release channel (default `REGULAR`)
- Cloud KMS key ring and key (rotation every 90 days) for application-layer secrets encryption, with the IAM binding for the GKE service agent; switchable with `enable_secrets_encryption`
- A dedicated node service account with only `logging.logWriter`, `monitoring.metricWriter`, `monitoring.viewer`, `stackdriver.resourceMetadata.writer` and `artifactregistry.reader`; the default compute service account is not used
- The default node pool is removed and replaced by one managed pool: Spot `e2-standard-2` by default, autoscaling 1 to 3 nodes per zone, auto repair and auto upgrade, `GKE_METADATA` workload metadata mode, secure boot and integrity monitoring
- Logging and monitoring limited to system components by default, managed Prometheus off, daily maintenance window

## Usage

```hcl
module "gke" {
  source = "../../modules/gcp-gke"

  project_id   = "my-project-id"
  cluster_name = "multi-cloud-sre-dev"
  environment  = "dev"
  location     = "europe-north1-a"

  network_name        = module.network.network_name
  subnet_name         = module.network.subnet_name
  pods_range_name     = module.network.pods_range_name
  services_range_name = module.network.services_range_name

  master_authorized_cidrs = ["203.0.113.10/32"] # your own address

  labels = { owner = "platform-team" }
}
```

`location` must be in the region of the subnet. A zone such as `europe-north1-a` creates a zonal cluster; a region such as `europe-north1` creates a regional one.

## Restrict the control plane endpoint

`master_authorized_cidrs` defaults to an empty list, which means the public endpoint cannot be reached from the internet: only the cluster's own network can reach it. That is the safe default but it also locks out `kubectl` from a workstation. Add your own address as a `/32` (for example `["203.0.113.10/32"]`) before using the cluster from your machine, and keep the list as short as possible. Set `enable_private_endpoint = true` to remove the public endpoint altogether and reach the cluster from inside the VPC.

## Workload Identity example

Bind a Kubernetes service account to a Google service account so pods use Google APIs without keys:

```hcl
resource "google_service_account" "orders" {
  project      = "my-project-id"
  account_id   = "orders"
  display_name = "orders workload"
}

# Allow the Kubernetes service account orders/orders-sa to act as the Google service account.
resource "google_service_account_iam_member" "orders_wi" {
  service_account_id = google_service_account.orders.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${module.gke.workload_pool}[orders/orders-sa]"
}

# Grant the Google service account whatever the workload needs, for example:
resource "google_project_iam_member" "orders_storage" {
  project = "my-project-id"
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.orders.email}"
}
```

Then annotate the Kubernetes service account:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: orders-sa
  namespace: orders
  annotations:
    iam.gke.io/gcp-service-account: orders@my-project-id.iam.gserviceaccount.com
```

## Re-creating the cluster

Cloud KMS key rings cannot be deleted. Destroying the cluster schedules the key's versions for destruction, but the key ring remains, so creating the cluster again with the same name fails with "already exists". Set `kms_name_suffix` to a new value (for example `"-2"`) when re-creating, or import the existing key ring.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `project_id` | `string` | n/a | GCP project ID. |
| `cluster_name` | `string` | n/a | Cluster name (3-24 characters, lowercase); prefix for related resources. |
| `environment` | `string` | n/a | One of `dev`, `staging`, `prod`. |
| `location` | `string` | n/a | Zone (zonal cluster) or region (regional cluster). |
| `network_name` | `string` | n/a | VPC network name. |
| `subnet_name` | `string` | n/a | Node subnet name. |
| `pods_range_name` | `string` | n/a | Secondary range name for pods. |
| `services_range_name` | `string` | n/a | Secondary range name for services. |
| `enable_private_endpoint` | `bool` | `false` | Remove the public control plane endpoint. |
| `master_authorized_cidrs` | `list(string)` | `[]` | CIDRs allowed to reach the public endpoint. Add your own `/32`. |
| `master_ipv4_cidr` | `string` | `"172.16.0.0/28"` | Private `/28` for the control plane. |
| `release_channel` | `string` | `"REGULAR"` | `RAPID`, `REGULAR` or `STABLE`. |
| `maintenance_start_time` | `string` | `"02:00"` | Daily maintenance window start (UTC, `HH:MM`). |
| `deletion_protection` | `bool` | `false` | Protect the cluster from deletion. |
| `enable_secrets_encryption` | `bool` | `true` | Encrypt secrets with a module-created KMS key. |
| `kms_rotation_period_days` | `number` | `90` | Key rotation period. |
| `kms_name_suffix` | `string` | `""` | Suffix for the key ring name, for re-creating the cluster. |
| `logging_components` | `list(string)` | `["SYSTEM_COMPONENTS"]` | Components that send logs. |
| `monitoring_components` | `list(string)` | `["SYSTEM_COMPONENTS"]` | Components that send metrics. |
| `enable_managed_prometheus` | `bool` | `false` | Managed Service for Prometheus. |
| `machine_type` | `string` | `"e2-standard-2"` | Node machine type. |
| `spot` | `bool` | `true` | Use Spot VMs. |
| `min_node_count` / `max_node_count` | `number` | `1` / `3` | Autoscaling bounds per zone. |
| `disk_size_gb` | `number` | `50` | Node boot disk size in GiB. |
| `disk_type` | `string` | `"pd-balanced"` | `pd-standard`, `pd-balanced` or `pd-ssd`. |
| `node_labels` | `map(string)` | `{}` | Kubernetes labels for the nodes. |
| `labels` | `map(string)` | `{}` | Resource labels merged onto the cluster, nodes and key. |

## Outputs

| Name | Description |
| --- | --- |
| `cluster_name` | Cluster name |
| `cluster_endpoint` | Control plane endpoint |
| `cluster_ca_certificate` | Base64 cluster CA certificate |
| `location` | Zone or region of the cluster |
| `workload_pool` | Workload Identity pool (`PROJECT.svc.id.goog`) |
| `node_service_account_email` | Dedicated node service account |
| `kms_key_id` | KMS key ID (null when encryption is off) |
| `get_credentials_command` | `gcloud container clusters get-credentials ...` command |

## Cost

All figures are approximate and must be checked against current Google Cloud pricing before applying.

- **Cluster management fee:** about $0.10 per hour (roughly $73 per month) per cluster, zonal or regional. Each billing account receives a monthly free-tier credit (about $74.40) that covers one zonal or Autopilot cluster, so a single zonal cluster is effectively free of management fees. Regional clusters are not covered by the credit.
- **Zonal vs regional:** a regional cluster has a highly available control plane and runs nodes in three zones, so the per-zone node counts triple (1 to 3 per zone becomes 3 to 9 nodes). Zonal is cheaper and fine for non-production; regional is the production choice.
- **Nodes:** `e2-standard-2` On-Demand costs on the order of $0.07 per hour in `europe-north1`. Spot VMs are typically 60-90% cheaper but can be reclaimed at any time.
- **KMS key:** about $0.06 per month per active key version plus a small charge per operation; rotation adds versions, and a destroyed key version stops billing once it is destroyed.
- **Other:** node boot disks, Cloud Logging and Monitoring ingestion, and the Cloud NAT from the network module.

For a short-lived environment, expect a few dollars per day or less with the defaults. Destroy the stack when not in use.

## Tests

Plan-only tests with a mocked provider run without credentials:

```bash
terraform init -backend=false
terraform test
```

They cover the defaults, zonal and regional locations, the encryption toggle, Spot off, the authorized CIDR list, the node service account roles and every input validation.

## Requirements

Terraform 1.11 or later; Google provider 7.0 or later. The Kubernetes Engine, Cloud KMS, IAM and Resource Manager APIs must be enabled in the project.
