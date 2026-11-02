# Security

Cluster security baseline: admission policies, external secrets integration (the External Secrets Operator and the store, see [ADR-0027](../../docs/adr/0027-external-secrets.md)), network policies, pod security standards and RBAC. Policies are enforced in CI and at admission time.

## What is here

| Directory | Purpose |
| --- | --- |
| [`kyverno`](kyverno) | The Kyverno policy engine, without policies (off by default: `scripts/bootstrap-argocd.sh --enable-policy`) |
| [`policies`](policies) | The Kyverno admission policies for the `shop` namespace (images, signatures, resources, probes, labels), in Audit by default |
| [`network-policies`](network-policies) | Default deny and the allow rules of the `kyverno` namespace (EKS only) |
| [`external-secrets`](external-secrets) | The External Secrets Operator, without a store or an ExternalSecret (off by default: `scripts/bootstrap-argocd.sh --enable-external-secrets`; EKS only) |
| [`external-secrets-store`](external-secrets-store) | The ClusterSecretStore `aws-parameter-store` for AWS Systems Manager Parameter Store, signing in with the operator's IAM role; no credential |
| [`external-secrets-network-policies`](external-secrets-network-policies) | Default deny and the allow rules of the `external-secrets` namespace (EKS only) |
