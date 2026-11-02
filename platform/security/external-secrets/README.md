# external-secrets

The External Secrets Operator from the official chart (`https://charts.external-secrets.io`), pinned by version in [`Chart.yaml`](Chart.yaml) and by digest in `Chart.lock`, as for the other wrapper charts: the downloaded tarball (`charts/`) is not committed, and Argo CD and the check scripts run `helm dependency build`. **This installs the operator only.** The store is in [`external-secrets-store`](../external-secrets-store), the network policies are in [`external-secrets-network-policies`](../external-secrets-network-policies), and no ExternalSecret is deployed by any of them. Argo CD deploys it to EKS clusters labelled `platform.example/external-secrets=true` (off by default; `scripts/bootstrap-argocd.sh --enable-external-secrets`).

| | |
| --- | --- |
| Chart | `external-secrets` **2.14.0**, application **v2.14.0** (released 2026-10-16) |
| Source | `https://charts.external-secrets.io` (Apache-2.0) |
| Namespace | `external-secrets`, Pod Security level `restricted` (the pods comply: non-root, read-only root filesystem, no capabilities, `RuntimeDefault` seccomp) |
| AppProject | `platform-addons` (the namespace is a destination; the cluster-scoped kinds the chart renders were already allowed, and `ClusterSecretStore` was added for the store) |
| Priority class | `platform-addons-critical` on all three pods |
| Pods | the controller, the webhook and the certificate controller; one replica each, no leader election |
| Requests | 100m CPU and 228Mi of memory in total (50m and 100Mi, 25m and 64Mi, 25m and 64Mi); limits 400m and 456Mi |
| Metrics | port 8080 of every pod, through a Service each; scraped by the ServiceMonitor `external-secrets` of [`monitors`](../../observability/monitors) |

**Compatibility.** The chart's `kubeVersion` is `>= 1.19.0-0`. The project's support table (`https://external-secrets.io/latest/introduction/stability-support/`, read on 2026-11-02) lists Kubernetes 1.37 for ESO 2.14, so the version is tested by the project against the version of the EKS cluster. Only the latest minor version receives support. Nothing has run on a cluster.

**The role.** The controller signs in to AWS with the IAM role of its service account (IAM roles for service accounts). The service account is made by this chart (`templates/serviceaccount.yaml`), not by the subchart, with the annotation `eks.amazonaws.com/role-arn`. The value `roleArn` comes from the cluster annotation `platform.example/external-secrets-role-arn` (Terraform output `external_secrets_role_arn`, module `aws-external-secrets-iam`), and **the chart refuses to render without it**, so the operator never starts without its role. The service account is named `external-secrets` in the namespace `external-secrets`, which is what the role trusts.

**The webhooks.** The chart renders two `ValidatingWebhookConfiguration` objects (`secretstore-validate` and `externalsecret-validate`), which validate stores and ExternalSecrets. `webhook.failurePolicy` is `Ignore`, so every webhook of both fails open: a dead operator cannot block the cluster. The cost is that an invalid store or ExternalSecret is accepted and reported by the controller instead. The certificate controller writes the CA bundle into the webhooks and the certificate into the Secret `external-secrets-webhook`, so the Application ignores those two fields (`ignoreDifferences` with `RespectIgnoreDifferences`).

**The CRDs** are larger than a client-side apply can store (the `SecretStore` and `ClusterSecretStore` CRDs are about 740 KB each), so the Application uses `ServerSideApply=true`.

Checks: `make external-secrets-check` (`scripts/external-secrets-check.sh`) lints, renders and schema-checks the three charts and runs the contracts (restricted Pod Security, the requests and the webhook settings above, the role, the fit with the `platform-addons` AppProject, `ServerSideApply`); `make network-policies-check` evaluates the flows of the policies.

The design is in [ADR-0027](../../../docs/adr/0027-external-secrets.md); setting up, checking and rotating are in the [secrets runbook](../../../docs/runbooks/secrets.md).
