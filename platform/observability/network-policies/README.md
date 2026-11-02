# network-policies

Default-deny network policies for the `observability` namespace, with the allow rules the stack needs. They are enforced by the VPC CNI on EKS ([`enable_network_policy`](../../../infra/terraform/modules/aws-eks/README.md)); the chart is deployed to EKS clusters only.

**Order.** Every allow rule has sync wave -2 and the default deny wave -1, so a deny never lands without them. The Application is wave 17, after the stack and its pipelines.

**The VPC range.** Prometheus, the Prometheus Operator, kube-state-metrics, the Grafana sidecars, Alloy and the Grafana secret Job call the Kubernetes API and get TCP 443 to the VPC address range, each on its own. The API server of EKS is a set of network interfaces in the VPC subnets, so a pod selector cannot name it; this is the narrowest rule that works. Prometheus also gets TCP 10250 to the same range for the kubelet and cAdvisor metrics on the nodes. The range is the value `vpcCidr`, which Argo CD passes from the cluster annotation `platform.example/vpc-cidr` (written by `scripts/bootstrap-argocd.sh` from the Terraform output `vpc_cidr_block`). It is not committed, and the chart refuses to render without it.

| Policy | From | To | Port |
| --- | --- | --- | --- |
| `default-deny` | | every pod, ingress and egress | none |
| `allow-dns` | every pod | `kube-dns` in `kube-system` | UDP and TCP 53 |
| `allow-kube-api-*` | the pods listed in `apiAccess` | the VPC range | TCP 443 |
| `prometheus-allow-to-<pod>` (and `<pod>-allow-from-prometheus`) | Prometheus | Grafana 3000, kube-state-metrics 8080, Alertmanager 9093 and 8080 (also where alerts are sent), the operator 8080, Loki 3100, Alloy 12345, Tempo 3200, the Collector 8888 and 8889 | TCP |
| `operator-allow-to-prometheus`, `-alertmanager` | Prometheus Operator | Prometheus 9090 and 8080, Alertmanager 9093 and 8080 | TCP |
| `grafana-allow-to-<source>` | Grafana | Prometheus 9090, Loki 3100, Tempo 3200, Alertmanager 9093 | TCP |
| `alloy-allow-to-loki` | Alloy | Loki | TCP 3100 |
| `collector-allow-to-tempo` | the Collector | Tempo | TCP 4317 |
| `collector-allow-from-services` | the four services in `shop` | the Collector | TCP 4317 |
| `prometheus-allow-to-services` | Prometheus | the services in `shop` | TCP 8080-8083 |
| `prometheus-allow-to-data` | Prometheus | PostgreSQL instances, RabbitMQ in `data` | TCP 9187, 15692 |
| `prometheus-allow-to-coredns` | Prometheus | `kube-dns` in `kube-system` | TCP 9153 |
| `prometheus-allow-to-kubelets` | Prometheus | the VPC range | TCP 10250 |

The in-namespace paths are the `flows` in [`values.yaml`](values.yaml); each renders an egress policy on the source and an ingress policy on the destination.

**Webhooks.** None runs in this namespace: the stack has `prometheusOperator.admissionWebhooks` off. If it is switched on, the API server calls the webhook from VPC addresses, so its port needs an ingress rule from the VPC range.

**What is not blocked.** The kubelet's probes and `kubectl port-forward` (the way to open Grafana, Prometheus and Alertmanager) do not use the pod network and need no rule.

**Alertmanager sends nothing.** Its receivers are empty, so it has no egress rule. A real receiver (a chat webhook, for example) needs an egress rule to that destination, added with the receiver.

**Switching off.** `enabled: false` in `values.yaml` renders nothing and Argo CD prunes the policies; it is the way back when a policy blocks something that must work ([network policy runbook](../../../docs/runbooks/network-policies.md#roll-back)).

Checks: `scripts/observability-check.sh` (lint, render, schema, the policy contract and fit with the AppProject) and `scripts/network-policies-check.sh` (that every label and namespace used is real, and the allowed and denied flows of [the matrix](../../../scripts/tests/fixtures/network-policies/flows.yaml)). Design: [ADR-0024](../../../docs/adr/0024-network-policies.md); operation: [network policy runbook](../../../docs/runbooks/network-policies.md).
