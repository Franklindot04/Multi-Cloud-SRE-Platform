# Helm

One chart deploys all four sample services. Argo CD renders it once per service (one ApplicationSet each, in [`platform/argocd/apps`](../../platform/argocd/apps)); the reasoning is in [ADR-0016](../../docs/adr/0016-service-deployment-model.md) and operations are in the [service deployment runbook](../../docs/runbooks/service-deployment.md).

## Layout

```text
deploy/helm/
  service/            the chart: Deployment, Service, ServiceAccount, PodDisruptionBudget, migration Job
                      (PreSync hook), optional Ingress, Certificate, ServiceMonitor and BackendConfig
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

## Image tags and digests

No image reference is hard-coded. `values/images.yaml` carries the registry (GitHub Container Registry, lower-case owner) and a **placeholder** tag. The `images` workflow builds and pushes the images on merges to `main` and prints each tag and digest in its job summary; CI does not commit anything. A person updates the file with `scripts/update-image-values.sh --tag <sha> --digest <service>=sha256:...` in a pull request (see [releasing images](../../docs/runbooks/releasing-images.md)). A digest, when set, is appended to the reference. Changes to this file run the chart checks in the `deploy` workflow.

## Checks

```bash
make deploy-check
```

`helm lint --strict` and `helm template` for every service under every profile and cloud (and with the optional features on), `kubeconform` against the Kubernetes version of each cloud, security checks on the rendered output (non-root, no privilege escalation, capabilities dropped, seccomp, limits, read-only root filesystem, no host access, no mounted token, no secret values, no LoadBalancer or NodePort Service, no `:latest`), `yamllint` and `shellcheck`.
