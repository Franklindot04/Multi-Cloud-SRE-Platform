# Platform

Cluster-level configuration reconciled onto the clusters by Argo CD. Terraform provisions the clusters; everything that runs on them is declared here.

| Path | Purpose |
| --- | --- |
| `argocd/` | Argo CD installation, projects and app-of-apps roots |
| `addons/` | Cluster baseline add-ons as pinned Helm wrapper charts: AWS Load Balancer Controller, external-dns, cert-manager and metrics-server (see [`addons/README.md`](addons/README.md)) |
| `observability/` | Metrics, logs, traces, alerting and dashboards |
| `security/` | Policy engine, secrets integration, network policies, RBAC |
