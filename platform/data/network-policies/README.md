# network-policies

Default-deny network policies for the `data` namespace (PostgreSQL, Valkey, RabbitMQ), with the allow rules each component needs. They are enforced by the VPC CNI on EKS ([`enable_network_policy`](../../../infra/terraform/modules/aws-eks/README.md)); the chart is deployed to EKS clusters only. The policies of the `shop` namespace are in the service chart ([`deploy/helm`](../../../deploy/helm/README.md#network-policies)).

**Order.** Every allow rule has sync wave -2 and the default deny wave -1, so a deny never lands without them. The Application is wave 9, after the data layer.

**The VPC range.** Pods that call the Kubernetes API (the PostgreSQL instance manager, the RabbitMQ peer discovery, and the Jobs of the secrets and PostgreSQL charts) get TCP 443 to the VPC address range. The API server of EKS is a set of network interfaces in the VPC subnets, so a pod selector cannot name it; this is the narrowest rule that works, given only to those pods. The range is the value `vpcCidr`, which Argo CD passes from the cluster annotation `platform.example/vpc-cidr` (written by `scripts/bootstrap-argocd.sh` from the Terraform output `vpc_cidr_block`). It is not committed, and the chart refuses to render without it. If the VPC has more than one address range, list the one the cluster's subnets are in.

| Policy | From | To | Port |
| --- | --- | --- | --- |
| `default-deny` | | every pod in `data`, ingress and egress | none |
| `allow-dns` | every pod | `kube-dns` in `kube-system` | UDP and TCP 53 |
| `allow-kube-api-postgres`, `-rabbitmq`, `-jobs` | those pods | the VPC range | TCP 443 |
| `postgres-allow-from-services` | `orders`, `payments` in `shop` | PostgreSQL instances | TCP 5432 |
| `postgres-allow-from-operator` | CloudNativePG operator (`cnpg-system`) | PostgreSQL instances | TCP 8000, 5432 |
| `postgres-allow-between-instances` | PostgreSQL instances | PostgreSQL instances | TCP 5432, 8000 |
| `postgres-allow-prometheus-scrape` | Prometheus (`observability`) | PostgreSQL instances | TCP 9187 |
| `valkey-allow-from-services` | `orders` | Valkey | TCP 6379 |
| `valkey-allow-between-pods` | Valkey | Valkey | TCP 6379 |
| `rabbitmq-allow-from-services` | `orders`, `notifier` | RabbitMQ | TCP 5672 |
| `rabbitmq-allow-from-operator` | RabbitMQ Cluster Operator (`rabbitmq-system`) | RabbitMQ | TCP 15672, 5672 |
| `rabbitmq-allow-clustering` | RabbitMQ | RabbitMQ | TCP 4369, 25672, 35672-35682 |
| `rabbitmq-allow-prometheus-scrape` | Prometheus | RabbitMQ | TCP 15692 |

**Webhooks.** The CloudNativePG operator (webhook port 9443) and the RabbitMQ Cluster Operator (9443) run in `cnpg-system` and `rabbitmq-system`, which these policies do not cover, so the API server reaches them as before. If those namespaces get a default deny later, each needs an ingress rule on 9443 from the VPC range, because the API server calls webhooks from VPC addresses.

**What is not blocked.** The kubelet's probes and `kubectl port-forward` do not use the pod network and need no rule.

**Not covered.** Egress to the internet (for example backups to object storage, which do not exist yet) is denied; add a rule with the backup change. The operators' own namespaces are not covered.

**Switching off.** `enabled: false` in `values.yaml` renders nothing and Argo CD prunes the policies; it is the way back when a policy blocks something that must work ([network policy runbook](../../../docs/runbooks/network-policies.md#roll-back)).

Checks: `scripts/data-manifests-check.sh` (lint, render, schema) and `scripts/network-policies-check.sh` (the policy contract, that every label and namespace used is real, and the allowed and denied flows of [the matrix](../../../scripts/tests/fixtures/network-policies/flows.yaml)). Design: [ADR-0024](../../../docs/adr/0024-network-policies.md); operation: [network policy runbook](../../../docs/runbooks/network-policies.md).
