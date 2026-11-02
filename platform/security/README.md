# Security

Cluster security baseline: admission policies, external secrets integration, network policies, pod security standards and RBAC. Policies are enforced in CI and at admission time.

## What is here

| Directory | Purpose |
| --- | --- |
| [`kyverno`](kyverno) | The Kyverno policy engine, without policies (off by default: `scripts/bootstrap-argocd.sh --enable-policy`) |
| [`policies`](policies) | The Kyverno admission policies for the `shop` namespace (images, signatures, resources, probes, labels), in Audit by default |
| [`network-policies`](network-policies) | Default deny and the allow rules of the `kyverno` namespace (EKS only) |
