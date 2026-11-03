# argo-rollouts

The Argo Rollouts controller from the official chart (`https://argoproj.github.io/argo-helm`), pinned by version in [`Chart.yaml`](Chart.yaml) and by digest in `Chart.lock`, as for the other wrapper charts: the downloaded tarball (`charts/`) is not committed, and Argo CD and the check scripts run `helm dependency build`. **This installs the controller only.** It deploys no Rollout and no analysis template itself; the service chart (`deploy/helm/service`) renders them for the gateway when its `rollout.enabled` is set, which Argo CD does from the same cluster label (see [ADR-0028](../../../docs/adr/0028-progressive-delivery.md)). The network policies are in [`argo-rollouts-network-policies`](../argo-rollouts-network-policies). Argo CD deploys it to clusters labelled `platform.example/progressive-delivery=true` (off by default; `scripts/bootstrap-argocd.sh --enable-progressive-delivery`).

| | |
| --- | --- |
| Chart | `argo-rollouts` **2.43.8**, application **v1.10.1** (the chart is dated 2026-10-16) |
| Source | `https://argoproj.github.io/argo-helm` (Apache-2.0) |
| Namespace | `argo-rollouts`, Pod Security level `restricted` (the pod complies: non-root, read-only root filesystem, no capabilities, `RuntimeDefault` seccomp) |
| AppProject | `platform-addons` (only the namespace is new in its destinations; every kind the chart renders was already allowed) |
| Priority class | `platform-addons-critical` |
| Pod | the controller, one replica |
| Requests | 50m CPU and 64Mi of memory; limits 200m and 192Mi |
| Metrics | port 8090, through the Service `argo-rollouts-metrics`; scraped by the ServiceMonitor `argo-rollouts` of [`monitors`](../../observability/monitors) |

**Kubernetes versions.** The chart has no `kubeVersion` field, and the project's documentation does not state a range of supported Kubernetes versions. What the project does publish is its end-to-end test matrix: for v1.10.1 it runs against Kubernetes 1.32 to 1.35. The cluster of this platform runs 1.37, which is outside that matrix. **That 1.37 is supported is therefore not confirmed**: no statement from the project says so, and nothing has run on a cluster. The controller uses only core APIs and its own CRDs, so nothing is known to be wrong, but this is a guess and it is recorded as one. Check it again when the pin changes.

**One replica, and what happens when it is down.** The chart can run two replicas with leader election (`values-ha.yaml` is the setting, not used by Argo CD). One replica is chosen because the room left on the nodes is small (about 1.7 vCPU and 12 GiB, see the [resilience runbook](../../../docs/runbooks/resilience.md)) and the node-loss case is already tight on CPU, and because a stopped controller costs little: Rollouts that exist keep their ReplicaSets and Services, so traffic is not interrupted. What stops is the progress of any rollout in flight (a canary does not advance, a failed analysis does not abort) and the reaction to a change of the spec, until the Deployment is back, which the kubelet and the ReplicaSet do within a minute or so on a healthy node. The priority class keeps the pod from being evicted before the services. A second replica would double the requests (to 100m and 128Mi) for faster recovery after a node loss; revisit it when a service really rolls out through a Rollout.

**What is left out.** No dashboard (`dashboard.enabled: false`; it has no authentication of its own and nothing needs it). No notifications (`notifications.configmap.create` and `notifications.secret.create` are false, so no Secret is rendered). No rights on a traffic router (`providerRBAC.enabled: false`): a Rollout here splits traffic by replica count, with no mesh or ingress provider. There is no webhook, so the controller cannot block an API call when it is down.

**The image** is the one of the chart (`quay.io/argoproj/argo-rollouts`, tag v1.10.1). It is not recorded in `deploy/helm/values/images.yaml`, which is for the images of the services, and no digest is added there. Like the images of the other wrapper charts it is outside the `shop` namespace, so the admission policies for registries, digests and signatures do not apply to it.

**The CRDs** (five: `rollouts`, `analysisruns`, `analysistemplates`, `clusteranalysistemplates` and `experiments`, all `argoproj.io`) are 175 to 232 KiB each as rendered (237,667 bytes at most, measured on the chart). Client-side apply stores the last applied configuration in an annotation, which is capped at 256 KiB, so they are close enough to the cap that the Application uses `ServerSideApply=true`. `keepCRDs` is true, so removing the chart does not delete the CRDs and the Rollouts that depend on them.

**The network policies** allow the controller what it needs now: DNS, the Kubernetes API and the scrape by Prometheus. They also allow it to query Prometheus on port 9090, which the controller does to run the analysis of a gateway canary (the AnalysisTemplate is in the service chart; see [ADR-0028](../../../docs/adr/0028-progressive-delivery.md)). The controller runs the query, not the pod that is analysed, so this is the rule the analysis depends on.

Checks: `make delivery-check` (`scripts/delivery-check.sh`) lints, renders and schema-checks the charts, builds the dependency from `Chart.lock`, runs the contracts (restricted Pod Security, requests and limits, the priority class, the ServiceMonitor against the real metrics Service, the CRDs against `ServerSideApply`, the fit with the `platform-addons` AppProject) and fails if the committed render under `scripts/tests/fixtures/delivery` has drifted from the chart. `make network-policies-check` evaluates the flows of the policies.

The design is in [ADR-0028](../../../docs/adr/0028-progressive-delivery.md).
