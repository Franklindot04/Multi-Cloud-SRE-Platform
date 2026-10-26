# GCP network

Applies and destroys the VPC network in `infra/terraform/environments/gcp`. Assumes the [state bucket exists](terraform-bootstrap.md).

## Cost

Figures are approximate; check current Google Cloud pricing before applying.

- **Cloud NAT** is the main cost: about $0.0014 per VM per hour (capped at 32 VMs), plus about $0.045 per GiB processed, plus charges for its external IP addresses. For a small cluster this is a few cents per hour. Set `nat_mode = "none"` to avoid it.
- **Flow logs** are billed as Cloud Logging ingestion and storage. Lower `flow_log_sampling` or set it to 0 to reduce them.
- The VPC, subnet, Cloud Router and firewall rules are free.

## Prerequisites

- A GCP project with billing enabled, and its project ID
- Terraform 1.11 or later and the Google Cloud CLI
- The state bucket from [terraform-bootstrap](terraform-bootstrap.md) and a local `backend.<environment>.hcl`
- The Compute Engine API enabled in the project:

  ```bash
  gcloud services enable compute.googleapis.com --project <PROJECT_ID>
  ```

- Permission to manage networks, subnets, routers and firewall rules (for example `roles/compute.networkAdmin` and `roles/compute.securityAdmin`)

## Authenticate

Terraform uses application default credentials:

```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project <PROJECT_ID>
gcloud auth application-default set-quota-project <PROJECT_ID>
```

## Apply

```bash
cd infra/terraform/environments/gcp
terraform init -backend-config=backend.dev.hcl
terraform plan -var environment=dev -var project_id=<PROJECT_ID> -out=tfplan
```

Review the plan: expect one VPC, one subnet with two secondary ranges, one Cloud Router, one Cloud NAT and four firewall rules. Then:

```bash
terraform apply tfplan
```

To avoid the NAT cost, add `-var nat_mode=none` to the plan; the router and NAT are then not created. To use another environment's range, set `-var vpc_cidr=10.21.0.0/16` (see [ADR-0006](../adr/0006-aws-network-design.md)).

Keep the `-var` values in a local `terraform.tfvars` (ignored by Git) if you apply repeatedly.

## Verify

```bash
terraform output
gcloud compute networks describe "$(terraform output -raw network_name)" --format='value(autoCreateSubnetworks,routingConfig.routingMode)'
gcloud compute networks subnets describe "$(terraform output -raw subnet_name)" --region europe-north1 \
  --format='yaml(ipCidrRange,privateIpGoogleAccess,secondaryIpRanges,logConfig)'
gcloud compute routers nats list --router "$(terraform output -raw network_name)" --region europe-north1
gcloud compute firewall-rules list --filter="network:$(terraform output -raw network_name)" \
  --format='table(name,direction,priority,sourceRanges.list(),denied[].map().firewall_rule().list(),allowed[].map().firewall_rule().list())'
```

The network resources are named `<project>-<environment>`, for example `multi-cloud-sre-dev`. Expect `False` and `REGIONAL` for the network, `10.20.0.0/20` with private Google access and the two secondary ranges for the subnet, one NAT (unless disabled) and the four firewall rules with the deny rule at priority 65534.

## Change the NAT setting

Change `nat_mode` and apply. Disabling NAT removes outbound internet access for private nodes immediately, so do it only when no workload depends on it.

## Destroy

1. Destroy anything that uses the network first (the GKE cluster and its load balancers, forwarding rules and disks created by Kubernetes objects). Leftover resources block subnet and VPC deletion.
2. Destroy the network:

   ```bash
   terraform destroy -var environment=dev -var project_id=<PROJECT_ID>
   ```

## Destroy checklist

Confirm each item is gone:

- [ ] Cloud NAT gateway (`gcloud compute routers nats list --router <NAME> --region europe-north1`)
- [ ] Cloud Router (`gcloud compute routers list`)
- [ ] Firewall rules (`gcloud compute firewall-rules list --filter="network:<NAME>"`)
- [ ] Subnet (`gcloud compute networks subnets list --filter="network:<NAME>"`)
- [ ] VPC network (`gcloud compute networks list`)
- [ ] Any reserved external addresses (`gcloud compute addresses list`) and leftover load balancer forwarding rules (`gcloud compute forwarding-rules list`)

## Troubleshooting

- **API not enabled:** a `compute.googleapis.com has not been used` error means the prerequisite step was skipped. Enable the API and wait a minute.
- **Subnet or VPC will not delete:** a resource still uses it. Check instances, GKE clusters, forwarding rules and internal load balancers in the VPC.
- **Quota or permission errors:** confirm the active project with `gcloud config get-value project` and the roles listed above.
