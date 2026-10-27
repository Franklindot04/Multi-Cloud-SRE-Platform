# Platform

Cluster-level configuration reconciled onto the clusters by Argo CD. Terraform provisions the clusters; everything that runs on them is declared here.

| Path | Purpose |
| --- | --- |
| `argocd/` | Argo CD hub: pinned install chart, AppProjects, the root app-of-apps and the ApplicationSets that deploy the add-ons (see [`argocd/README.md`](argocd/README.md)) |
| `addons/` | Cluster baseline add-ons as pinned Helm wrapper charts: AWS Load Balancer Controller, external-dns, cert-manager and metrics-server (see [`addons/README.md`](addons/README.md)) |
| `data/` | Data layer: PostgreSQL (CloudNativePG), a Valkey cache and RabbitMQ with their operators, namespaces, storage class and in-cluster credential generation (see [`data/README.md`](data/README.md)); off unless a cluster is labelled `platform.example/data=true` |
| `observability/` | Metrics, logs, traces, alerting and dashboards |
| `security/` | Policy engine, secrets integration, network policies, RBAC |
