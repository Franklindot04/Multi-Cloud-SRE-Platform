# GCP GKE

Creates and destroys the GKE cluster in `infra/terraform/environments/gcp`. The cluster is intended to be applied briefly and destroyed. The [network](gcp-network.md) is part of the same stack.

## Cost

Figures are approximate; check current Google Cloud pricing before applying.

- **Cluster management fee:** about $0.10 per hour per cluster. One zonal cluster per billing account is covered by a monthly free-tier credit (about $74.40), so the default zonal cluster has no management fee in practice. A regional cluster is not covered.
- **Nodes:** two to three Spot `e2-standard-2` nodes cost a few cents per hour each; Spot VMs are typically 60-90% cheaper than On-Demand. A regional cluster runs the node counts in three zones.
- **Cloud NAT:** a few cents per hour plus data processing (see the [network runbook](gcp-network.md)).
- **KMS key:** about $0.06 per month per active key version.
- Boot disks, Cloud Logging and Cloud Monitoring ingestion.

Destroy the stack as soon as you are done.

## Prerequisites

- A GCP project with billing enabled and its project ID
- Terraform 1.11 or later, the Google Cloud CLI, `kubectl` and the GKE auth plugin (below)
- The state bucket from [terraform-bootstrap](terraform-bootstrap.md) and a local `backend.<environment>.hcl`
- These APIs enabled in the project:

  ```bash
  gcloud services enable \
    compute.googleapis.com \
    container.googleapis.com \
    cloudkms.googleapis.com \
    iam.googleapis.com \
    cloudresourcemanager.googleapis.com \
    --project <PROJECT_ID>
  ```

- Permission to create clusters, networks, service accounts, IAM bindings and KMS keys. For a personal sandbox project, `roles/owner` is the simplest; otherwise combine `roles/container.admin`, `roles/compute.networkAdmin`, `roles/iam.serviceAccountAdmin`, `roles/resourcemanager.projectIamAdmin` and `roles/cloudkms.admin`.
- Your public IP address for the control plane allowlist (for example from `curl https://checkip.amazonaws.com`)

Install the auth plugin if needed:

```bash
gcloud components install gke-gcloud-auth-plugin
gke-gcloud-auth-plugin --version
```

## Authenticate

```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project <PROJECT_ID>
gcloud auth application-default set-quota-project <PROJECT_ID>
```

## Apply

The network and cluster are applied together. Terraform creates the network first because the cluster depends on it.

```bash
cd infra/terraform/environments/gcp
terraform init -backend-config=backend.dev.hcl
terraform plan -var environment=dev -var project_id=<PROJECT_ID> \
  -var 'master_authorized_cidrs=["<YOUR_IP>/32"]' \
  -out=tfplan
```

Review the plan. Expect the network resources plus a node service account with five IAM bindings, a KMS key ring, key and IAM binding, the cluster and one node pool. Then:

```bash
terraform apply tfplan
```

Creation takes roughly 10 to 15 minutes. Do not set `nat_mode=none` while the cluster exists: private nodes need Cloud NAT to pull from non-Google registries.

If a previous cluster with the same name was destroyed, the KMS key ring still exists. Pass `-var gke_kms_name_suffix=-2` (or another unused suffix), or import the existing key ring; see the [module README](../../infra/terraform/modules/gcp-gke/README.md#re-creating-the-cluster).

Keep the `-var` values in a local `terraform.tfvars` (ignored by Git) if you apply repeatedly.

## Kubeconfig

```bash
$(terraform output -raw get_credentials_command)
kubectl config current-context
```

This needs `gke-gcloud-auth-plugin` on your path, and your IP in `master_authorized_cidrs`. If the IP changes, update the variable and apply.

## Verify

```bash
kubectl get nodes -o wide                  # all nodes Ready
kubectl get pods -n kube-system            # system pods Running (kube-dns, gke-metrics-agent, anetd, konnectivity-agent)
gcloud container clusters describe "$(terraform output -raw cluster_name)" \
  --location "$(terraform output -raw cluster_location)" \
  --format='yaml(status,workloadIdentityConfig,networkConfig.datapathProvider,databaseEncryption,privateClusterConfig,masterAuthorizedNetworksConfig)'
```

Expect `status: RUNNING`, the workload pool `<PROJECT_ID>.svc.id.goog`, datapath `ADVANCED_DATAPATH`, `databaseEncryption.state: ENCRYPTED`, private nodes and your `/32` under authorized networks.

Confirm that a pod can pull an image through Cloud NAT and run:

```bash
kubectl run smoke-test --image=public.ecr.aws/docker/library/busybox:stable --restart=Never -- sleep 60
kubectl wait --for=condition=Ready pod/smoke-test --timeout=180s
kubectl delete pod smoke-test
```

The image comes from a non-Google registry, so it can only be pulled over Cloud NAT. Check the NAT with `gcloud compute routers nats list --router <CLUSTER_NAME> --region europe-north1`.

## Destroy

1. Delete anything created in the cluster that provisions Google Cloud resources outside Terraform: `Service` objects of type `LoadBalancer`, `Ingress` resources, and `PersistentVolumeClaim`s. Otherwise forwarding rules, firewall rules and disks are left behind and block deletion of the network.

   ```bash
   kubectl delete svc,ingress --all-namespaces --all
   kubectl delete pvc --all --all-namespaces
   ```

2. Destroy the stack:

   ```bash
   terraform destroy -var environment=dev -var project_id=<PROJECT_ID>
   ```

3. If `gke_deletion_protection` was enabled, set it to `false` and apply before destroying.

## Destroy checklist

Confirm that each item is gone or scheduled for destruction:

- [ ] GKE cluster (`gcloud container clusters list`)
- [ ] Node pool and its VM instances (`gcloud compute instances list`)
- [ ] KMS key versions scheduled for destruction (`gcloud kms keys versions list --key secrets --keyring <CLUSTER_NAME>-gke --location europe-north1`). The key ring itself cannot be deleted and remains, at no cost.
- [ ] Node service account (`gcloud iam service-accounts list`) and its project role bindings
- [ ] Cloud NAT (`gcloud compute routers nats list --router <CLUSTER_NAME> --region europe-north1`)
- [ ] Cloud Router (`gcloud compute routers list`)
- [ ] Firewall rules, including any left by Kubernetes load balancers (`gcloud compute firewall-rules list`)
- [ ] Subnet (`gcloud compute networks subnets list`)
- [ ] VPC network (`gcloud compute networks list`)
- [ ] Load balancer forwarding rules, reserved addresses and unattached disks (`gcloud compute forwarding-rules list`, `gcloud compute addresses list`, `gcloud compute disks list`)

## Troubleshooting

- **`Unable to connect to the server` or timeout:** your IP is not in `master_authorized_cidrs`, or it changed. Update the variable and apply.
- **`gke-gcloud-auth-plugin not found`:** install it as described above and make sure it is on your `PATH`.
- **API not enabled:** a `container.googleapis.com has not been used` error means the prerequisite step was skipped. Enable the API and wait a minute.
- **KMS key ring already exists:** see the note under Apply.
- **Spot capacity errors or preempted nodes:** set `gke_spot=false` or add capacity in another zone.
- **IP exhaustion errors on node creation:** the pod range allows 64 nodes at the default per-node range; check `kubectl get nodes` and the autoscaler maximum.
