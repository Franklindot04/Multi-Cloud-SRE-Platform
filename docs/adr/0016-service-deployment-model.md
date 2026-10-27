# ADR-0016: Service deployment model

- Status: Accepted
- Date: 2026-10-27

## Context

The four sample services have images, a data layer ([ADR-0014](0014-data-layer.md)) and optional integration with it ([ADR-0015](0015-service-data-integration.md)). This change defines how they are deployed to the clusters: Helm charts, Argo CD wiring, migrations, credentials and exposure. It builds on the GitOps structure ([ADR-0012](0012-argocd-hub-and-gitops-structure.md)) and the application design ([ADR-0013](0013-sample-application-design.md)). No image is published yet and nothing is deployed by this change.

## Decision

One shared chart, not one chart per service

- A single chart, `deploy/helm/service`, deploys any of the four services. What differs between them is data: port, image user, replicas, resources, environment, the Secrets they read. Those live in one values file per service (`deploy/helm/values/<service>.yaml`) plus a profile file (`<service>-memory.yaml` or `<service>-data.yaml`) and, for the gateway only, a cloud overlay (`cloud-aws.yaml`, `cloud-gcp.yaml`).
- Four near-identical charts would drift: a security context fix would have to be made four times and reviewed four times. The services are deliberately uniform (ADR-0013: the same probes, the same shutdown behaviour, the same configuration style), which is what makes a shared chart honest. If a service ever needs something structurally different, it can get its own chart then; the shared chart does not grow conditionals for hypothetical cases.
- The cost is that a change to the chart touches all four services at once. The render checks run every service under every profile for that reason.
- Each service is its own Argo CD Application (one ApplicationSet per service), so rollouts, sync status and rollbacks are per service.

Profiles: memory by default, data when the data layer exists

- `memory` sets `STORAGE=memory`, `CACHE=none`, `MESSAGING=http` and one replica for the stateful services, so the services can be deployed and tested with no infrastructure. `data` sets `postgres`, `valkey` and `rabbitmq`, two replicas for orders and payments, and consumes the Secrets of [ADR-0014](0014-data-layer.md) by name (`orders-db`, `payments-db`, `cache-auth` and the new `rabbitmq-auth`). A cluster picks one with the label `platform.example/apps-profile` (default `memory`).
- Passwords are mounted as files (`DB_PASSWORD_FILE`, `CACHE_PASSWORD_FILE`, `AMQP_PASSWORD_FILE`) rather than passed as environment variables, which keeps them out of the process environment, `kubectl describe` output and crash dumps. Non-secret parts (host, port, user) come from the same Secrets through `secretKeyRef`, so the Secret contract stays the single source.
- The memory profile keeps one replica for orders, payments and the notifier because their state is in the pod: a second replica would not see the first one's orders. Only the gateway is replicated there.

Migrations are PreSync hook Jobs

- Orders (`python -m orders.migrate`) and payments (`java -jar payments.jar migrate`) migrate with a Job that is an Argo CD **PreSync** hook, in the same chart, using the same image as the service so the SQL and the code that expects it always ship together. The Job has a backoff limit, an active deadline (15 minutes), the same restricted security context and its own, minimal environment (only what the migration reads).
- **Not as init containers:** every replica would run the migration on each start; the advisory lock makes that safe but not free, a failing migration looks like a crash loop of the service instead of a failed deploy, and a rollout would restart pods that are healthy only to re-check the schema. **Not as startup migrations:** [ADR-0015](0015-service-data-integration.md) rejects those (races, DDL rights for the runtime role, rollback coupling).
- Behaviour when the database is not ready: the command exits non-zero, the pod is restarted with backoff, and this repeats until the deadline. Behaviour on failure: the Job fails, **the sync stops before any workload is touched, and the old pods keep serving**. Argo CD retries the sync with backoff (the ApplicationSet sets retry limits) and shows the failed hook; the logs are those of the Job's pod. A succeeded Job is deleted (`HookSucceeded`); a failed one stays for inspection and is replaced on the next attempt (`BeforeHookCreation`).
- The Job uses the namespace's default service account with no token rather than the service's own account, because on a first install the PreSync phase runs before the Deployment's ServiceAccount exists.
- Migrations are forward-only (ADR-0015), so rolling back the Deployment never needs a schema rollback; destructive schema changes follow expand-then-contract.

