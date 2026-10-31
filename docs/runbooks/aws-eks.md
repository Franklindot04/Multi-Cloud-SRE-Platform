# AWS EKS

Creates and destroys the EKS cluster in `infra/terraform/environments/aws`. The cluster is intended to be applied briefly and destroyed.

## Cost

Figures are approximate; check current AWS pricing before applying.

- EKS control plane: about $0.10 per hour (roughly $73 per month) from the moment the cluster exists.
- Two Spot nodes (`t3.large`, `m5.large`): a few cents per hour each, well below On-Demand.
- NAT gateway: about $0.05 per hour plus data charges (see the [network runbook](aws-network.md)).
- KMS key: about $1 per month, prorated, and it keeps billing until its deletion window ends.
- CloudWatch Logs for control plane logs, and node EBS volumes.

With the defaults, expect a few dollars per day. Destroy as soon as you are done.

## Prerequisites

- Terraform 1.11 or later, and AWS credentials with permission to manage EKS, IAM, KMS, EC2 and CloudWatch Logs
- `kubectl` and AWS CLI v2
- The state bucket from [terraform-bootstrap](terraform-bootstrap.md) and a local `backend.<environment>.hcl`
- Your public IP address, to restrict the API endpoint (for example from `curl https://checkip.amazonaws.com`)
- Enough service quota for the instance types in the region

## Apply

The network and cluster live in one stack. Terraform creates the network first and the cluster after it, because the cluster depends on the network outputs.

```bash
cd infra/terraform/environments/aws
terraform init -backend-config=backend.dev.hcl
terraform plan -var environment=dev \
  -var 'public_access_cidrs=["<YOUR_IP>/32"]' \
  -var 'admin_principal_arns=["arn:aws:iam::<ACCOUNT_ID>:role/<ADMIN_ROLE>"]' \
  -out=tfplan
```

Review the plan. Expect the network resources plus the cluster, log group, KMS key and alias, IAM roles, launch template, node group, OIDC provider and five add-ons. Then:

```bash
terraform apply tfplan
```

Creation takes roughly 15 to 20 minutes. Do not set `nat_mode=none` while the cluster exists.

Keep the `-var` values in a local `terraform.tfvars` (ignored by Git) if you apply repeatedly.

## Kubeconfig

```bash
$(terraform output -raw kubeconfig_command)
kubectl config current-context
```

The identity running the command must be the cluster creator or listed in `admin_principal_arns`.

## Verify

```bash
kubectl get nodes -o wide                      # all nodes Ready
kubectl get pods -n kube-system                # coredns, aws-node, kube-proxy, ebs-csi, eks-pod-identity-agent Running
aws eks list-addons --cluster-name "$(terraform output -raw cluster_name)"
aws eks describe-addon --cluster-name "$(terraform output -raw cluster_name)" --addon-name coredns --query addon.status
```

All five add-ons (`vpc-cni`, `kube-proxy`, `coredns`, `eks-pod-identity-agent`, `aws-ebs-csi-driver`) should report `ACTIVE`.

Confirm an image can be pulled and a pod scheduled:

```bash
kubectl run smoke-test --image=public.ecr.aws/docker/library/busybox:stable --restart=Never -- sleep 60
kubectl wait --for=condition=Ready pod/smoke-test --timeout=120s
kubectl delete pod smoke-test
```

Also confirm that the API endpoint is limited to your address:

```bash
aws eks describe-cluster --name "$(terraform output -raw cluster_name)" \
  --query 'cluster.resourcesVpcConfig.publicAccessCidrs'
```

## Destroy

