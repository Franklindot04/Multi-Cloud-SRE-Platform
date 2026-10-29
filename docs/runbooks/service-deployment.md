# Service deployment

Deploys the four sample services (gateway, orders, payments, notifier) to a cluster through Argo CD, checks them, rolls them back, and removes them. The chart and values are in [`deploy/helm`](../../deploy/helm); the reasoning is in [ADR-0016](../adr/0016-service-deployment-model.md).

> **Prerequisite: published images.** The tag in [`deploy/helm/values/images.yaml`](../../deploy/helm/values/images.yaml) stays a placeholder until a release updates it. The `images` workflow publishes the images when changes merge to `main`; then follow [releasing images](releasing-images.md) to put the tag and digests in the values file. Do not enable the services on a cluster before that, or the pods stay in `ImagePullBackOff`.
>
> **An enabled ingress creates a billed load balancer** (an AWS Application Load Balancer or a Google Cloud HTTP(S) load balancer). The ingress is off by default. See [Teardown](#teardown) for the order that avoids leaving one behind.

## Profiles

| Profile | Cluster label | What it runs |
| --- | --- | --- |
| `memory` (default) | `platform.example/apps-profile=memory` | `STORAGE=memory`, `CACHE=none`, `MESSAGING=http`. No infrastructure needed; data is lost on restart |
| `data` | `platform.example/apps-profile=data` | `postgres`, `valkey`, `rabbitmq` in the `data` namespace. Needs the data layer ([data layer runbook](data-layer.md)) and, for the RabbitMQ credentials, its `data-rabbitmq-credentials` Application |

## Enable the services

The bootstrap script writes every label on each run, so repeat the flags you already use (for example `--enable-data`).

```bash
# preview: changes nothing, calls no cluster or cloud API
./scripts/bootstrap-argocd.sh --context <EKS_CONTEXT> --dry-run --enable-apps
# memory profile
./scripts/bootstrap-argocd.sh --context <EKS_CONTEXT> --enable-apps
# data profile (the data layer must be enabled too)
./scripts/bootstrap-argocd.sh --context <EKS_CONTEXT> --enable-data --enable-apps --apps-profile data
```

Under the hood this sets `platform.example/apps=true` (and `platform.example/apps-profile`) on the cluster Secret in the `argocd` namespace. The `apps-*` ApplicationSets select clusters by that label. The `platform-root` Application reads Git, so the `platform/argocd` and `deploy` changes must be on `main` first.

Sync order (waves): `data-rabbitmq-credentials` (8), then `apps-notifier` and `apps-payments` (20), `apps-orders` (21) and `apps-gateway` (22). Inside an Application, the migration Job (orders and payments, data profile) is a PreSync hook, so it finishes before the Deployment is touched.

## Verify

```bash
kubectl --context <CTX> -n argocd get applications | grep -E 'apps-|rabbitmq-credentials'   # Synced and Healthy
kubectl --context <CTX> -n shop get pods                                                    # all Ready
kubectl --context <CTX> -n shop get secret orders-db payments-db cache-auth rabbitmq-auth   # data profile
```

A request through a port-forward of the gateway, an order created and read back:

```bash
kubectl --context <CTX> -n shop port-forward svc/gateway 8080:8080 &
curl -s -X POST localhost:8080/api/orders -H 'Content-Type: application/json' -H 'Idempotency-Key: try-1' \
  -d '{"customer_id":"cust-1","items":[{"sku":"sku-1","quantity":2,"unit_price_minor":1250}],"currency":"USD"}'
# -> 201, "status": "paid", "total_minor": 2500
curl -s localhost:8080/api/orders/<id from the response>
```

The full end-to-end checks work against a port-forward too:

```bash
kubectl --context <CTX> -n shop port-forward svc/notifier 8083:8083 &
./scripts/smoke-test.sh          # 21 checks (memory profile)
```

Notifications arriving (data profile): the notifier consumes the order events from RabbitMQ.

```bash
kubectl --context <CTX> -n shop port-forward svc/notifier 8083:8083 &
curl -s localhost:8083/metrics | grep -E '^messages_consumed_total|^dead_letter_messages_total'
# messages_consumed_total{result="processed"} grows by two per order (order.created and order.paid)
```

Dependency status: `kubectl -n shop port-forward svc/orders 8081:8081`, then `curl -s localhost:8081/readyz` lists `postgres`, `payments`, and the degraded-only `valkey` and `rabbitmq` checks.

## Migrations

In the data profile, orders and payments each run a Job (`orders-migrate`, `payments-migrate`) as an Argo CD PreSync hook, before the Deployment changes.

- **Not ready yet:** if PostgreSQL is not reachable (just installed, failing over), or the role, its password or the database does not exist yet, the command waits and retries every five seconds, logging each attempt, for up to 780 seconds (`MIGRATE_WAIT_SECONDS`). The pod keeps running, so the Job's retry budget is untouched. After that it exits with the last error and the Job fails at its 15-minute deadline at the latest.
- **Waiting:** orders prints `database not ready (attempt N: ...); retrying in 5s (Ns of 780s)` and payments logs `database not ready, retrying` while PostgreSQL, the role or its password is not ready. The wait is inside the process, so it does not use the Job's retries; the 780 s limit (`MIGRATE_WAIT_SECONDS`) is shorter than the 900 s deadline.
- **On failure:** the sync stops before any workload is touched and **the old pods keep serving**. The Application shows `OutOfSync` with a failed PreSync hook; Argo CD retries with backoff. Fix the cause (a bad migration is fixed by a new commit, never by editing an applied one) and let it retry, or sync from the UI.
- **Read the logs** while the Job exists (a succeeded Job is deleted; a failed one stays):

  ```bash
  kubectl --context <CTX> -n shop get jobs
  kubectl --context <CTX> -n shop logs job/orders-migrate
  kubectl --context <CTX> -n shop logs job/payments-migrate
  kubectl --context <CTX> -n shop describe job orders-migrate      # attempts, deadline, events
  ```

  Orders prints `applied N migration(s): ...` and exits 0. Exit code 1 is a failed migration or an unreachable database, 2 a configuration problem (a missing Secret key, `STORAGE` not `postgres`). Payments logs one JSON line (`migrations applied`) after Flyway's plain-text lines.
- **RabbitMQ credentials:** `kubectl -n shop logs job/rabbitmq-credentials-copy` says `created` or `updated shop/rabbitmq-auth`, or that the source Secret is not available yet (it retries until the operator has created it).

## Roll back

1. **Image or chart change:** revert the commit that changed `images.yaml` or the chart and let Argo CD sync, or in the UI choose the previous revision's **Rollback** for the Application (disable automated sync first, otherwise self-heal re-applies Git). The Deployment does a normal rolling update back.
2. **Schema:** migrations are forward-only. A rollback of the application is safe because schema changes are expand-then-contract; a bad migration is corrected by a new migration.
3. **Stop everything:** remove the `platform.example/apps` label by running the bootstrap script without `--enable-apps`; the ApplicationSets delete the Applications and their resources. Data in PostgreSQL stays.

## Optional ingress

Off by default. To expose the gateway, set values for the gateway (a values change committed to Git, or a Helm parameter), for example:

```yaml
ingress:
  enabled: true
  scheme: internet-facing   # or internal
  host: shop.example.com
certificate:
  enabled: true             # GKE / controllers that read a TLS Secret; needs a ClusterIssuer
```

On AWS the load balancer takes its certificate from ACM, so pass `ingress.certificateArn` as a Helm parameter at deploy time (an identifier; never commit it). Check `kubectl -n shop get ingress` for the address; the ALB or GCLB takes a few minutes. DNS is by external-dns when enabled ([global DNS](global-dns.md)).

## Teardown

Order matters, because a load balancer left behind keeps billing:

1. **Delete the Ingress first** (set `ingress.enabled: false` and sync, or `kubectl -n shop delete ingress gateway`), if it was ever enabled.
2. **Wait for the load balancer to disappear:**

   ```bash
   kubectl --context <CTX> -n shop get ingress                    # gone
   aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'     # AWS: none from this cluster
   gcloud compute forwarding-rules list                            # GCP: none from this cluster
   ```

3. **Remove the label, not the Applications.** An Application deleted by hand is created again by its ApplicationSet while the cluster Secret carries `platform.example/apps=true`. Delete the label keys for the services and the data layer together, so nothing can recreate either:

   ```bash
   kubectl --context <CTX> -n argocd label secret cluster-in-cluster platform.example/apps- platform.example/data-
   kubectl --context <CTX> -n argocd get applications | grep -E 'apps-|data-'      # wait until empty
   kubectl --context <CTX> -n shop get deployments,statefulsets,jobs,ingresses,pods  # wait until the namespace is empty
   ```

   (Running the bootstrap script without `--enable-apps` sets the services label to `false`, which also stops them; `false` was verified to work like a missing label.)
4. **Then the data layer and its volumes**, in the order of the [data layer teardown](data-layer.md#teardown): the `Cluster` and the `RabbitmqCluster`, the RabbitMQ StatefulSet if its pod survives, the remaining claims including `platform-valkey`, `kubectl get pv` empty, then the cloud checks for volumes, load balancers and controller-created security groups. `scripts/teardown-prep.sh --context <CTX> --region <REGION>` runs steps 3 and 4 with waits (use `--dry-run` first). Deleting the services does not delete PostgreSQL, Valkey or RabbitMQ or their volumes.
5. Then the Argo CD and Terraform teardown ([Argo CD runbook](argocd.md#teardown)).

## Local test with kind

How the chart was checked on a throwaway local cluster (requires Docker and [kind](https://kind.sigs.k8s.io)). Nothing here touches a real cluster or cloud.

```bash
make apps-build                                   # sre-sample/<service>:local images
export KUBECONFIG=$(mktemp)                       # keep the test cluster out of your own kubeconfig
kind create cluster --name sre-chart-test --wait 120s
for s in gateway orders payments notifier; do kind load docker-image "sre-sample/${s}:local" --name sre-chart-test; done

# the namespace as the platform defines it: Pod Security restricted is enforced
kubectl create namespace shop
kubectl label namespace shop pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest
helm template pc platform/addons/priority-classes | kubectl apply -f -      # the platform-apps PriorityClass

for s in notifier payments orders gateway; do
  helm upgrade --install $s deploy/helm/service -n shop \
    -f deploy/helm/values/images.yaml -f deploy/helm/values/$s.yaml -f deploy/helm/values/$s-memory.yaml \
    --set image.registry=sre-sample --set image.tag=local --set image.pullPolicy=Never
done
kubectl -n shop wait --for=condition=Ready pod --all --timeout=240s

kubectl -n shop port-forward svc/gateway 18080:8080 &
kubectl -n shop port-forward svc/notifier 18083:8083 &
GATEWAY_URL=http://localhost:18080 NOTIFIER_URL=http://localhost:18083 ./scripts/smoke-test.sh

# rolling restarts under a request loop (a curl pod calling the gateway by Service name) must not fail a request
for d in notifier payments orders gateway; do kubectl -n shop rollout restart deploy/$d; kubectl -n shop rollout status deploy/$d; done

# admission check of the data profile (including the migration Jobs) against the restricted namespace
helm template orders deploy/helm/service -n shop -f deploy/helm/values/images.yaml -f deploy/helm/values/orders.yaml \
  -f deploy/helm/values/orders-data.yaml | kubectl -n shop apply --dry-run=server -f -

kind delete cluster --name sre-chart-test
```

What this verified, and what it could not, is recorded in the change summary: pods Ready under `restricted` with a read-only root filesystem, probes passing, the gateway reaching the others by Service name, 21 of 21 smoke checks, 471 request pairs with no failure across restarts of all four services, the RabbitMQ credential copy Job and its permissions. It cannot verify the data profile end to end (there is no PostgreSQL, Valkey or RabbitMQ in that cluster), the Argo CD hooks and sync waves, the ingress controllers, or multi-node and multi-zone spreading.

## Troubleshooting

- **`ImagePullBackOff`:** the images in `images.yaml` are not published or the registry is private; set `imagePullSecrets` or publish the images.
- **Pods `CreateContainerConfigError`:** a Secret the profile reads is missing (`orders-db`, `payments-db`, `cache-auth` from `data-secrets`; `rabbitmq-auth` from `data-rabbitmq-credentials`). `kubectl -n shop describe pod` names it.
- **Pod rejected by Pod Security:** the message names the violated rule; the chart is meant to satisfy `restricted`, so a change to the security context is the cause.
- **`orders` not ready, `payments` ok:** `curl localhost:8081/readyz` (port-forward) names the failing check; `postgres` and `payments` are required, `valkey` and `rabbitmq` only degrade.
- **PreSync hook stuck:** `kubectl -n shop get jobs,pods` and the Job logs above. A migration that cannot reach PostgreSQL, or whose role or password is not set up yet, logs `database not ready` every five seconds and keeps waiting for up to 13 minutes (`MIGRATE_WAIT_SECONDS`), then fails with the last error.
- **`rabbitmq-auth` or another Secret is missing:** the copy and generator Jobs run during a sync; see the secrets entries in the [data layer troubleshooting](data-layer.md#troubleshooting).
- **Memory profile loses orders after a restart:** by design; orders and payments hold their state in the pod there.
