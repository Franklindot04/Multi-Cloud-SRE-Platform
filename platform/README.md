# Platform

Cluster-level configuration reconciled onto the clusters by Argo CD. Terraform provisions the clusters; everything that runs on them is declared here.

| Path | Purpose |
| --- | --- |
| `argocd/` | Argo CD installation, projects and app-of-apps roots |
| `addons/` | Cluster add-ons (ingress, cert-manager, external-dns, autoscaling) |
| `observability/` | Metrics, logs, traces, alerting and dashboards |
| `security/` | Policy engine, secrets integration, network policies, RBAC |
