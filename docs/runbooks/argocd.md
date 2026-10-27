# Argo CD

Installs the Argo CD hub on the EKS cluster, registers the cluster, and lets Argo CD deploy the baseline add-ons from Git. Covers verification, registering GKE later, upgrades and teardown.

## Prerequisites

- The EKS cluster and network applied ([AWS network](aws-network.md) and [EKS](aws-eks.md) runbooks), with the `aws-eks` and `aws-network` outputs available.
- `kubectl`, `helm`, `aws`, `jq` and `terraform` installed, and a kubeconfig context for the cluster (`terraform output -raw kubeconfig_command`).
- Your IP in `public_access_cidrs` so `kubectl` can reach the control plane.
- The GitOps definitions **merged to `main` on GitHub** (`https://github.com/Franklindot04/Multi-Cloud-SRE-Platform`). Argo CD reads Git, not your working tree, and the repository is public so no credentials are needed.
- Terraform applied with the add-on IAM roles you need. The load balancer controller role is created by default; the DNS roles are off until a domain exists.

## Apply order

1. **Terraform** (cluster, network, add-on roles):

   ```bash
   cd infra/terraform/environments/aws
   terraform init -backend-config=backend.dev.hcl
   terraform plan -var environment=dev -out=tfplan   # plus your usual -var values
   terraform apply tfplan
   terraform output cluster_name region account_id vpc_id aws_load_balancer_controller_role_arn
   ```

2. **Check the definitions** (optional but recommended):

   ```bash
   make argocd-check
   make addons-check
   ```

3. **Bootstrap Argo CD** from the repository root. First do a dry run, which changes nothing and does not call any cluster or cloud API:

   ```bash
   ./scripts/bootstrap-argocd.sh --context <EKS_CONTEXT> --dry-run
   ./scripts/bootstrap-argocd.sh --context <EKS_CONTEXT>
   ```

   The script reads the Terraform outputs, confirms that the context points at the EKS cluster and that your AWS credentials belong to the same account, asks for confirmation, installs the pinned Argo CD chart, waits for it, writes the cluster Secret (labels and annotations only), and applies the AppProjects and the root Application. It prints the access instructions at the end and never prints the password.

   Optional flags: `--enable-data` (the data layer, see the [data layer runbook](data-layer.md)), `--enable-apps` with `--apps-profile memory|data` (the sample services; needs published images, see the [service deployment runbook](service-deployment.md)), `--enable-external-dns --dns-domain example.com` and `--enable-dns01 --acme-email you@example.com` once a domain exists and the DNS roles are applied (see [global DNS](global-dns.md)).

4. **Open the UI** (no ingress; port-forward only):

   ```bash
   kubectl --context <EKS_CONTEXT> -n argocd port-forward svc/argocd-server 8080:80
   ```

   Browse to `http://localhost:8080` and sign in as `admin`.

5. **Rotate the admin password** and delete the initial secret:

   ```bash
   kubectl --context <EKS_CONTEXT> -n argocd get secret argocd-initial-admin-secret \
     -o jsonpath='{.data.password}' | base64 -d; echo
   argocd login localhost:8080 --username admin --plaintext
   argocd account update-password
   kubectl --context <EKS_CONTEXT> -n argocd delete secret argocd-initial-admin-secret
   ```

## Verify

```bash
kubectl --context <EKS_CONTEXT> -n argocd get applications
```

Within a few minutes every Application should be `Synced` and `Healthy`: `argocd`, `priority-classes-*`, `cert-manager-aws-*`, `cert-manager-issuers-aws-*`, `metrics-server-*` and `aws-load-balancer-controller-*` (external-dns only if enabled; `data-*` only with `--enable-data`; `data-rabbitmq-credentials-*` and `apps-gateway-*`, `apps-orders-*`, `apps-payments-*`, `apps-notifier-*` only with `--enable-apps`). If an Application is stuck, run `kubectl -n argocd describe application <name>` and see the troubleshooting section.

Then check the add-ons:

```bash
kubectl top nodes                       # metrics-server answering
kubectl get clusterissuer               # selfsigned and internal-ca Ready
```

**Test Certificate** from the self-signed issuer:

```bash
kubectl apply -f - <<'YAML'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: argocd-test
  namespace: default
spec:
  secretName: argocd-test-tls
  dnsNames: [argocd-test.local]
  issuerRef: {name: selfsigned, kind: ClusterIssuer}
YAML
kubectl wait --for=condition=Ready certificate/argocd-test --timeout=60s
kubectl delete certificate argocd-test && kubectl delete secret argocd-test-tls
```

**Test Ingress** (creates an ALB, which bills hourly, so delete it when done):

```bash
kubectl create deployment web --image=public.ecr.aws/nginx/nginx:stable --port=80
kubectl expose deployment web --port=80 --target-port=80
kubectl apply -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
spec:
  ingressClassName: alb
  defaultBackend:
    service: {name: web, port: {number: 80}}
YAML
kubectl get ingress web -w     # wait for an ALB host name in ADDRESS, then Ctrl-C
curl -sI "http://$(kubectl get ingress web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')" | head -1

kubectl delete ingress web
kubectl delete service web
kubectl delete deployment web
# Wait until the ALB and its target group are gone
aws elbv2 describe-load-balancers --region <REGION> --query 'LoadBalancers[].LoadBalancerName'
aws elbv2 describe-target-groups --region <REGION> --query 'TargetGroups[].TargetGroupName'
```

## Register GKE later

No file in the repository changes. Create a cluster Secret for the GKE cluster with the labels `platform.example/managed=true` and `platform.example/cloud=gcp`, and these annotations (prefix `platform.example/`) taken from the GCP stack outputs and your configuration: `cluster-name`, `project-id`, `cert-manager-sa-email`, and for the optional add-ons `external-dns-sa-email`, `dns-domain` and `acme-email`. Set the label `platform.example/external-dns=true` to deploy external-dns there.

