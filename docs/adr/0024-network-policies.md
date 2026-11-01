# ADR-0024: Network policies

- Status: Accepted
- Date: 2026-11-01

## Context

Until now every pod could talk to every other pod. The earlier ADRs listed that as a gap ([ADR-0014](0014-data-layer.md), [ADR-0016](0016-service-deployment-model.md), [ADR-0020](0020-metrics-stack.md), [ADR-0021](0021-logging-stack.md), [ADR-0022](0022-tracing-stack.md)): the gateway could reach PostgreSQL, any pod could reach Loki, and a compromised service could scan the cluster. The paths that the platform really uses are few and known, so they can be written down and everything else closed.

Two facts shape the design. The EKS VPC CNI enforces Kubernetes NetworkPolicy only when its add-on is configured to, and an object is otherwise accepted and ignored. And the Kubernetes API server of EKS is not a pod: it is a set of network interfaces owned by the cluster, placed in the VPC subnets, so a policy cannot select it by label.

## Decision

Default deny for ingress and egress in the `shop`, `data` and `observability` namespaces, and an explicit allow for every path that is used.

Enforcement

- The `vpc-cni` add-on gets `enableNetworkPolicy: "true"` in its configuration values, from the module variable `enable_network_policy` (default true). That starts the network policy agent in the `aws-node` pods. It needs add-on 1.14.0-eksbuild.3 or later, Kubernetes 1.25 or later and nodes with kernel 5.10 or later; the module already uses the newest compatible add-on, and the Amazon Linux 2023 nodes qualify.
- The default enforcement mode is kept (`standard`). In it a new pod starts with all traffic allowed until the agent has programmed its policies, a short window. Strict mode would close that window, but it needs a policy for every endpoint a pod reaches including CoreDNS, in a namespace this change does not cover (kube-system), so it is not used. A pod that must never have that window needs strict mode, and that is a later decision.
- GKE enforces policies with Dataplane V2 ([ADR-0009](0009-gke-cluster-design.md)). The service chart's policies apply there too; the policy charts for `data` and `observability` are for EKS only, because they open the API server by the VPC range.

Where the policies live

