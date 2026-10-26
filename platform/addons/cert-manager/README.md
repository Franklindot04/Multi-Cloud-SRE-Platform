# cert-manager

Issues and renews certificates. Chart: `cert-manager` v1.21.3 from `https://charts.jetstack.io`. Issuers are deployed separately by [`cert-manager-issuers`](../cert-manager-issuers), after this chart's CRDs exist.

- **Namespace:** `cert-manager`
- **CRDs:** installed by the chart (`crds.enabled: true`) and kept on uninstall (`crds.keep: true`), so removing the add-on does not delete your certificates.
- **High availability:** two replicas each for the controller, webhook and cainjector, with pod disruption budgets (`minAvailable: 1`).
- **Hardening:** non-root, seccomp `RuntimeDefault`, read-only root filesystem and no privilege escalation (chart defaults), resource requests and limits on every component, and the `platform-addons-critical` priority class.
- **Permissions:** only needed for DNS-01. Argo CD sets the service account annotation (IRSA or Workload Identity) from the cluster Secret; it has no effect until a DNS-01 issuer is enabled.
- **EKS:** `fsGroup: 1001` lets the non-root pod read the IRSA token.
- **Metrics:** Prometheus scraping is off until the observability stack exists.