RabbitMQ credentials reach the shop namespace through a narrowly scoped copy Job

- The RabbitMQ operator creates `platform-mq-default-user` in the `data` namespace. The services need the credentials in `shop`. The `rabbitmq-credentials` chart in `platform/data` runs a PreSync Job (sync wave 8, after the broker) that reads that Secret and writes `rabbitmq-auth` (username, password, host, port) in `shop`, creating it or patching it so a changed source propagates on the next sync.
- **Least privilege:** the Job's service account exists only while the Job runs (all RBAC objects are hooks) and has `get` on exactly the one source Secret in `data`; `get`, `update` and `patch` on exactly the one target Secret in `shop`; and `create` on Secrets in `shop`. RBAC cannot restrict `create` by name, so the account can create other Secrets in `shop` but cannot read, change or delete any other Secret anywhere. There is no ClusterRole. The Job runs under the restricted security context. This was tested on a local cluster, including the denials.
- The values stay base64 between the two Secrets and are never printed. No credential is committed.
- **Alternative for later:** External Secrets Operator generating `rabbitmq-auth` from the cloud's secret manager, as planned for all credentials in ADR-0014. Consumers would not change, and the copy chart would be deleted.
- The chart lives with the data layer (project `platform-data`, which already reaches `data` and `shop`) rather than with the services, because the `platform-apps` project must not reach the `data` namespace at all.

Probes and shutdown

- `startupProbe` on `/healthz` allows a slow start (two minutes, for the JVM) without making the liveness probe lenient; `readinessProbe` on `/readyz` takes the pod out of the Service when a required dependency is down; `livenessProbe` on `/healthz` only restarts a process that is actually stuck. Liveness never checks dependencies, so an outage of PostgreSQL does not restart every pod.
- A `preStop` sleep (5 s) delays SIGTERM so the endpoints are removed from the Service first; the images have no shell, so it uses the Kubernetes native sleep action. Then the service's own drain starts (`/readyz` fails for `SHUTDOWN_DRAIN_SECONDS`), then in-flight requests finish within `SHUTDOWN_TIMEOUT_SECONDS`. The chart sets those two variables from the same values it uses to compute `terminationGracePeriodSeconds` (preStop + drain + timeout + 5 s), so the grace period can never be shorter than the shutdown it must cover. The rolling update uses `maxUnavailable: 0, maxSurge: 1`; on a local cluster every service was restarted in turn under a continuous request loop with no failed request.
- A PodDisruptionBudget (`maxUnavailable: 1`) and topology spread constraints over nodes and zones (`ScheduleAnyway`, so a small or single-zone cluster still schedules) keep voluntary disruptions and node loss from taking out both replicas.
- Pods use the new `platform-apps` PriorityClass (100,000), added to the existing priority-classes chart next to `platform-addons-critical` (1,000,000): the services rank below the add-ons they depend on and above workloads with no class.

Security context

- Restricted Pod Security (the `shop` namespace enforces it): non-root numeric user matching each image (65532, and 10001 for orders), `runAsNonRoot`, no privilege escalation, all capabilities dropped, `seccompProfile: RuntimeDefault`, a read-only root filesystem (an `emptyDir` on `/tmp` only for the Java service), no service account token mounted (the services never call the API; the credential copier is the one exception and is marked so), no host namespaces or host paths. These are verified on the rendered output by `make deploy-check`, not only by schema, and by admission on a local cluster.
- Requests and limits are modest for two small Spot nodes (for example 20 m / 32 Mi for the Go services, 100 m / 320 Mi for the JVM), and every container has limits.

