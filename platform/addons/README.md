# Cluster add-ons

GitOps-ready definitions of the baseline add-ons for both clusters. Argo CD deploys them from this directory in the next change (see [ADR-0011](../../docs/adr/0011-cluster-baseline-addons.md)). **Nothing is installed by these definitions.** The cloud permissions they need are created by Terraform in `infra/terraform/environments/<cloud>/addons-iam.tf`.

## Components and pinned versions

Chart versions were checked on **2026-10-26** against each project's official Helm repository index. All four are the newest stable release listed, none is marked deprecated, and all are actively maintained by their upstream projects.

| Add-on | Chart | Chart version | App version | Chart released | Source | Clouds |
| --- | --- | --- | --- | --- | --- | --- |
| [aws-load-balancer-controller](aws-load-balancer-controller) | `aws-load-balancer-controller` | 3.6.2 | v3.6.2 | 2026-10-25 | `https://aws.github.io/eks-charts` | EKS |
| [external-dns](external-dns) | `external-dns` | 1.23.0 | 0.23.0 | 2026-09-30 | `https://kubernetes-sigs.github.io/external-dns/` | EKS, GKE |
| [cert-manager](cert-manager) | `cert-manager` | v1.21.3 | v1.21.3 | 2026-10-23 | `https://charts.jetstack.io` | EKS, GKE |
| [metrics-server](metrics-server) | `metrics-server` | 3.14.0 | 0.9.0 | 2026-08-19 | `https://kubernetes-sigs.github.io/metrics-server/` | EKS |

The load balancer controller chart was published one day before the check. It is the newest stable release, so it is pinned; revisit it if upstream reports a regression.

Local charts (no upstream dependency): [cert-manager-issuers](cert-manager-issuers) and [priority-classes](priority-classes).

### Ingress controller: ingress-nginx is not used

The Kubernetes project announced the retirement of **ingress-nginx** in November 2025, with best-effort maintenance ending in March 2026 and no further releases, bug fixes or security fixes afterwards ([announcement](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/), [steering statement](https://www.kubernetes.io/blog/2026/01/29/ingress-nginx-statement/)). It is therefore not deployed. Each cloud uses its native load balancer integration instead:

| Cloud | Ingress | Notes |
| --- | --- | --- |
| EKS | AWS Load Balancer Controller (`IngressClass` `alb`) | ALBs for `Ingress`, NLBs for `Service` of type `LoadBalancer`. Installed by this directory. |
| GKE | GKE Ingress (class `gce` for external, `gce-internal` for internal) | Built in: the HTTP load balancing add-on is on by default, so no controller is installed. GKE Gateway API (`GatewayClass` such as `gke-l7-global-external-managed`) is the preferred long-term model; it needs `gateway_api_config` enabled on the cluster, which the `gcp-gke` module does not set yet. |

GKE also ships its own metrics-server, which is why that add-on targets EKS only.

## Layout and approach

Each add-on is a small Helm **wrapper chart**:

```text
platform/addons/<name>/
  Chart.yaml            wrapper chart; the upstream chart is a pinned dependency
  Chart.lock            resolved dependency digest (committed)
  values.yaml           shared values, nested under the dependency name
  values-aws.yaml       EKS overrides (where they differ)
  values-gcp.yaml       GKE overrides (where they differ)
  templates/            extra manifests (issuers, priority classes)
  ci/<cloud>-*.yaml     extra value sets used only by the checks
  README.md
```

A wrapper chart was chosen over Kustomize `helmCharts` because Argo CD renders Helm charts and their dependencies natively (no kustomize `--enable-helm` flag or plugin), the exact chart version and its digest are pinned in `Chart.yaml` and `Chart.lock`, and extra manifests can live in the same chart. The `charts/` directory that `helm dependency build` creates is not committed.

The `platform/clouds` annotation in each `Chart.yaml` lists the clouds an add-on applies to, and the checks use it.

### Namespaces and priority

| Add-on | Namespace | Priority class |
| --- | --- | --- |
| aws-load-balancer-controller, metrics-server | `kube-system` | `system-cluster-critical` |
| cert-manager, external-dns | `cert-manager`, `external-dns` | `platform-addons-critical` |

The built-in `system-*` classes are reserved for `kube-system`, so add-ons in their own namespaces use `platform-addons-critical`, defined by [priority-classes](priority-classes).

### Deployment order

1. `priority-classes`
2. `cert-manager` (installs the CRDs)
3. `cert-manager-issuers` (after the CRDs exist)
4. `aws-load-balancer-controller`, `metrics-server` (EKS)
5. `external-dns` (only when a domain exists)

### Workload identity placeholders

Service account annotations in `values-aws.yaml` and `values-gcp.yaml` hold `REPLACE_...` placeholders. Replace them with the Terraform outputs: `aws_load_balancer_controller_role_arn`, `external_dns_role_arn` and `cert_manager_role_arn` (AWS), and `external_dns_service_account_email` and `cert_manager_service_account_email` (GCP). Also set `vpcId` for the load balancer controller from `vpc_id`.

## Disabled until a domain exists

- **external-dns** renders nothing until `externalDns.enabled` is set to `true`.
- **DNS-01 ClusterIssuers** for Route 53 and Cloud DNS are templates that are off by default (`dns01.*.enabled: false`).
- The **self-signed** and **internal CA** issuers work without a domain and are on by default.

## Version pinning policy

- Pin the exact chart version and keep `Chart.lock` committed; never use ranges or `latest`.
- Move to a new version in a pull request that updates `Chart.yaml`, regenerates `Chart.lock` (`ADDONS_UPDATE=1 ./scripts/addons-check.sh`), and passes the checks. Read the upstream release notes first, especially for CRD changes in cert-manager.
- Update the table above (version, date checked, source) in the same pull request.
- Keep the vendored load balancer controller IAM policy in step with the controller version.
- Review versions at least monthly and when upstream publishes a security fix.

## Checks

```bash
make addons-check
```

For every add-on and each cloud it targets this runs `helm lint --strict`, `helm template` and `kubeconform` (strict mode, with a CRD schema catalog), plus the optional features in `ci/`, then `yamllint`. Schemas are pinned to the Kubernetes version each cluster runs: **1.37** for EKS (the `aws-eks` module default) and **1.36** for GKE (the current default of the Regular release channel, checked 2026-10-26 in the GKE release notes). CustomResourceDefinitions are not schema-checked. The target skips with a message if `helm` or `kubeconform` is not installed.
