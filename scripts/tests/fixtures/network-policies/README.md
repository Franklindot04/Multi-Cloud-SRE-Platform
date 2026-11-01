# Network policy flows

`flows.yaml` lists the connections the network policies of the `shop`, `data` and `observability` namespaces must allow and must deny. `scripts/network-policy-flows.py` evaluates every row against the policies the charts render, with the standard Kubernetes NetworkPolicy semantics, and fails when a flow comes out differently. `scripts/network-policies-check.sh` runs it (`make network-policies-check`) and `scripts/test-scripts.sh` tests the evaluator against this file.

## Format

- `vpcCidr`: a neutral example range (the documentation range). The pods get addresses inside it, as they do with the VPC CNI, so a rule that allows the VPC range also matches pods, and the evaluator sees that.
- `namespaces`: the namespaces and any labels beyond `kubernetes.io/metadata.name`.
- `enforced`: namespaces in which every pod must be isolated for ingress and egress.
- `endpoints`: addresses that are not pods (the API server, a kubelet, another address in the VPC, an address on the internet). All are examples.
- `pods`: pods that the charts do not render because an operator creates them (PostgreSQL, RabbitMQ, Prometheus, Alertmanager), pods of namespaces we do not own (CoreDNS), and the `stray` pods that stand for a workload added later with no policy of its own. Each has a `source` that says where its labels come from, so a reviewer can check them. A pod that a chart also renders is declared too, so that the unit tests need no wrapper chart, and the check compares the declared labels with the rendered ones and fails if the chart does not set them. The pods of the four services come from the service chart only.
- `names`: short names for the flows.
- `flows`: rows with `from` and `to` (a name or a list of names), `port` or `ports`, `protocol` (TCP by default), `expect` (`allow` or `deny`), a `note`, and `profiles` (the values profile of the services, `data` by default; `memory` is the profile without the data layer). A row expands to one flow for each source, destination and port.

## What it does and does not prove

It proves that the rendered policies mean what we intend, under the standard semantics. It does not prove that the VPC CNI policy agent behaves that way; see the [network policy runbook](../../../../docs/runbooks/network-policies.md) for the checks to run on a cluster.

## Changing it

When a policy changes, change the rows with it. A new allow gets an allowed row for the new path and, usually, a denied row for a nearby path that must stay closed. A new service gets rows in both directions and its pods come from the service chart.