Exposure and cost

- Every Service is `ClusterIP`; the gateway is reached inside the cluster by name. The chart has an **optional Ingress** for the gateway only, off by default: on AWS an Application Load Balancer through the AWS Load Balancer Controller (internet-facing or internal, target type `ip`, health check `/healthz`), on GKE the built-in ingress with a BackendConfig health check. An optional cert-manager `Certificate` serves TLS where the controller reads a Secret (GKE); the AWS load balancer takes its certificate from ACM through `ingress.certificateArn`, an identifier supplied at deploy time and never committed.
- **Enabling the ingress creates a billed load balancer** on either cloud, and an ALB or GCLB that is left behind by a careless teardown keeps billing. The service runbook puts deleting the Ingress and waiting for the load balancer to disappear before any other teardown step.
- Nothing else is exposed. `deploy-check` fails on a `LoadBalancer` or `NodePort` Service.

Argo CD wiring

- One ApplicationSet per service, with the cluster generator selecting clusters labelled `platform.example/managed=true` and `platform.example/apps=true` (off unless the bootstrap script is run with `--enable-apps`). One per service rather than a list generator because the waves, the cloud overlay (gateway only) and the render test stay explicit and readable, at the price of four similar files.
- Order: the RabbitMQ credential copy (wave 8, data project), then notifier and payments (20), orders (21) and the gateway (22). Within each Application the migration Job is a PreSync hook, so a service never starts against an unmigrated schema.
- A new AppProject, `platform-apps`, is limited to this repository, to the `shop` namespace, to a short allowlist of namespaced kinds, and to one cluster-scoped kind (`Namespace`, so the services can create `shop` with the restricted Pod Security label on a cluster that has no data layer). It cannot reach the `data` namespace, so neither a prune nor deleting an Application can touch the data layer or its volumes; the data layer additionally keeps `Prune=false,Delete=false` on its own resources (ADR-0014). Sync is automated with self-heal, `PruneLast` and retries with backoff.

Image tag and digest handling

- The chart hard-codes no image reference. `deploy/helm/values/images.yaml` holds the registry (GitHub Container Registry under the lowercase owner) and a **placeholder** tag, plus a `digests` map. The upcoming CI change builds and pushes the images, then updates this one file in Git (tag and per-service digest), which Argo CD syncs; a digest, when present, is appended to the reference and is what the node actually pulls. Until that happens a cluster that enables the services cannot pull images, which is intentional: the placeholder is obvious and the render checks accept it.

Deferred

- Network policies (default deny between namespaces and allow rules for gateway to orders to payments, orders to the data layer); horizontal pod autoscaling; progressive delivery (canary, automatic rollback on SLO burn); mTLS between services; External Secrets for all credentials; image signature verification at admission; a migration Job that runs as a separate database role with schema rights while the service runs with data rights only; resource tuning from real load.

## Consequences

- The services deploy from the same chart with a few lines of values each, and a security fix is one change. A bad chart change affects all four services, which the matrix of render and security checks is there to catch.
- A failed migration blocks the rollout of that service and leaves the running version serving. Recovery is a normal Git fix and sync.
- The RabbitMQ credential copy needs `create` on Secrets in `shop`, a small residual permission that exists only during the Job.
- Enabling the optional ingress is a deliberate, billed act, and teardown order matters.
- Until CI publishes images the services cannot start on a cluster; the cluster label must stay off until then.

## Alternatives considered

- One chart per service: more files, drift, and four places to fix the same bug.
- Migrations as init containers or on startup: rejected above.
- Copying the RabbitMQ Secret with a ClusterRole or a controller such as Reflector: broader permissions or another component to run for one Secret.
- Letting the operator create the user in `shop` directly: the cluster resource lives in `data` and creates its Secret next to it.
- Kustomize overlays instead of Helm values: the repository already uses Helm and Argo CD parameters everywhere; mixing a second templating tool is not worth it.
