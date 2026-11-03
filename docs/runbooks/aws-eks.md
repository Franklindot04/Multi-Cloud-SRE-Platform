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

**Seed the secrets first (once for each environment).** If the cluster will use external secrets (`--enable-external-secrets`), the passwords have to be in Parameter Store before the first sync. They are free and survive a rebuild, so this is done once; a second run changes nothing:

```bash
./scripts/seed-secrets.sh --region eu-north-1 --profile <PROFILE>
./scripts/seed-secrets.sh --region eu-north-1 --profile <PROFILE> --check
```

The details, and what to check afterwards, are in the [secrets runbook](secrets.md). A cluster that does not opt in needs none of this.

The checks to run on a cluster for everything merged and not yet seen (network policies, Kyverno, resilience, external secrets and the Argo Rollouts canary), in order, with the flags and the node count to use, are in [checks for the next apply session](progressive-delivery.md#checks-for-the-next-apply-session).

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

## Network policy enforcement

The `vpc-cni` add-on enforces Kubernetes network policies when its configuration has `enableNetworkPolicy` set to `"true"`. The module sets it with `enable_network_policy` (default `true`); without it, NetworkPolicy objects are accepted and ignored. It needs add-on 1.14.0-eksbuild.3 or later (the module always uses the newest version compatible with the cluster), Kubernetes 1.25 or later, and nodes with Linux kernel 5.10 or later (the Amazon Linux 2023 nodes qualify).

- **Fresh apply:** nothing extra. The add-on is created with the setting, and the `aws-node` pods start with the network policy agent.
- **Existing cluster:** `terraform apply` updates the `vpc-cni` add-on in place with the new configuration, and adds the output `service_cidr_block` (the address range of the cluster's Services; the cluster itself does not change). The `aws-node` DaemonSet rolls node by node and each pod gains a second container (`aws-network-policy-agent`). Policies already in the cluster start to be enforced once the agent runs on the node, so apply the policies after this, never before (the allow rules and the default deny are applied together by Argo CD). The update does not restart your pods, but a node may pause new pod networking for a short time while its `aws-node` pod restarts.

Verify:

```bash
kubectl -n kube-system get ds aws-node                                   # READY equals DESIRED
kubectl -n kube-system get pods -l k8s-app=aws-node -o jsonpath='{.items[0].spec.containers[*].name}'; echo   # includes aws-network-policy-agent
aws eks describe-addon --cluster-name "$(terraform output -raw cluster_name)" --addon-name vpc-cni --query addon.configurationValues --output text
terraform output -raw service_cidr_block; echo                           # for example 172.20.0.0/16 (the EKS default; an example)
```

The policy agent matches egress rules against the address a pod connects to. For a Service that is its ClusterIP, before it becomes a pod address, so the policies need the Service range of the cluster. It comes from the output `service_cidr_block`. This was found on a real cluster on 2026-11-02 with the first version of the policies; the policies of this version, which use the range, have not been applied to a cluster yet. See [ADR-0024](../adr/0024-network-policies.md).

The order to apply, for a new cluster and for an existing one:

1. `terraform apply`: the add-on setting and the output `service_cidr_block`.
2. `scripts/bootstrap-argocd.sh` again, with the flags you already use. It reads the outputs `vpc_cidr_block` and `service_cidr_block` and writes them as the annotations `platform.example/vpc-cidr` and `platform.example/service-cidr` on the cluster Secret. It stops if an output is empty, so Terraform comes first.
3. Argo CD syncs the policies, with every allow rule applied before the default deny. The two policy Applications and the four service Applications fail to sync, on purpose, until the annotations exist.

The checks to run afterwards, starting with DNS and then the API server, and the rollback are in the [network policy runbook](network-policies.md). The policies and what they allow are in [`platform/data/network-policies`](../../platform/data/network-policies), [`platform/observability/network-policies`](../../platform/observability/network-policies) and the service chart ([`deploy/helm/service`](../../deploy/helm/README.md#network-policies)).

## Destroy

1. Delete anything created in the cluster that provisions AWS resources outside Terraform: load balancers (`Ingress` and `Service` of type `LoadBalancer`), the security groups the AWS Load Balancer Controller creates for them, and the volumes behind `PersistentVolumeClaim`s. Otherwise load balancers, volumes, security groups and network interfaces are left behind and block deletion of the subnets and the VPC. The order matters, and deleting Argo CD Applications by hand does not work (they come back). The script does the whole sequence with waits and stops at the first step that does not finish; read the dry run first:

   ```bash
   scripts/teardown-prep.sh --context <EKS_CONTEXT> --region <REGION> --cluster-name <CLUSTER_NAME> --dry-run
   scripts/teardown-prep.sh --context <EKS_CONTEXT> --region <REGION> --cluster-name <CLUSTER_NAME>
   ```

   What it does, and the commands to run by hand, are in the [data layer teardown](data-layer.md#teardown): remove the cluster Secret labels (`kubectl -n argocd label secret cluster-in-cluster platform.example/apps- platform.example/data- platform.example/observability- platform.example/policy-`, deleting the keys, not setting them to `false`), delete the Kyverno policies and webhook configurations if the policy engine was deployed, wait for the `shop` namespace to empty, delete the `Cluster` and the `RabbitmqCluster` and then the RabbitMQ StatefulSet if its pod survives, delete the remaining claims including `platform-valkey`, confirm `kubectl get pv` is empty, and confirm with the AWS CLI that only the node root volumes remain. Then check for load balancers and for security groups created by the load balancer controller:

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
- [ ] Informational, not a cost: the secrets in Parameter Store (`aws ssm describe-parameters --region eu-north-1 --parameter-filters 'Key=Path,Option=Recursive,Values=/multi-cloud-sre/dev' --query 'Parameters[].Name'`). The six parameters are expected and are free; they are left on purpose for the next cluster. After `./scripts/seed-secrets.sh --purge` there should be none ([secrets runbook](secrets.md#the-parameters-between-sessions))

If the destroy fails on subnets or the VPC, look for leftover network interfaces and load balancers:

```bash
aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=<VPC_ID> --query 'NetworkInterfaces[].[NetworkInterfaceId,Description]'
```

## Troubleshooting

- **`Unauthorized` from kubectl:** your identity is not the creator and not in `admin_principal_arns`. Add it and apply. For SSO roles, use the role ARN without the `aws-reserved/sso.amazonaws.com/` path.
- **Cannot reach the API:** your IP changed. Update `public_access_cidrs` and apply.
- **Nodes not joining:** check that the private route tables have a NAT route and the add-ons `vpc-cni` and `kube-proxy` are `ACTIVE`.
- **Spot capacity errors:** add more instance types or switch `node_capacity_type` to `ON_DEMAND`.
