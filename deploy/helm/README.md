# Helm

One chart deploys all four sample services. Argo CD renders it once per service (one ApplicationSet each, in [`platform/argocd/apps`](../../platform/argocd/apps)); the reasoning is in [ADR-0016](../../docs/adr/0016-service-deployment-model.md) and operations are in the [service deployment runbook](../../docs/runbooks/service-deployment.md).

## Layout

```text
deploy/helm/
  service/            the chart: Deployment, Service, ServiceAccount, PodDisruptionBudget, migration Job
                      (PreSync hook), NetworkPolicies, optional Ingress, Certificate, ServiceMonitor and BackendConfig
  values/
    images.yaml       registry, tag and per-service digests: the one file CI updates (the tag is a placeholder)
    <service>.yaml    what is the same in every profile: port, user, resources, plain environment
    <service>-memory.yaml   STORAGE=memory, CACHE=none, MESSAGING=http (the default profile)
    <service>-data.yaml     postgres, valkey and rabbitmq; the Secrets they read; the migration Job
    cloud-aws.yaml, cloud-gcp.yaml   ingress annotations per cloud (used by the gateway)
```

The RabbitMQ credential copy lives with the data layer, in [`platform/data/rabbitmq-credentials`](../../platform/data/rabbitmq-credentials).

## Render it

```bash
helm template orders deploy/helm/service -n shop \
  -f deploy/helm/values/images.yaml -f deploy/helm/values/orders.yaml -f deploy/helm/values/orders-data.yaml
```

The release name is the service name: the chart names the Service, Deployment and ServiceAccount after it, and the services reach each other by those names (`http://orders:8081`).

## What the chart does

