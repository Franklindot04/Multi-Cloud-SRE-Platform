# external-dns

Creates DNS records for `Ingress` and `Service` resources in Route 53 (EKS) or Cloud DNS (GKE). Chart: `external-dns` 1.23.0 from `https://kubernetes-sigs.github.io/external-dns/`.

- **Disabled by default.** The wrapper chart gates the dependency on `externalDns.enabled: false`, so it renders nothing until it is switched on. Enable it only after the domain and DNS zones exist (see the [global DNS runbook](../../../docs/runbooks/global-dns.md)) and `domainFilters` is set to your domain.
- **Namespace:** `external-dns`
- **Safety:** `policy: upsert-only` (no deletions), a TXT registry with a per-cluster `txtOwnerId`, and domain filters. Never run it without domain filters.
- **Permissions:** IRSA (`values-aws.yaml`) or Workload Identity (`values-gcp.yaml`), created by `addons-iam.tf` in each environment stack and scoped to the one hosted zone. Replace the annotation placeholders with the stack outputs.
- **Defaults:** one replica (the chart's maximum), non-root with a read-only root filesystem, resource requests and limits, and the `platform-addons-critical` priority class.

Enable by setting `externalDns.enabled: true` (and the real domain) in the Argo CD Application values.