With the Argo CD CLI (logged in through the port-forward), adding a cluster creates the Secret with credentials and metadata together:

```bash
argocd cluster add <GKE_CONTEXT> --name gke-dev \
  --label platform.example/managed=true --label platform.example/cloud=gcp \
  --annotation platform.example/cluster-name=<NAME> --annotation platform.example/project-id=<PROJECT_ID> \
  --annotation platform.example/cert-manager-sa-email=<EMAIL>
```

`argocd cluster add` creates a service account and a long-lived token in the target cluster and stores it in the hub. Treat that credential as sensitive; replacing it with short-lived exec-based authentication is a later hardening step. The GKE control plane endpoint must also be reachable from the hub: add the hub's egress address (the EKS NAT gateway IP) to `master_authorized_cidrs` for the GKE cluster. The ApplicationSets then create the GKE applications automatically (cert-manager, issuers, and external-dns if labelled). The load balancer controller and metrics-server are EKS-only and are not created there.

## Upgrade and roll back

Argo CD manages itself, so upgrades go through Git:

1. Read the argo-helm changelog and the Argo CD upgrade notes for the target version, especially for major versions and CRD changes.
2. In a pull request, bump the version in `platform/argocd/install/Chart.yaml`, regenerate `Chart.lock` (`cd platform/argocd/install && helm dependency update`), update the version table in `platform/argocd/README.md`, and run `make argocd-check`.
3. Merge. The `argocd` Application syncs the new version. Watch with `kubectl -n argocd get pods -w`.

To roll back, revert the pull request and let the Application sync, or in the UI use **History and Rollback** on the `argocd` Application. A rollback of the chart does not roll back CRD changes already applied; check the upgrade notes before moving across a CRD change. If Argo CD is unreachable, the manual fallback is `helm upgrade --install argocd platform/argocd/install -n argocd -f platform/argocd/install/values.yaml` with the previous revision checked out.

Add-on upgrades follow the same pattern through `platform/addons` (see the add-ons README).

## Teardown

Delete everything that makes AWS create load balancers **while the load balancer controller is still running**, and wait until the ALBs and target groups are gone, **before** removing the controller and before Terraform destroys the cluster. Otherwise ALBs, target groups and network interfaces are left behind, keep billing and block deletion of the subnets and the VPC.

1. **Delete workloads that create load balancers or volumes.** Delete the Applications that deploy workloads first (there are none yet), so Argo CD does not recreate them, then:

   ```bash
   kubectl delete ingress --all -A
   kubectl delete svc -A --field-selector spec.type=LoadBalancer
   ```

   Do not delete the data layer's volume claims here; follow the [data layer teardown](data-layer.md#teardown), which removes them deliberately and confirms the cloud volumes are gone.

2. **Wait until the ALBs and target groups are gone:**

   ```bash
   aws elbv2 describe-load-balancers --region <REGION> --query 'LoadBalancers[].LoadBalancerName'
   aws elbv2 describe-target-groups --region <REGION> --query 'TargetGroups[].TargetGroupName'
   ```

   Both must come back empty, or list nothing that belongs to the cluster, before you continue.
3. **Delete the root Application and the ApplicationSets**, which removes every add-on through the Application finalizers:

   ```bash
   kubectl -n argocd delete application platform-root --wait=true
   kubectl -n argocd delete applicationset --all
   kubectl -n argocd get applications          # wait until only the argocd Application, if any, remains
   ```

4. **Remove Argo CD:** `kubectl -n argocd delete application --all`, then `helm uninstall argocd -n argocd` and `kubectl delete namespace argocd`. Argo CD's CRDs are kept by design; delete them (`kubectl delete crd applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io`) only when you are removing it for good.
5. **Destroy with Terraform**, following the [EKS](aws-eks.md) runbook: the cluster and add-on roles first (set `enable_*_iam=false` or run `terraform destroy`), then the network.

### Teardown checklist

- [ ] Ingress and `LoadBalancer` Services deleted; no PVCs left
- [ ] If the data layer was enabled: all PersistentVolumeClaims deleted and the cloud volumes confirmed gone ([data layer teardown](data-layer.md#teardown)); volumes are not removed by Terraform
- [ ] No load balancers or target groups from the cluster (`aws elbv2 ...`)
- [ ] Root Application and ApplicationSets deleted; Applications gone
- [ ] Argo CD uninstalled
- [ ] Terraform destroy of the stack completed
- [ ] NAT gateways, Elastic IPs, KMS key (pending deletion) and log groups checked, per the EKS runbook

## Troubleshooting

- **Application `OutOfSync` with a CRD error:** the CRD may not exist yet; the issuers chart waits for cert-manager, and retries with backoff clear the rest. Check `kubectl -n argocd describe application <name>`.
- **`cert-manager-issuers` stuck in PreSync:** the wait Job could not find cert-manager's CRDs or webhook. Check `kubectl -n cert-manager get jobs,pods` and that the `cert-manager` Application is Healthy.
- **No Applications appear:** the cluster Secret is missing labels. Check `kubectl -n argocd get secret cluster-in-cluster --show-labels` for `platform.example/managed=true` and `platform.example/cloud=aws`.
- **Load balancer controller crash-loops:** the `cluster-name`, `region`, `vpc-id` or `lbc-role-arn` annotation is empty; re-run the bootstrap script after fixing the Terraform outputs.
- **`ComparisonError` pulling the repository:** the definitions are not on `main`, or the repository URL is wrong. The repository is public, so no credentials are involved.
- **Cannot reach the UI:** use the port-forward; there is no ingress by design.
