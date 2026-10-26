# cert-manager-issuers

ClusterIssuers for cert-manager. This is a plain local chart (no dependency) because the issuer resources need cert-manager's CRDs, which are installed by the separate [`cert-manager`](../cert-manager) add-on. Deploy it after cert-manager is ready; the manifests carry Argo CD sync waves and `SkipDryRunOnMissingResource` so a first sync does not fail before the CRDs exist.

| Issuer | Created | Purpose |
| --- | --- | --- |
| `selfsigned` | by default | Signs the internal CA; also usable directly. Needs no domain. |
| `internal-ca` | by default | CA-style issuer backed by a self-signed root certificate. Workloads can trust one root. Needs no domain. |
| `letsencrypt-route53` | `dns01.route53.enabled: true` | ACME DNS-01 through Route 53, using IRSA. Off by default. |
| `letsencrypt-clouddns` | `dns01.cloudDns.enabled: true` | ACME DNS-01 through Cloud DNS, using Workload Identity. Off by default. |

The DNS-01 issuers exist as manifests but are disabled, and nothing references them. Enable one only after the domain, hosted zone and the matching IAM role or service account exist. They default to the Let's Encrypt staging server (`dns01.acmeServer`); switch to production (`https://acme-v02.api.letsencrypt.org/directory`) after testing.

Example certificate from the self-signed issuer:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test
spec:
  secretName: test-tls
  dnsNames: [test.local]
  issuerRef: {name: selfsigned, kind: ClusterIssuer}
```

Files under `ci/` are extra values used only by the add-on checks to render the optional issuers.
