# Cluster add-ons

Installs and checks the baseline add-ons defined in `platform/addons`. Argo CD installs them in the next change; this runbook covers the post-install checks, a manual Helm fallback for verification, and teardown.

## Prerequisites

- A running cluster and credentials (see the [EKS](aws-eks.md) and [GKE](gcp-gke.md) runbooks) and `helm` and `kubectl`
- The cloud permissions created by Terraform, with the outputs copied into the values files:

  ```bash
  cd infra/terraform/environments/aws
  terraform output aws_load_balancer_controller_role_arn vpc_id
  # external_dns_role_arn and cert_manager_role_arn if the DNS roles are enabled

  cd ../gcp
  terraform output external_dns_service_account_email cert_manager_service_account_email
  ```

  The load balancer controller role is enabled by default. The DNS add-on roles are off by default; turn on `enable_external_dns_iam` and `enable_cert_manager_iam` only once a domain and zone exist (see [global DNS](global-dns.md)).
- Values files updated: replace every `REPLACE_...` placeholder (account ID, VPC ID, project ID) and set the real domain in the external-dns values.

## How the add-ons are installed

Argo CD deploys them from `platform/addons` using an app-of-apps and ApplicationSets (next change). The order is: `priority-classes`, `cert-manager`, `cert-manager-issuers`, then `aws-load-balancer-controller` and `metrics-server` on EKS, and `external-dns` only when a domain exists.

### Manual fallback (verification only)

Use these only to verify the charts on a throwaway cluster, then remove them so Argo CD owns the add-ons. Run from the repository root, replacing `aws` with `gcp` on GKE.

```bash
cd platform/addons
for c in priority-classes cert-manager cert-manager-issuers aws-load-balancer-controller metrics-server; do
  [ -f "$c/Chart.lock" ] && helm dependency build "$c"
done

helm upgrade --install priority-classes priority-classes
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install cert-manager cert-manager -n cert-manager \
  -f cert-manager/values.yaml -f cert-manager/values-aws.yaml --wait
helm upgrade --install cert-manager-issuers cert-manager-issuers -n cert-manager \
  -f cert-manager-issuers/values.yaml -f cert-manager-issuers/values-aws.yaml

# EKS only
helm upgrade --install aws-load-balancer-controller aws-load-balancer-controller -n kube-system \
  -f aws-load-balancer-controller/values.yaml -f aws-load-balancer-controller/values-aws.yaml --wait
helm upgrade --install metrics-server metrics-server -n kube-system \
  -f metrics-server/values.yaml -f metrics-server/values-aws.yaml --wait
```

Only after a domain exists, install external-dns with `--set externalDns.enabled=true` (and the real `domainFilters` in the values file) into the `external-dns` namespace.

Render without installing, at any time:

```bash
make addons-check
```

## Post-install checks

### Pods running

```bash
kubectl get pods -n cert-manager
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller   # EKS
kubectl get pods -n kube-system -l app.kubernetes.io/name=metrics-server                 # EKS
kubectl get pdb -A | grep -E 'cert-manager|metrics-server|aws-load-balancer'
```

All pods should be `Running` and `Ready`, with the replica counts in the values files (2 for cert-manager components, the load balancer controller and metrics-server).

### Metrics

```bash
kubectl top nodes
kubectl top pods -A
```

Both should return numbers within a minute or two of metrics-server starting (EKS). On GKE these work out of the box.

### Self-signed certificate

```bash
kubectl apply -f - <<'YAML'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: addons-test
  namespace: default
spec:
  secretName: addons-test-tls
  dnsNames: [addons-test.local]
  issuerRef: {name: selfsigned, kind: ClusterIssuer}
YAML
kubectl wait --for=condition=Ready certificate/addons-test --timeout=60s
kubectl get secret addons-test-tls
kubectl get clusterissuer
```

Expect the certificate `Ready`, the secret present, and `selfsigned` and `internal-ca` both `Ready`. Repeat with `issuerRef: {name: internal-ca, kind: ClusterIssuer}` to test the CA issuer. Clean up with `kubectl delete certificate addons-test` and `kubectl delete secret addons-test-tls`.

### Test Ingress on EKS

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
kubectl get ingress web -w     # an ALB host name appears in ADDRESS after a few minutes
```

Then `curl -I http://<ADDRESS>`. This creates an internet-facing ALB, which bills hourly; delete it when done (see teardown).

### Test Ingress on GKE

```bash
kubectl create deployment web --image=public.ecr.aws/nginx/nginx:stable --port=80
kubectl expose deployment web --type=NodePort --port=80 --target-port=80
kubectl apply -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web
  annotations:
    kubernetes.io/ingress.class: gce
spec:
  defaultBackend:
    service: {name: web, port: {number: 80}}
YAML
kubectl get ingress web -w     # an external IP appears in ADDRESS after a few minutes
```

GKE Ingress with the `gce` class needs a `NodePort` or `LoadBalancer` service with NEGs or node ports; the health check path defaults to `/`.

### DNS-01 (only when a domain exists)

After enabling a DNS-01 issuer, check `kubectl describe clusterissuer letsencrypt-route53` (or `letsencrypt-clouddns`) shows `Ready`, then request a certificate for a host in the zone using the staging server before switching to production.

## Teardown order

Delete anything that makes the cloud create load balancers **before** destroying the cluster, otherwise the load balancers, forwarding rules, target groups and network interfaces are left behind, keep billing and block deletion of subnets and VPCs.

1. Delete test and application `Ingress` and `Service` (type `LoadBalancer`) objects, and wait for the cloud load balancers to disappear:

   ```bash
   kubectl delete ingress --all -A
   kubectl delete svc -A --field-selector spec.type=LoadBalancer
   kubectl delete pvc --all -A
   ```

   Confirm: `aws elbv2 describe-load-balancers` (EKS) or `gcloud compute forwarding-rules list` (GKE) show none from the cluster.
2. Remove external-dns first if it was running, so it does not recreate records, then delete the DNS records it created if you do not want them left.
3. Uninstall the add-ons (or let Argo CD prune them): the load balancer controller after its Ingress and Service objects are gone, then cert-manager-issuers, cert-manager and the rest. cert-manager's CRDs are kept on uninstall by design; delete them (`kubectl delete crd -l app.kubernetes.io/name=cert-manager`) only if you also want the certificates removed.
4. Destroy the cluster and network following the [EKS](aws-eks.md) and [GKE](gcp-gke.md) runbooks.
5. Destroy the add-on IAM roles and service accounts by applying with `enable_*_iam=false` (or `terraform destroy`).

## Troubleshooting

- **Load balancer controller crash-loops or says it cannot find the VPC or region:** `clusterName`, `region` and `vpcId` must be set in `values-aws.yaml`.
- **Ingress has no ADDRESS on EKS:** check the controller logs (`kubectl logs -n kube-system deploy/aws-load-balancer-controller`) and that the public subnets carry `kubernetes.io/role/elb` and the cluster tag.
- **`no matches for kind ClusterIssuer`:** cert-manager's CRDs are not installed yet; install cert-manager first.
- **`kubectl top` shows `Metrics API not available`:** wait for metrics-server to be ready; on EKS confirm the pods run and the APIService `v1beta1.metrics.k8s.io` is `Available`.
- **cert-manager webhook timeouts on a private GKE cluster:** the control plane must reach the nodes on port 10250; GKE creates this rule by default, so check for custom firewall changes.
