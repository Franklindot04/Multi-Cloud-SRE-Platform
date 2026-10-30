# Argo CD

The GitOps hub. One Argo CD instance runs on the EKS cluster, deploys the cluster add-ons from [`platform/addons`](../addons) to every registered cluster, and manages its own upgrades. Design rationale is in [ADR-0012](../../docs/adr/0012-argocd-hub-and-gitops-structure.md); step-by-step instructions are in the [Argo CD runbook](../../docs/runbooks/argocd.md).

## Pinned version

| Component | Version | Source | Checked |
| --- | --- | --- | --- |
| `argo-cd` Helm chart | **10.11.1** (released 2026-10-23) | `https://argoproj.github.io/argo-helm` (argo-helm) | 2026-10-26 |
| Argo CD | **v3.5.6** (the chart's app version) | same chart | 2026-10-26 |

10.11.1 is the newest release in the chart index; it is not marked deprecated and requires Kubernetes 1.25 or later. The exact chart version and its digest are pinned in [`install/Chart.yaml`](install/Chart.yaml) and [`install/Chart.lock`](install/Chart.lock).

### Chart changes that matter here

From the chart's own changelog (read on 2026-10-26):

- **10.0.0:** `global.networkPolicy.create` defaults to `true`, so the chart ships network policies. They are kept enabled here.
- **9.1.0:** upgrading an existing install that uses `redis-ha` complains about an immutable selector on `argocd-redis-ha-haproxy`. This only affects an upgrade of a running HA install; a fresh HA install (`values-ha.yaml`) is unaffected. The chart notes that server-side diffing must be off while fixing it.
- **9.0.0:** the `configs.params` defaults were removed from the chart (the interface is unchanged), and `applicationsetcontroller.policy` now follows upstream, whose default allows the ApplicationSet controller to create, update and delete Applications. This platform relies on that default.
- **8.0.0:** the chart moved to Argo CD 3.x. Read the upstream v2.14 to 3.0 upgrade notes when moving between major versions.
- **CRDs:** the chart annotates its CRDs for server-side apply, which is needed because the ApplicationSet CRD exceeds the client-side apply size limit. The self-managing Application also syncs with `ServerSideApply=true`.

The changelog has no entries about sync waves or multi-source applications. This platform does not use multi-source applications: each Application has one source (a wrapper chart in this repository), and cluster identifiers are passed as Helm parameters. Sync waves are used as described below.

## Layout

```text
platform/argocd/
  install/        wrapper chart: pinned argo-cd chart, values.yaml, values-ha.yaml
  bootstrap/      applied once by scripts/bootstrap-argocd.sh:
                    appproject-platform-system.yaml   Argo CD itself and the GitOps definitions
                    appproject-platform-addons.yaml   the add-ons
                    appproject-platform-apps.yaml     the sample services (shop namespace only)
                    appproject-platform-observability.yaml  the metrics foundation (observability namespace)
                    root-application.yaml             app-of-apps, points at apps/
  apps/           synced by the root Application:
                    00-argocd.yaml                    Argo CD manages its own upgrades
                    10-... 61-...                     ApplicationSets for the add-ons
                    70-... 78-...                     the data layer (and the RabbitMQ credential copy)
                    80-... 83-...                     the sample services, one ApplicationSet each
                    90-... 94-...                     the metrics foundation (platform/observability)
```

## How clusters are described

A cluster is a Secret in the `argocd` namespace. Its **labels** choose which add-ons it gets, and its **annotations** carry the identifiers that the ApplicationSets turn into Helm parameters, so account IDs, VPC IDs, role ARNs and project IDs are never committed to Git. `scripts/bootstrap-argocd.sh` creates the secret for the EKS hub from Terraform outputs; a GKE cluster is registered the same way later.

| Label | Values | Meaning |
| --- | --- | --- |
| `platform.example/managed` | `true` | The cluster receives the baseline add-ons |
| `platform.example/cloud` | `aws`, `gcp` | Selects the cloud overlay (`values-aws.yaml` or `values-gcp.yaml`) and cloud-only add-ons |
| `platform.example/external-dns` | `true`, `false` | Deploy external-dns (default `false`) |
| `platform.example/dns01` | `true`, `false` | Create the Let's Encrypt DNS-01 ClusterIssuer (default `false`) |
| `platform.example/data` | `true`, `false` | Deploy the data layer from `platform/data` (default `false`; volumes it creates outlive `terraform destroy`) |
| `platform.example/data-profile` | `standard`, `ha` | Data layer profile (default `standard`; `ha` needs three nodes) |
| `platform.example/observability` | `true`, `false` | Deploy the metrics foundation from `platform/observability` (default `false`; no volumes, no ingress) |
| `platform.example/apps` | `true`, `false` | Deploy the sample services from `deploy/helm` (default `false`; needs published images) |
| `platform.example/apps-profile` | `memory`, `data` | Service profile (default `memory`; `data` needs the data layer) |

| Annotation (prefix `platform.example/`) | Used for |
| --- | --- |
| `cluster-name` | load balancer controller cluster name, external-dns owner ID |
| `region` | load balancer controller, external-dns, Route 53 issuer region |
| `account-id` | recorded for reference and verified by the bootstrap script |
| `vpc-id` | load balancer controller VPC |
| `lbc-role-arn`, `external-dns-role-arn`, `cert-manager-role-arn` | IRSA role annotations on the service accounts (AWS) |
| `external-dns-sa-email`, `cert-manager-sa-email` | Workload Identity annotations (GCP) |
| `project-id` | external-dns and Cloud DNS issuer project (GCP) |
| `hosted-zone-id` | Route 53 DNS-01 issuer |
| `dns-domain` | external-dns domain filter |
| `acme-email` | ACME account email for the DNS-01 issuers |

Only the EKS cluster exists today. Adding GKE means creating a second cluster secret with `cloud=gcp`; no file in this directory changes. The ApplicationSets use the cluster generator with a label selector, so a new matching cluster gets its applications automatically.

## Sync order and CRD ordering

The ApplicationSets carry `argocd.argoproj.io/sync-wave` annotations, so the root Application creates them in this order:

| Wave | ApplicationSet |
| --- | --- |
| -1 | `argocd` (the Application for Argo CD itself) |
| 0 | `priority-classes` |
| 1 | `cert-manager` |
| 2 | `cert-manager-issuers` |
| 3 | `metrics-server`, `aws-load-balancer-controller` |
| 4 | `external-dns` (only on labelled clusters) |
| 5 | `data-namespaces`, `data-storage` (only on clusters labelled `platform.example/data=true`) |
| 6 | `data-secrets`, `data-cnpg-operator`, `data-rabbitmq-operator` |
| 7 | `data-postgres`, `data-valkey`, `data-rabbitmq` |
| 8 | `data-rabbitmq-credentials` (copies the broker credentials into `shop`) |
| 10 | `observability-secrets` (only on clusters labelled `platform.example/observability=true`) |
| 11 | `observability-stack` (Prometheus Operator, Prometheus, Grafana) |
| 12 | `observability-collector` |
| 13 | `observability-monitors` |
| 14 | `observability-dashboards` (Grafana dashboards as ConfigMaps) |
| 20 | `apps-notifier`, `apps-payments` (only on clusters labelled `platform.example/apps=true`) |
| 21 | `apps-orders` |
| 22 | `apps-gateway` |

Waves order how the ApplicationSets are created; each generated Application then syncs on its own, and Argo CD does not wait for one Application before starting another. Consumers therefore wait for what they need (the PostgreSQL chart has a PreSync gate for the role Secrets, the credential copy waits for the broker's Secret); see [ADR-0018](../../docs/adr/0018-secret-generation-and-ordering.md). The one hard dependency, the issuers needing cert-manager's CRDs and webhook, is enforced where it matters:

- The issuers chart has a PreSync hook Job that waits for the cert-manager CRDs to exist and be established, and for the webhook Deployment to roll out, before any ClusterIssuer is applied.
- The issuer manifests use `SkipDryRunOnMissingResource=true`, and every Application retries with exponential backoff, so a race self-heals.
- Argo CD's built-in health checks for cert-manager resources mark an issuer Healthy only when it is Ready.
- cert-manager is applied server-side (`ServerSideApply=true`) because of its large CRDs.

`ignoreDifferences` is used only where something else legitimately rewrites a field: the webhook CA bundle written by cainjector, the load balancer controller's per-render webhook certificate, and the Secrets that Argo CD itself maintains.

## Access and security posture

- No ingress: the server runs in insecure (plain HTTP) mode **inside the pod** because it is reached only through `kubectl port-forward`, which is already authenticated and encrypted by the Kubernetes API. Remove that setting when an ingress with TLS is added.
- Default RBAC role is read-only (`policy.default: role:readonly`); Dex and notifications are disabled.
- The built-in `admin` account is kept for bootstrap. Rotate its password after the first login and delete the initial secret (see the runbook).
- A fourth AppProject, `platform-apps`, restricts the sample services to the `shop` namespace and a short allowlist of namespaced kinds (the only cluster-scoped kind is `Namespace`), so it cannot reach the `data` namespace or its volumes. A third AppProject, `platform-data`, restricts the data layer to the namespaces `data`, `shop`, `cnpg-system` and `rabbitmq-system` and an allowlist of cluster-scoped kinds that includes StorageClass.
- A fifth AppProject, `platform-observability`, restricts the metrics foundation to the namespaces `observability` and `kube-system` (for the CoreDNS Service the stack creates there), the cluster-scoped kinds a Prometheus Operator install needs (the namespace, CRDs and read-only roles, but no webhook configurations) and a short allowlist of namespaced kinds. The existing projects do not fit: `platform-addons` allows other namespaces and kinds, and `platform-data` and `platform-apps` are scoped to the data and shop namespaces. The monitors for the services and the data layer live in the `observability` namespace and select their targets, so this project cannot touch `shop` or `data`. `make observability-check` verifies that everything the charts render is allowed by it.
- AppProjects limit sources to this repository, destinations to the namespaces in use, and cluster-scoped kinds to an allowlist, and warn about orphaned resources.

## Checks

```bash
make argocd-check
```

The metrics foundation has its own check, `make observability-check` (see [`platform/observability`](../observability)).

Runs `helm lint`, `helm template` and `kubeconform` on the install chart (default and HA values), `kubeconform` on every Application, ApplicationSet and AppProject (with Argo CD CRD schemas from the pinned `datreeio/CRDs-catalog` commit `3eb90d47`), `yamllint`, `shellcheck` (through `scripts/shellcheck.sh`: `-S style`, version 0.11.0, the same as CI), and a render test: every referenced path and values file exists, every project is defined, and every templated Helm parameter changes the rendered output of its chart. Missing tools are skipped.