1. Delete anything created in the cluster that provisions AWS resources outside Terraform: load balancers (`Ingress` and `Service` of type `LoadBalancer`), the security groups the AWS Load Balancer Controller creates for them, and the volumes behind `PersistentVolumeClaim`s. Otherwise load balancers, volumes, security groups and network interfaces are left behind and block deletion of the subnets and the VPC. The order matters, and deleting Argo CD Applications by hand does not work (they come back). The script does the whole sequence with waits and stops at the first step that does not finish; read the dry run first:

   ```bash
   scripts/teardown-prep.sh --context <EKS_CONTEXT> --region <REGION> --cluster-name <CLUSTER_NAME> --dry-run
   scripts/teardown-prep.sh --context <EKS_CONTEXT> --region <REGION> --cluster-name <CLUSTER_NAME>
   ```

   What it does, and the commands to run by hand, are in the [data layer teardown](data-layer.md#teardown): remove the cluster Secret labels (`kubectl -n argocd label secret cluster-in-cluster platform.example/apps- platform.example/data- platform.example/observability-`, deleting the keys, not setting them to `false`), wait for the `shop` namespace to empty, delete the `Cluster` and the `RabbitmqCluster` and then the RabbitMQ StatefulSet if its pod survives, delete the remaining claims including `platform-valkey`, confirm `kubectl get pv` is empty, and confirm with the AWS CLI that only the node root volumes remain. Then check for load balancers and for security groups created by the load balancer controller:

   ```bash
   aws resourcegroupstaggingapi get-resources --region <REGION> --resource-type-filters elasticloadbalancing:loadbalancer \
     --tag-filters Key=elbv2.k8s.aws/cluster,Values=<CLUSTER_NAME> --query 'ResourceTagMappingList[].ResourceARN'
   aws ec2 describe-security-groups --region <REGION> --filters Name=tag:elbv2.k8s.aws/cluster,Values=<CLUSTER_NAME> \
     --query 'SecurityGroups[].[GroupId,GroupName]'
   ```

   Both must be empty. Then remove the namespaces, the storage class and Argo CD with the script, which refuses to start while a volume or a claim is left:

   ```bash
   scripts/teardown-argocd.sh --context <EKS_CONTEXT> --dry-run
   scripts/teardown-argocd.sh --context <EKS_CONTEXT>
   ```

   The order is `scripts/teardown-prep.sh`, then `scripts/teardown-argocd.sh`, then `terraform destroy`. Why the second script exists is in the [Argo CD teardown](argocd.md#teardown). Do not rely on `kubectl delete pvc --all -A` alone: a claim stays `Bound` while a pod still uses it.

2. Destroy the stack:

   ```bash
   terraform destroy -var environment=dev
   ```

3. Wait for the destroy to finish. It removes the node group, add-ons and cluster first, then the network.

## Destroy checklist

Confirm in the console or CLI that each item is gone, since these are what keep billing:

- [ ] EKS cluster (`aws eks list-clusters`)
- [ ] Managed node group and its EC2 instances (`aws ec2 describe-instances --filters Name=tag:environment,Values=dev Name=instance-state-name,Values=running`)
- [ ] NAT gateways (`aws ec2 describe-nat-gateways --filter Name=state,Values=available`)
- [ ] Elastic IPs released (`aws ec2 describe-addresses`)
- [ ] Load balancers created by Services or Ingresses (`aws elbv2 describe-load-balancers`)
- [ ] Unattached EBS volumes (`aws ec2 describe-volumes --filters Name=status,Values=available`)
- [ ] **EBS volumes created for PersistentVolumeClaims**, such as the data layer's: they are not managed by Terraform and are not removed by `terraform destroy`. Delete the claims first ([data layer teardown](data-layer.md#teardown)), then `aws ec2 describe-volumes --region eu-north-1 --filters Name=tag-key,Values=kubernetes.io/created-for/pvc/name` must list nothing
- [ ] KMS key in `PendingDeletion` (it bills until the window ends; the default is 7 days; `aws kms list-aliases`)
- [ ] CloudWatch log groups for the control plane and flow logs (`aws logs describe-log-groups --log-group-name-prefix /aws/eks`; also `/aws/vpc`)
- [ ] IAM roles for the cluster, nodes and EBS CSI driver, and the OIDC provider

If the destroy fails on subnets or the VPC, look for leftover network interfaces and load balancers:

```bash
aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=<VPC_ID> --query 'NetworkInterfaces[].[NetworkInterfaceId,Description]'
```

## Troubleshooting

- **`Unauthorized` from kubectl:** your identity is not the creator and not in `admin_principal_arns`. Add it and apply. For SSO roles, use the role ARN without the `aws-reserved/sso.amazonaws.com/` path.
- **Cannot reach the API:** your IP changed. Update `public_access_cidrs` and apply.
- **Nodes not joining:** check that the private route tables have a NAT route and the add-ons `vpc-cni` and `kube-proxy` are `ACTIVE`.
- **Spot capacity errors:** add more instance types or switch `node_capacity_type` to `ON_DEMAND`.
