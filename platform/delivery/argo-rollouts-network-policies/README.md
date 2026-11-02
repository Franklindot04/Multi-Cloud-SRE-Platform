# argo-rollouts-network-policies

The network policies of the `argo-rollouts` namespace, for the controller in [`argo-rollouts`](../argo-rollouts). Argo CD deploys them, after the controller, to EKS clusters labelled `platform.example/progressive-delivery=true`, with the Service range passed from the cluster annotation `platform.example/service-cidr`. The chart refuses to render without it.

They follow the findings of [ADR-0024](../../../docs/adr/0024-network-policies.md) for the VPC CNI: an egress rule is matched against the address the pod connects to, so a flow through a Service (the API server, DNS, Prometheus) is allowed to the Service range (`ipBlock`) next to the pod selector; ingress is matched on pod addresses. The controller has no webhook, so nothing calls it from the API server or the kubelet and no rule takes the VPC range.

| Policy | What it allows |
| --- | --- |
| `default-deny` | nothing, in both directions, for every pod of the namespace |
| `allow-dns` | UDP and TCP 53 to the cluster DNS (pods and the Service range) |
| `allow-kube-api-controller` | TCP 443 to the Service range (the Service `kubernetes`), for the controller only |
| `controller-allow-prometheus-scrape` | ingress on the metrics port 8090 from the Prometheus pods |
| `controller-allow-prometheus-query` | egress to Prometheus on 9090, pods and the Service range, for the analysis of the gateway canary, which the controller runs (the address is the Service `kube-prometheus-stack-prometheus` in `observability`) |

The other half of the Prometheus flows is in [`observability/network-policies`](../../observability/network-policies) (`prometheus-allow-to-argo-rollouts` and `prometheus-allow-from-argo-rollouts`). The flows are in the matrix `scripts/tests/fixtures/network-policies/flows.yaml`, allowed and denied, and `scripts/network-policies-check.sh` evaluates them for both profiles. The policies can be switched off with `enabled: false`; see the [network policies runbook](../../../docs/runbooks/network-policies.md).
