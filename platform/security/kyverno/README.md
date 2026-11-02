# kyverno

The Kyverno policy engine from the official chart (`https://kyverno.github.io/kyverno/`), pinned by version in [`Chart.yaml`](Chart.yaml) and by digest in `Chart.lock`, as for the other wrapper charts: the downloaded tarball (`charts/`) is not committed, and Argo CD and the check scripts run `helm dependency build`. **This installs the engine only. No policy is deployed by it** (the policies are in [`policies`](../policies), a separate Application). Argo CD deploys it to clusters labelled `platform.example/policy=true` (off by default; `scripts/bootstrap-argocd.sh --enable-policy`).

| | |
| --- | --- |
| Chart | `kyverno` **3.9.2**, Kyverno **v1.19.2** |
| Source | `https://kyverno.github.io/kyverno/` (Apache-2.0) |
| Namespace | `kyverno`, Pod Security level `restricted` |
| AppProject | `platform-addons` (the namespace is a destination; the cluster-scoped kinds the chart renders were already allowed) |
| Controllers | admission, background, cleanup, reports; one replica each (`values-ha.yaml`: three admission replicas) |
| Requests | 225m CPU and 320Mi of memory in total (`values-ha.yaml`: 425m and 576Mi) |
| Metrics | port 8000 of every controller, scraped through the ServiceMonitor of [`monitors`](../../observability/monitors) |

**Compatibility.** The chart requires Kubernetes 1.25 or later (`kubeVersion`), which does not exclude the 1.37 of the EKS cluster. The Kyverno documentation lists Kubernetes 1.33 to 1.35 as supported for v1.19 and says other versions may work but are not tested. **Compatibility with 1.37 is therefore not confirmed**, and nothing has run on a cluster.

**The webhooks.** Kyverno creates its webhook configurations itself, when there are policies; the chart renders none. They exclude the namespaces `kube-system`, `kube-node-lease`, `argocd` and `kyverno`, and `features.forceFailurePolicyIgnore` makes every one of them fail open, so Kyverno being down cannot block the cluster.

**The CRDs** are larger than a client-side apply can store (the biggest, `clusterpolicies.kyverno.io`, is about 675 KB), so the Application uses `ServerSideApply=true`.

[`network-policies`](../network-policies) has the default deny and the allow rules of the `kyverno` namespace. Checks: `make policy-check` (`scripts/policy-check.sh`) lints, renders and schema-checks both charts and runs the contracts (restricted Pod Security, the requests and the webhook settings above, the fit with the `platform-addons` AppProject, `ServerSideApply`); `make network-policies-check` evaluates the flows of the policies.
