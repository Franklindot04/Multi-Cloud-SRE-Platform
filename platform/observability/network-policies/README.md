# network-policies

Default-deny network policies for the `observability` namespace, with the allow rules the stack needs. They are enforced by the VPC CNI on EKS ([`enable_network_policy`](../../../infra/terraform/modules/aws-eks/README.md)); the chart is deployed to EKS clusters only.

**Status.** The first version of these policies ran on a real cluster on 2026-11-02; it could not reach the API server and could not use a Service from a pod selector, because the policy agent matches egress against the Service address. This version, which allows the Service range, has not been applied to a cluster yet. See [ADR-0024](../../../docs/adr/0024-network-policies.md#what-has-been-exercised).

**Order.** Every allow rule has sync wave -2 and the default deny wave -1, so a deny never lands without them. The Application is wave 17, after the stack and its pipelines.

**The Service range.** The VPC CNI policy agent matches an egress rule against the address the pod connects to. For a Service that is its ClusterIP, before it becomes a pod address, so a rule that names the pods behind a Service does not let the connection through. Prometheus, the Prometheus Operator, kube-state-metrics, the Grafana sidecars, Alloy and the Grafana secret Job call the Kubernetes API (the Service `kubernetes`) and get TCP 443 to the Service range, each on its own. The cluster DNS is a Service too. In the `flows` in `values.yaml`, the connections that go through a Service (Grafana to its data sources, Alloy to Loki, the Collector to Tempo, and the operator, which is allowed both ways) are marked `service: true` and also get the Service range on their ports. Prometheus follows the endpoints of a Service and connects to the pods, so its scrape rules are by pod. Who may connect is decided by the ingress policy of the destination, which is matched against the pod. The range is the value `serviceCidr`, which Argo CD passes from the cluster annotation `platform.example/service-cidr` (written by `scripts/bootstrap-argocd.sh` from the Terraform output `service_cidr_block`; `172.20.0.0/16` is the EKS default, as an example).

**The VPC range.** Prometheus also reaches two things by address and not through a Service: the kubelets (TCP 10250 on the nodes, for the kubelet and cAdvisor metrics) and the network interfaces of the API server (TCP 443, the targets of the apiserver scrape, which follows the endpoints of the Service `kubernetes`). Both are addresses in the VPC, so those two rules use the value `vpcCidr`, from the annotation `platform.example/vpc-cidr` (Terraform output `vpc_cidr_block`). Neither range is committed, and the chart refuses to render without them.

| Policy | From | To | Port |
| --- | --- | --- | --- |
| `default-deny` | | every pod, ingress and egress | none |
| `allow-dns` | every pod | `kube-dns` in `kube-system`, and the Service range | UDP and TCP 53 |
| `allow-kube-api-*` | the pods listed in `apiAccess` | the Service range (the API) | TCP 443 |
| `prometheus-allow-to-<pod>` (and `<pod>-allow-from-prometheus`) | Prometheus | Grafana 3000, kube-state-metrics 8080, Alertmanager 9093 and 8080 (also where alerts are sent), the operator 8080, Loki 3100, Alloy 12345, Tempo 3200, the Collector 8888 and 8889 | TCP |
| `operator-allow-to-prometheus`, `-alertmanager` | Prometheus Operator | Prometheus 9090 and 8080, Alertmanager 9093 and 8080 | TCP |
| `grafana-allow-to-<source>` | Grafana | Prometheus 9090, Loki 3100, Tempo 3200, Alertmanager 9093 (pods, and the Service range) | TCP |
| `alloy-allow-to-loki` | Alloy | Loki (pods, and the Service range) | TCP 3100 |
| `collector-allow-to-tempo` | the Collector | Tempo (pods, and the Service range) | TCP 4317 |
| `collector-allow-from-services` | the four services in `shop` | the Collector | TCP 4317 |
| `prometheus-allow-to-services` | Prometheus | the services in `shop` | TCP 8080-8083 |
| `prometheus-allow-to-data` | Prometheus | PostgreSQL instances, RabbitMQ in `data` | TCP 9187, 15692 |
| `prometheus-allow-to-coredns` | Prometheus | `kube-dns` in `kube-system` | TCP 9153 |
| `prometheus-allow-to-kubelets` | Prometheus | the VPC range | TCP 10250 |
| `prometheus-allow-to-apiserver-endpoints` | Prometheus | the VPC range (the API server's interfaces) | TCP 443 |

The in-namespace paths are the `flows` in [`values.yaml`](values.yaml); each renders an egress policy on the source and an ingress policy on the destination.

**Webhooks.** None runs in this namespace: the stack has `prometheusOperator.admissionWebhooks` off. If it is switched on, the API server calls the webhook from VPC addresses, so its port needs an ingress rule from the VPC range.

**What is not blocked.** The kubelet's probes and `kubectl port-forward` (the way to open Grafana, Prometheus and Alertmanager) do not use the pod network and need no rule.

**Alertmanager sends nothing.** Its receivers are empty, so it has no egress rule. A real receiver (a chat webhook, for example) needs an egress rule to that destination, added with the receiver.

**Switching off.** `enabled: false` in `values.yaml` renders nothing and Argo CD prunes the policies; it is the way back when a policy blocks something that must work ([network policy runbook](../../../docs/runbooks/network-policies.md#roll-back)).

Checks: `scripts/observability-check.sh` (lint, render, schema, the policy contract and fit with the AppProject) and `scripts/network-policies-check.sh` (that every label and namespace used is real, and the allowed and denied flows of [the matrix](../../../scripts/tests/fixtures/network-policies/flows.yaml)). Design: [ADR-0024](../../../docs/adr/0024-network-policies.md); operation: [network policy runbook](../../../docs/runbooks/network-policies.md).