- **The shop namespace: in the service chart** ([`deploy/helm/service`](../../deploy/helm/README.md#network-policies)), on by default (`networkPolicy.enabled`). Each release denies its own pods (the Deployment and the migration Job) and allows what that service does, listed in the values of the service and of its profile. The policies are per release, not one namespace-wide object, because four releases share the namespace and a namespace-wide object would be owned by four Applications. The price: a pod in `shop` that this chart does not create is not covered. Only the platform-apps project deploys there, so nothing else should be.
- **The data and observability namespaces: in two small platform charts** ([`platform/data/network-policies`](../../platform/data/network-policies) and [`platform/observability/network-policies`](../../platform/observability/network-policies)), each deployed by its own ApplicationSet (waves 9 and 17, after the workloads) with a namespace-wide deny, because one Application owns each namespace's policies. They hold the allows of the namespace and also the rules for traffic that crosses namespaces, written once on each side: the egress in the source's namespace and the ingress in the destination's.
- **Order.** Inside every Application the allow rules have sync wave -2, the deny -1 and the workloads 0. The three places are separate Applications, but every path is declared by both of its ends and a side is closed only by its own deny, which arrives after its own allows. A side whose policies have not been applied yet is still open, so a path is never cut because the other end is late.

The rules

- **DNS** is allowed to the `kube-dns` pods in `kube-system` on UDP and TCP 53 for every pod. Everything else a pod needs is a named allow, small and commented. The tables of what is allowed are in the READMEs of the three places, and the same list, as flows, is [the matrix](../../scripts/tests/fixtures/network-policies/flows.yaml) the checker uses.
- **The services** reach what they use and nothing else. The gateway calls orders and payments; orders calls payments (and, in the memory profile, the notifier), PostgreSQL, Valkey and RabbitMQ; payments calls PostgreSQL; the notifier calls RabbitMQ. Every service calls the Collector on 4317 and accepts Prometheus on its port. Nothing outside the cluster is allowed in: `kubectl port-forward` does not use the pod network and the kubelet's probes are not subject to policy, so neither needs a rule. If the ingress is enabled, the load balancer sends traffic straight to the pod IPs from the VPC, so the chart then needs `networkPolicy.ingressCidrs` and refuses to render without it.
- **The data layer** accepts SQL from orders and payments, the cache from orders and the broker from orders and the notifier, and the operators' own paths (CloudNativePG asks each instance for its status on 8000; the RabbitMQ operator uses the management port), the replication and clustering between instances, and Prometheus on the metrics ports.
- **Observability** keeps the paths Prometheus, the operator, Grafana, Alloy and the Collector use, listed as flows in the chart's values so that each renders an egress policy on the source and an ingress policy on the destination.
- **Alertmanager has no egress.** Its receivers are empty. A real receiver needs an egress rule, added with it.

The Kubernetes API server

- The pods that call the API get TCP 443 to the VPC address range, each on its own, not the namespace: in `data` the PostgreSQL instances, the RabbitMQ pods and the Jobs of the secrets and PostgreSQL charts; in `observability` Prometheus, the operator, kube-state-metrics, Grafana (its sidecars), Alloy and the Job that makes Grafana's password. The services never call the API (no token is mounted) and have no rule. Prometheus also gets TCP 10250 to the same range, for the kubelets.
- A rule on the VPC range is the narrowest that works, and it is wider than it looks: with the VPC CNI the pods have addresses inside the VPC, so the rule also reaches other pods on 443 (and Prometheus's rule other pods on 10250). The checker models this, because it gives its pods addresses in the range.
- **The range is a value, `vpcCidr`.** Argo CD passes it from the cluster annotation `platform.example/vpc-cidr`, which `scripts/bootstrap-argocd.sh` writes from the Terraform output `vpc_cidr_block` (as for the VPC ID and the other identifiers, it is not in Git). The charts refuse to render without it, so a deny cannot land without the API rule. The CI fixtures use a documentation range.

Webhooks

- The API server calls admission webhooks from VPC addresses, so a namespace with a default deny needs an ingress rule on a webhook's port from the VPC range, or creating that webhook's resources hangs. The webhooks of the platform: CloudNativePG (9443, `cnpg-system`), the RabbitMQ Cluster Operator (9443, `rabbitmq-system`), cert-manager and the AWS Load Balancer Controller (in their own namespaces). The Prometheus Operator's webhook is off in the stack.
- **None of them is in a namespace with a policy, so no rule is added.** A policy that selects a webhook pod would isolate it and cut its other traffic, and the pods are not ours to isolate in this change. The charts' READMEs say what each needs when its namespace gets a default deny.

Left out, and what comes next

- **argocd, kube-system, cnpg-system, rabbitmq-system, cert-manager** (and the other add-on namespaces) have no policies. They hold the controllers that the cluster depends on, their paths are many (the Argo CD server, repo server and application controller, the webhooks, the API server's calls into webhooks) and a mistake there stops all deployment. Each is its own change, in this order: the operator namespaces (the webhook rule above and the operators' API access), cert-manager, Argo CD, kube-system. Strict mode of the policy agent belongs after kube-system.
- **TLS and mutual authentication** between services are not part of this; policies decide who can connect, not who they are.
- **Egress to the internet** is closed for the services and the data layer. Backups to object storage (not configured yet) will need a rule; so will a real Alertmanager receiver.

## What the checker proves, and what it does not

[`scripts/network-policy-flows.py`](../../scripts/network-policy-flows.py) implements the standard NetworkPolicy semantics (isolation by any selecting policy, the union of rules, the AND of the source's egress and the destination's ingress, label selectors, namespace selectors alone and combined with pod selectors, address ranges with exceptions, ports with protocols and ranges, empty and missing lists) and evaluates a matrix of flows against the policies the charts render. The pods come from the rendered workloads; the ones that operators create are declared in the matrix with where their labels come from, and a declared pod that a chart also renders must carry the declared labels. `scripts/network-policies-check.sh` runs it for the data and the memory profile, and `scripts/test-scripts.sh` tests it with small hand-made policies and with mutations of the real ones: removing an allow, adding a broad one, removing a deny and changing a port each make a flow fail.

- **It proves** that the policies mean what we intend under the standard semantics: every path in the list is open on both sides, every path in the denied list is closed, a new pod in `data` or `observability` is held by the default deny, and a label that no pod carries is found.
- **It does not prove** that the VPC CNI policy agent behaves as the standard semantics say, nor that the matrix lists every path the software uses. The matrix comes from reading the code and the manifests; a missing path shows up on a cluster as a blocked connection. The operator ports (the RabbitMQ operator's 15672 and 5672, CloudNativePG's 8000 and 5432) and the Prometheus Operator's calls to Prometheus and Alertmanager come from how the operators are documented to work, not from a run.
- **The open question** is how the policy agent treats a connection to a Service address. The policies name pods, and a connection to a Service is rewritten to a pod address by kube-proxy; the agent must compare the pod address. This is the usual setup and AWS's own examples depend on it, but it was not observed here. DNS is the first thing to check after an apply because every other path starts with it ([the runbook](../runbooks/network-policies.md)).
- **The per-service deny is formally redundant.** In the service chart every pod is already isolated by its other policies (DNS egress, the Prometheus ingress), and isolation by any policy is what closes the rest, so `<service>-default-deny` changes no flow. It stays because it states the intent and keeps the pod isolated if the other policies are removed. In `data` and `observability` the namespace-wide deny is what holds a pod that has no policy of its own, and the checker has a test for that.

## Consequences

- The services, the data layer and the stack can reach only the listed paths. A new connection has to be added as a policy and as a row of the matrix, in the same change.
- On an existing cluster the order is: apply Terraform (the add-on), run the bootstrap script again (the annotation), then let Argo CD sync the policy Applications. Until the annotation exists the two platform Applications fail to sync, on purpose.
- The policies are only as good as the labels they select. `scripts/network-policies-check.sh` fails if a label or namespace in a policy is carried by no pod or Service or monitor selector in the rendered charts.
- The window of an open pod before its policies load (standard mode) is accepted.
- Every new `NetworkPolicy` in the shop and observability namespaces needs the kind in the AppProject; both have it.

## What has been exercised

- The checks have run: chart lint and schema validation of every policy, the policy contract (a deny for every pod, allows before denies, no open range, every label real), the flow evaluator on the data and memory profiles, its unit and mutation tests, and the Argo CD checks including the sync-wave table and the AppProject fit. The Terraform module has run `fmt`, `validate` and its plan-only tests.
- **Nothing has run on a cluster.** The add-on setting has not been applied, the policy agent has not enforced any of these policies, and the open questions above are open.

## Alternatives considered

- **One namespace-wide deny in the shop namespace**, owned by one of the Applications: if that Application is removed, the deny goes with it; a separate Application for it would need an order against the four services. Per-release policies avoid both.
- **A deny with allow rules in a single Application per namespace set** (a cluster policy chart): one place to read, but it couples the services' release to the platform and makes a service's paths live far from its values.
- **Calico or Cilium instead of the VPC CNI policy agent:** more features (cluster-wide policies, DNS names in rules), a second networking component to run. The VPC CNI agent is enough for the rules here.
- **Allowing the API server by a Service address or a pod selector:** not possible on EKS, as above. A rule on the cluster's API endpoint addresses would be narrower but they change, and the Terraform output of the network interfaces is not available to Argo CD.
- **Strict mode now:** closes the startup window, but needs a policy for CoreDNS and the other kube-system pods first.
