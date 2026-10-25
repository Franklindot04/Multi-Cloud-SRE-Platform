# AWS network

Applies and destroys the VPC network in `infra/terraform/environments/aws`. Assumes the [state bucket exists](terraform-bootstrap.md).

## Cost

The NAT gateway is the main cost: about $0.05 per hour (around $35 per month) per gateway in `eu-north-1`, plus a per-GB processing charge, plus an hourly charge for its public IPv4 address. The default `nat_mode = "single"` creates one gateway. `per_az` creates three and triples that fixed cost. Flow logs add small CloudWatch charges. The VPC, subnets, route tables, internet gateway and S3 gateway endpoint are free. Prices change, so check current AWS pricing.

Cost levers:

- Leave `nat_mode` at `single` unless testing zone failure.
- Use `nat_mode = "none"` while the network is idle but needs to stay.
- Destroy the stack when it is not in use; it can be recreated from code in a few minutes.

## Prerequisites

- Terraform 1.11 or later and AWS credentials for the target account
- The AWS state bucket from [terraform-bootstrap](terraform-bootstrap.md)
- A local `backend.<environment>.hcl` copied from `backend.hcl.example` (local only, ignored by Git)

## Apply

```bash
cd infra/terraform/environments/aws
terraform init -backend-config=backend.dev.hcl
terraform plan -var environment=dev -out=tfplan
```

Review the plan: expect one VPC, six subnets, one internet gateway, one NAT gateway with its address, four route tables, an S3 endpoint, a log group, a flow log and its IAM role. Then:

```bash
terraform apply tfplan
```

To use a different layout, pass variables to `plan`, for example `-var nat_mode=none` or `-var vpc_cidr=10.11.0.0/16`.

## Verify

- `terraform output` shows the VPC ID, three public and three private subnet IDs and, unless `nat_mode=none`, the NAT public IPs.
- In the console or CLI, check that private route tables have a `0.0.0.0/0` route to a NAT gateway and that flow logs are delivering to the log group.

## Change the NAT layout

Change `nat_mode` and apply. Switching between modes creates or removes gateways, which briefly interrupts egress from private subnets, so plan the change outside critical work.

## Destroy

1. Destroy anything that depends on the network first (clusters, load balancers, endpoints created elsewhere). Leftover network interfaces block subnet deletion.
2. Destroy the network:

   ```bash
   terraform destroy -var environment=dev
   ```

3. Confirm in the console that the NAT gateways are deleted and their Elastic IPs released, since these keep billing if they linger.

If a destroy fails on a subnet or the VPC, look for remaining network interfaces (`aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=<VPC_ID>`) and remove their owners.
