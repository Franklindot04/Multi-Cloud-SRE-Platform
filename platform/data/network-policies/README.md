# network-policies

Default-deny network policies for the `data` namespace (PostgreSQL, Valkey, RabbitMQ), with the allow rules each component needs. They are enforced by the VPC CNI on EKS ([`enable_network_policy`](../../../infra/terraform/modules/aws-eks/README.md)); the chart is deployed to EKS clusters only. The policies of the `shop` namespace are in the service chart ([`deploy/helm`](../../../deploy/helm/README.md#network-policies)).

**Status.** The first version of these policies ran on a real cluster on 2026-11-02; it could not reach the API server and could not use a Service from a pod selector, because the policy agent matches egress against the Service address. This version, which allows the Service range, has not been applied to a cluster yet. See [ADR-0024](../../../docs/adr/0024-network-policies.md#what-has-been-exercised).

**Order.** Every allow rule has sync wave -2 and the default deny wave -1, so a deny never lands without them. The Application is wave 9, after the data layer.

**The Service range.** The VPC CNI policy agent matches an egress rule against the address the pod connects to. For a Service that is its ClusterIP, before it becomes a pod address, so a rule that names the pods behind a Service does not let the connection through. The Kubernetes API (the Service `kubernetes`) and the cluster DNS are Services, so the pods that call the API get TCP 443 to the Service range, each on its own and not the namespace: the PostgreSQL instance manager, the RabbitMQ peer discovery, and the Jobs of the secrets and PostgreSQL charts. DNS gets the Service range next to the DNS pods, and a PostgreSQL or Valkey replica may reach its primary through the Service on 5432 or 6379. Who may connect is decided by the ingress policy of the destination, which is matched against the pod. The range is the value `serviceCidr`, which Argo CD passes from the cluster annotation `platform.example/service-cidr` (written by `scripts/bootstrap-argocd.sh` from the Terraform output `service_cidr_block`; `172.20.0.0/16` is the EKS default, as an example). It is not committed, and the chart refuses to render without it. This chart no longer uses the VPC range.

| Policy | From | To | Port |
| --- | --- | --- | --- |
| `default-deny` | | every pod in `data`, ingress and egress | none |
| `allow-dns` | every pod | `kube-dns` in `kube-system`, and the Service range | UDP and TCP 53 |
| `allow-kube-api-postgres`, `-rabbitmq`, `-jobs` | those pods | the Service range (the API) | TCP 443 |
| `postgres-allow-from-services` | `orders`, `payments` in `shop` | PostgreSQL instances | TCP 5432 |
| `postgres-allow-from-operator` | CloudNativePG operator (`cnpg-system`) | PostgreSQL instances | TCP 8000, 5432 |
| `postgres-allow-between-instances` | PostgreSQL instances | PostgreSQL instances, and the Service range on 5432 | TCP 5432, 8000 |
| `postgres-allow-prometheus-scrape` | Prometheus (`observability`) | PostgreSQL instances | TCP 9187 |
| `valkey-allow-from-services` | `orders` | Valkey | TCP 6379 |
| `valkey-allow-between-pods` | Valkey | Valkey, and the Service range | TCP 6379 |
| `rabbitmq-allow-from-services` | `orders`, `notifier` | RabbitMQ | TCP 5672 |
| `rabbitmq-allow-from-operator` | RabbitMQ Cluster Operator (`rabbitmq-system`) | RabbitMQ | TCP 15672, 5672 |
| `rabbitmq-allow-clustering` | RabbitMQ | RabbitMQ | TCP 4369, 25672, 35672-35682 |
| `rabbitmq-allow-prometheus-scrape` | Prometheus | RabbitMQ | TCP 15692 |

**Webhooks.** The CloudNativePG operator (webhook port 9443) and the RabbitMQ Cluster Operator (9443) run in `cnpg-system` and `rabbitmq-system`, which these policies do not cover, so the API server reaches them as before. If those namespaces get a default deny later, each needs an ingress rule on 9443 from the VPC range, because the API server calls webhooks from VPC addresses.

**What is not blocked.** The kubelet's probes and `kubectl port-forward` do not use the pod network and need no rule.

**Not covered.** Egress to the internet (for example backups to object storage, which do not exist yet) is denied; add a rule with the backup change. The operators' own namespaces are not covered.

**Switching off.** `enabled: false` in `values.yaml` renders nothing and Argo CD prunes the policies; it is the way back when a policy blocks something that must work ([network policy runbook](../../../docs/runbooks/network-policies.md#roll-back)).

Checks: `scripts/data-manifests-check.sh` (lint, render, schema) and `scripts/network-policies-check.sh` (the policy contract, that every label and namespace used is real, and the allowed and denied flows of [the matrix](../../../scripts/tests/fixtures/network-policies/flows.yaml)). Design: [ADR-0024](../../../docs/adr/0024-network-policies.md); operation: [network policy runbook](../../../docs/runbooks/network-policies.md).
