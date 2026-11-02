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

- Rolling update with `maxUnavailable: 0`, a PodDisruptionBudget, topology spread over nodes and zones, and the `platform-apps` priority class.
- Restricted security context on every container and Job: non-root numeric user, no privilege escalation, all capabilities dropped, `RuntimeDefault` seccomp, read-only root filesystem (an `emptyDir` on `/tmp` only for payments), no service account token, requests and limits.
- Probes on `/healthz` (startup, liveness) and `/readyz` (readiness); a `preStop` sleep and a grace period derived from the drain and shutdown timeouts.
- Passwords as mounted Secret files (`NAME_FILE`), other connection details from the same Secrets.
- Prometheus scrape annotations and a ServiceMonitor, both off by default.
- An optional Ingress for the gateway (off by default; **enabling it creates a billed load balancer**), with AWS Load Balancer Controller annotations (scheme, target type `ip`, health check `/healthz`) or the built-in GKE ingress with a BackendConfig, and an optional cert-manager Certificate.

## Network policies

Each release renders network policies for its own pods (the Deployment and the migration Job), on by default (`networkPolicy.enabled`). They are enforced where the cluster's network plugin enforces them: the VPC CNI on EKS with `enable_network_policy` (see the [AWS EKS runbook](../../docs/runbooks/aws-eks.md#network-policy-enforcement)) and Dataplane V2 on GKE. Without enforcement they have no effect. The allow rules have sync wave -2, the default deny -1 and the Deployment 0, so a deny never lands before its allows. The policies are per service, not per namespace, because the four releases share the namespace and a namespace-wide object would be owned by four Applications. A pod in `shop` that this chart does not create is not covered.

| Service | Ingress from | Egress to |
| --- | --- | --- |
| gateway | nobody (see below) | orders 8081, payments 8082 |
| orders | gateway | payments 8082; memory profile: notifier 8083; data profile: PostgreSQL 5432, Valkey 6379, RabbitMQ 5672 |
| payments | gateway, orders | data profile: PostgreSQL 5432 |
| notifier | memory profile: orders | data profile: RabbitMQ 5672 |
| every service | Prometheus on the service port | DNS (`kube-dns`, UDP and TCP 53) and the OpenTelemetry Collector (4317) |

The gateway calls the payments service too (`GET /payments/{id}` and its readiness check), so it has both destinations. The notifier makes no outgoing connection other than RabbitMQ and the Collector. **Nothing outside the cluster is allowed in.** `kubectl port-forward` does not use the pod network (the stream goes through the API server and the kubelet into the pod's own network namespace), and the kubelet's probes are not blocked by policy, so neither needs a rule. When the ingress is enabled the load balancer sends traffic straight to the pod IPs from the VPC, so `networkPolicy.ingressCidrs` must list its source range (the chart refuses to render without it), for example with a Helm parameter in the gateway's ApplicationSet or in your own values file (nothing is committed for it, and it is off until the ingress is). The services never call the Kubernetes API (no token is mounted), so they need no rule for it.

The design is in [ADR-0024](../../docs/adr/0024-network-policies.md); applying, checking and rolling back are in the [network policy runbook](../../docs/runbooks/network-policies.md). The callers and destinations are values: `networkPolicy.ingressFrom`, `egressTo` and `egressToData` in `values/<service>.yaml` and the profile file. The labels and ports of the targets (`networkPolicy.dataTargets` and the rest) are checked against the real charts by `scripts/network-policies-check.sh`, which also evaluates the allowed and denied flows against the rendered policies. Set `networkPolicy.enabled: false` to render none.

## Image tags and digests

No image reference is hard-coded. `values/images.yaml` carries the registry (GitHub Container Registry, lower-case owner) and a **placeholder** tag. The `images` workflow builds and pushes the images on merges to `main` and prints each tag and digest in its job summary; CI does not commit anything. A person updates the file with `scripts/update-image-values.sh --tag <sha> --digest <service>=sha256:...` in a pull request (see [releasing images](../../docs/runbooks/releasing-images.md)). A digest, when set, is appended to the reference. Changes to this file run the chart checks in the `deploy` workflow.

## Checks

```bash
make deploy-check
```

`helm lint --strict` and `helm template` for every service under every profile and cloud (and with the optional features on), `kubeconform` against the Kubernetes version of each cloud, security checks on the rendered output (non-root, no privilege escalation, capabilities dropped, seccomp, limits, read-only root filesystem, no host access, no mounted token, no secret values, no LoadBalancer or NodePort Service, no `:latest`), `yamllint` and `shellcheck`.