- Rolling update with `maxUnavailable: 0` and a surge of one, a PodDisruptionBudget for a service with more than one replica, topology spread over nodes and zones, an optional CPU autoscaler (see [Replicas, budgets and autoscaling](#replicas-budgets-and-autoscaling)), and the `platform-apps` priority class.
- Restricted security context on every container and Job: non-root numeric user, no privilege escalation, all capabilities dropped, `RuntimeDefault` seccomp, read-only root filesystem (an `emptyDir` on `/tmp` only for payments), no service account token, requests and limits.
- Probes on `/healthz` (startup, liveness) and `/readyz` (readiness); a `preStop` sleep and a grace period derived from the drain and shutdown timeouts.
- Passwords as mounted Secret files (`NAME_FILE`), other connection details from the same Secrets.
- Prometheus scrape annotations and a ServiceMonitor, both off by default.
- An optional Ingress for the gateway (off by default; **enabling it creates a billed load balancer**), with AWS Load Balancer Controller annotations (scheme, target type `ip`, health check `/healthz`) or the built-in GKE ingress with a BackendConfig, and an optional cert-manager Certificate.

## Replicas, budgets and autoscaling

A service may run more than one replica only when its state is outside the pod. Each values file says which it is:

| Service | Memory profile | Data profile | Why |
| --- | --- | --- | --- |
| gateway | 2, fixed | 2 to 4, CPU autoscaler | Keeps no state; every request is forwarded |
| orders | 1 | 2 to 4, CPU autoscaler | Orders live in PostgreSQL; the outbox relay claims its rows with `FOR UPDATE SKIP LOCKED`, an order leaves `pending` only through `UPDATE ... WHERE status = 'pending'`, and the idempotency key is a unique key. In the memory profile the orders are in the pod |
| payments | 1 | 2, fixed | PostgreSQL arbitrates the idempotency key (`ON CONFLICT DO NOTHING`). Fixed because a JVM's start-up burst would read as load against a request of 100m; an autoscaler waits for load data |
| notifier | 1 | 1 | Its duplicate detection and its notifications are in memory, per pod ([ADR-0015](../../docs/adr/0015-service-data-integration.md)) |

- **Replicas.** `replicas` is a fixed count and is `null` by default. With `autoscaling.enabled: true` the Deployment has no `replicas` field, so Argo CD has nothing to put back when the autoscaler changes the count, and no `ignoreDifferences` is needed. Setting both is refused when the chart renders. The first sync after switching an existing release over can take the Deployment down to one replica for a moment before the autoscaler raises it to its minimum.
- **Autoscaler** (`autoscaling`, `autoscaling/v2`). CPU utilisation, 70 percent of the CPU request (`targetCPUUtilizationPercentage`), between `minReplicas` 2 and `maxReplicas` 4 for the services that scale, scaling up at once and down after five minutes below target (`scaleDownStabilizationSeconds`). It needs the metrics API (metrics-server on EKS, built in on GKE). The percentage is of the request, and the requests are small, so a pod scales out at 14m (gateway) or 35m (orders) of average CPU.
- **Budget** (`podDisruptionBudget`). `maxUnavailable: 1`, rendered only when the service starts with more than one replica (`replicas`, or `autoscaling.minReplicas`). On a single replica it would block every node drain and Spot replacement.
- **Spread** (`topologySpread`). Over nodes and over zones, with `maxSkew` 1. `whenUnsatisfiable` is `ScheduleAnyway` here, which prefers the spread and keeps pods schedulable on a small or single-zone cluster; a production profile can set `DoNotSchedule`, which leaves a pod Pending rather than break the spread. `matchLabelKeys: pod-template-hash` keeps the old and the new pods of a rollout from counting against each other.
- **Rollout and shutdown.** `maxUnavailable: 0`, `maxSurge: 1`. The grace period is the `preStop` sleep (5 s) plus the drain (5 s), the shutdown timeout (20 s) and a buffer (5 s). All four services fail `/readyz` on SIGTERM, wait for the drain and finish the requests in flight.

The reasoning is in [ADR-0026](../../docs/adr/0026-resilience-and-autoscaling.md), and applying, checking and testing it are in the [resilience runbook](../../docs/runbooks/resilience.md).

`scripts/chart-contract-check.py scaling` checks every rendered service against this (see the table in `scripts/deploy-check.sh`): the replica count or the autoscaler each service and profile should have, no `replicas` next to an autoscaler, a budget exactly when there is more than one replica, the spread, the rollout and the grace period. A service with in-memory state cannot be given a second replica without the check failing. Nothing here has run on a cluster.

## Network policies

Each release renders network policies for its own pods (the Deployment and the migration Job), on by default (`networkPolicy.enabled`). They are enforced where the cluster's network plugin enforces them: the VPC CNI on EKS with `enable_network_policy` (see the [AWS EKS runbook](../../docs/runbooks/aws-eks.md#network-policy-enforcement)) and Dataplane V2 on GKE. Without enforcement they have no effect. The allow rules have sync wave -2, the default deny -1 and the Deployment 0, so a deny never lands before its allows. The policies are per service, not per namespace, because the four releases share the namespace and a namespace-wide object would be owned by four Applications. A pod in `shop` that this chart does not create is not covered.

**Status.** The first version of these policies ran on a real cluster on 2026-11-02. It could not use a Service from a pod selector, because the policy agent of the VPC CNI matches egress against the Service address. This version, which adds the Service range to every egress rule, has not been applied to a cluster yet (see [ADR-0024](../../docs/adr/0024-network-policies.md#what-has-been-exercised)).

| Service | Ingress from | Egress to |
| --- | --- | --- |
| gateway | nobody (see below) | orders 8081, payments 8082 |
| orders | gateway | payments 8082; memory profile: notifier 8083; data profile: PostgreSQL 5432, Valkey 6379, RabbitMQ 5672 |
| payments | gateway, orders | data profile: PostgreSQL 5432 |
| notifier | memory profile: orders | data profile: RabbitMQ 5672 |
| every service | Prometheus on the service port | DNS (`kube-dns`, UDP and TCP 53) and the OpenTelemetry Collector (4317) |

Every egress rule has a second peer, the Service range, on the same port, because a connection to a Service goes to its ClusterIP and the agent matches that address, not the pod behind it. The pod peer stays for connections that go straight to a pod address. The destination's ingress rule, matched against the pod, still says who may connect. The range is `networkPolicy.serviceCidr`: Argo CD passes it to each service from the cluster annotation `platform.example/service-cidr` (written by `scripts/bootstrap-argocd.sh` from the Terraform output `service_cidr_block`; `172.20.0.0/16` is the EKS default, as an example), it is not committed, and the chart refuses to render without it. `networkPolicy.matchServiceAddresses: false` leaves these peers out and needs no range, for a network plugin that matches after the address is translated (GKE Dataplane V2 is expected to be one; that has not been tried).

The gateway calls the payments service too (`GET /payments/{id}` and its readiness check), so it has both destinations. The notifier makes no outgoing connection other than RabbitMQ and the Collector. **Nothing outside the cluster is allowed in.** `kubectl port-forward` does not use the pod network (the stream goes through the API server and the kubelet into the pod's own network namespace), and the kubelet's probes are not blocked by policy, so neither needs a rule. When the ingress is enabled the load balancer sends traffic straight to the pod IPs from the VPC, so `networkPolicy.ingressCidrs` must list its source range (the chart refuses to render without it), for example with a Helm parameter in the gateway's ApplicationSet or in your own values file (nothing is committed for it, and it is off until the ingress is). The services never call the Kubernetes API (no token is mounted), so they need no rule for it.

The design is in [ADR-0024](../../docs/adr/0024-network-policies.md); applying, checking and rolling back are in the [network policy runbook](../../docs/runbooks/network-policies.md). The callers and destinations are values: `networkPolicy.ingressFrom`, `egressTo` and `egressToData` in `values/<service>.yaml` and the profile file. The labels and ports of the targets (`networkPolicy.dataTargets` and the rest) are checked against the real charts by `scripts/network-policies-check.sh`, which also evaluates the allowed and denied flows against the rendered policies. Set `networkPolicy.enabled: false` to render none.

## Image tags and digests

No image reference is hard-coded. `values/images.yaml` carries the registry (GitHub Container Registry, lower-case owner) and a **placeholder** tag. The `images` workflow builds and pushes the images on merges to `main` and prints each tag and digest in its job summary; CI does not commit anything. A person updates the file with `scripts/update-image-values.sh --tag <sha> --digest <service>=sha256:...` in a pull request (see [releasing images](../../docs/runbooks/releasing-images.md)). A digest, when set, is appended to the reference. Changes to this file run the chart checks in the `deploy` workflow.

## Checks

```bash
make deploy-check
```

`helm lint --strict` and `helm template` for every service under every profile and cloud (and with the optional features on), `kubeconform` against the Kubernetes version of each cloud, security checks on the rendered output (non-root, no privilege escalation, capabilities dropped, seccomp, limits, read-only root filesystem, no host access, no mounted token, no secret values, no LoadBalancer or NodePort Service, no `:latest`), `yamllint` and `shellcheck`.
