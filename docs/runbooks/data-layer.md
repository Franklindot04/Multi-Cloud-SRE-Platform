# Data layer

Deploys and operates PostgreSQL, Valkey and RabbitMQ on a cluster through Argo CD, runs them locally for development, and removes them safely. Definitions and conventions are in [`platform/data`](../../platform/data); the reasoning is in [ADR-0014](../adr/0014-data-layer.md).

> **Volumes outlive the cluster.** The disks these workloads create are not managed by Terraform. `terraform destroy` does not remove them and they keep billing. The [teardown](#teardown) section is required before destroying a cluster that ever ran the data layer.

## How it is deployed

Argo CD (see the [Argo CD runbook](argocd.md)) has eight ApplicationSets for the data layer, applied to clusters labelled `platform.example/data=true`:

| Wave | Application | Purpose |
| --- | --- | --- |
| 5 | `data-namespaces`, `data-storage` | Namespaces with Pod Security labels; the `platform-data` StorageClass |
| 6 | `data-secrets`, `data-cnpg-operator`, `data-rabbitmq-operator` | Credential generation; the two operators |
| 7 | `data-postgres`, `data-valkey`, `data-rabbitmq` | The databases, cache and broker themselves |

Custom resources wait for their operator through retries with backoff and `SkipDryRunOnMissingResource`, so the first sync takes a few minutes while CRDs, webhooks and credentials appear. Automated pruning cannot delete data: the `Cluster`, `RabbitmqCluster`, Valkey claim, namespaces and storage class carry `Prune=false,Delete=false`.

## Prerequisites

- Argo CD bootstrapped on the cluster, with cert-manager healthy (the RabbitMQ operator's webhooks need it) and the `priority-classes` add-on.
- On EKS, the EBS CSI driver (installed by the `aws-eks` module); on GKE, the built-in Persistent Disk CSI driver.
- Enough capacity: the standard profile requests about 0.75 vCPU and 1.7 GiB. The HA profile needs at least three schedulable nodes.
- The definitions merged to `main`.

## Enable it on a cluster

Data is **off** unless the cluster Secret carries the label. At bootstrap:

```bash
./scripts/bootstrap-argocd.sh --context <EKS_CONTEXT> --enable-data            # standard profile
./scripts/bootstrap-argocd.sh --context <EKS_CONTEXT> --enable-data --data-profile ha
```

On an existing hub, change the labels directly (they are not secrets):

```bash
kubectl --context <EKS_CONTEXT> -n argocd label secret cluster-in-cluster platform.example/data=true --overwrite
kubectl --context <EKS_CONTEXT> -n argocd label secret cluster-in-cluster platform.example/data-profile=standard --overwrite
```

Removing the `platform.example/data` label (or setting it to `false`) stops Argo CD managing the data Applications, but **it does not delete the data** (see teardown).

## Verify

```bash
# Operators and applications
kubectl -n cnpg-system get pods
kubectl -n rabbitmq-system get pods
kubectl -n argocd get applications | grep data-
kubectl get storageclass platform-data

# Everything in the data namespace
kubectl -n data get cluster.postgresql.cnpg.io,rabbitmqcluster,pods,pvc
kubectl get ns data shop --show-labels                 # Pod Security labels
kubectl -n data get cluster.postgresql.cnpg.io platform-pg    # STATUS "Cluster in healthy state"
kubectl -n data get rabbitmqcluster platform-mq               # ALLREPLICASREADY True
kubectl -n shop get secrets orders-db payments-db cache-auth  # generated credentials exist
```

PVCs should be `Bound` with storage class `platform-data`. Pod Security `warn` messages at deploy time, if any, list pods that would fail the `restricted` level.

### A test query

```bash
PW=$(kubectl -n shop get secret orders-db -o jsonpath='{.data.password}' | base64 -d)
kubectl -n data run psql-test --rm -i --restart=Never --image=ghcr.io/cloudnative-pg/postgresql:18.6-minimal-trixie \
  --env="PGPASSWORD=$PW" -- psql -h platform-pg-rw.data.svc -U orders -d orders -c 'select current_user, current_database()'
# The orders role must be refused by the payments database:
kubectl -n data run psql-test --rm -i --restart=Never --image=ghcr.io/cloudnative-pg/postgresql:18.6-minimal-trixie \
  --env="PGPASSWORD=$PW" -- psql -h platform-pg-rw.data.svc -U orders -d payments -c 'select 1'
```

### A cache set and get

```bash
CPW=$(kubectl -n shop get secret cache-auth -o jsonpath='{.data.password}' | base64 -d)
kubectl -n data run valkey-test --rm -i --restart=Never --image=valkey/valkey:9.1.2 \
  --env="REDISCLI_AUTH=$CPW" -- sh -c 'valkey-cli -h platform-valkey set smoke hello EX 60 && valkey-cli -h platform-valkey get smoke'
kubectl -n data run valkey-noauth --rm -i --restart=Never --image=valkey/valkey:9.1.2 -- valkey-cli -h platform-valkey ping   # NOAUTH
```

### A test publish and consume

```bash
MQ_USER=$(kubectl -n data get secret platform-mq-default-user -o jsonpath='{.data.username}' | base64 -d)
MQ_PASS=$(kubectl -n data get secret platform-mq-default-user -o jsonpath='{.data.password}' | base64 -d)
kubectl -n data port-forward svc/platform-mq 15672:15672 &
PF=$!; sleep 3
H='content-type: application/json'
curl -su "$MQ_USER:$MQ_PASS" -H "$H" -X PUT  -d '{"durable":true}' http://127.0.0.1:15672/api/queues/%2F/smoke
curl -su "$MQ_USER:$MQ_PASS" -H "$H" -X POST -d '{"properties":{},"routing_key":"smoke","payload":"hello","payload_encoding":"string"}' http://127.0.0.1:15672/api/exchanges/%2F/amq.default/publish
curl -su "$MQ_USER:$MQ_PASS" -H "$H" -X POST -d '{"count":1,"ackmode":"ack_requeue_false","encoding":"auto"}' http://127.0.0.1:15672/api/queues/%2F/smoke/get   # payload "hello"
curl -su "$MQ_USER:$MQ_PASS" -X DELETE http://127.0.0.1:15672/api/queues/%2F/smoke
kill $PF
```

## Run it locally

A Compose stack with the same three components (pinned images, healthchecks, named volumes, every port bound to `127.0.0.1`, RabbitMQ management UI on `http://localhost:15672`):

```bash
cp apps/.env.example apps/.env      # fake values; change them. apps/.env is not tracked
make data-up
make data-check                     # waits for the healthchecks, then tests each component
make data-down                      # stops; keeps the volumes
make data-down PURGE=1              # stops and removes the volumes
```

`make data-check` verifies that each service role reaches only its own PostgreSQL database, that Valkey refuses unauthenticated commands and round-trips an authenticated SET and GET, and that a message published to RabbitMQ is read back. To run the application services against this stack, see "Run the services against the data layer" in the [local development runbook](local-development.md) (`make integration-test`).

## How the services use it

The services are connected to this data layer ([ADR-0015](../adr/0015-service-data-integration.md)): orders and payments store their data in the PostgreSQL databases `orders` and `payments`, orders caches reads in Valkey, and order events travel from an outbox in the orders database through the `platform.events` exchange in RabbitMQ to the notifier. Each is optional and off by default (`STORAGE`, `CACHE`, `MESSAGING`). The services need only a host, port and credentials, so the same images run against the in-cluster components or against managed services.

### Migrations

The schema is created by a separate, forward-only step that runs before the service starts. Locally these are the Compose services `orders-migrate` (`python -m orders.migrate`) and `payments-migrate` (`java -jar payments.jar migrate`). Both take a PostgreSQL advisory lock, so running two at once is safe, and both are idempotent: a second run applies nothing. To see what ran: `docker compose ... logs orders-migrate payments-migrate`, or `SELECT * FROM schema_migrations` (orders) and `SELECT * FROM flyway_schema_history` (payments).

**On Kubernetes** the migrations are PreSync hook Jobs in the service chart (`orders-migrate`, `payments-migrate`) and the RabbitMQ credentials are copied into `shop` by the `rabbitmq-credentials` chart; see the [service deployment runbook](service-deployment.md) and [ADR-0016](../adr/0016-service-deployment-model.md). The migration role is the database owner today; later it can be split from a runtime role with DML rights only.

### Dead-letter queue: inspect and replay

Messages that the notifier cannot process end up in `notifier.orders.dlq` with the reason in the `x-failure-reason` header (also `x-attempts` and `x-original-routing-key`). Metrics: `dead_letter_messages_total` and `consumer_queue_messages{queue="dead_letter"}` on the notifier.

Inspect (management UI at `http://localhost:15672` locally, queue `notifier.orders.dlq`, "Get messages" with "Nack message requeue true" so nothing is removed), or with the HTTP API:

```bash
# load RABBITMQ_DEFAULT_USER / RABBITMQ_DEFAULT_PASS from apps/.env first (never paste them into a shell history)
curl -s -u "$RABBITMQ_DEFAULT_USER:$RABBITMQ_DEFAULT_PASS" -H 'content-type: application/json' \
  -X POST http://127.0.0.1:15672/api/queues/%2F/notifier.orders.dlq/get \
  -d '{"count":10,"ackmode":"ack_requeue_true","encoding":"auto"}'
```

Decide per message. A message dead-lettered for `invalid_json`, `unknown_event_type` or `unsupported_schema_version_N` is a producer or contract problem: fix the cause, do not replay it as is. A message dead-lettered for `max_attempts_exceeded: ...` failed for a transient reason: replay it once the cause (for example storage in the consumer) is fixed.

Replay moves the message back to the main queue through the default exchange, which is safe because the handler is idempotent on the event ID:

```bash
# one message: read it (ack_requeue_false removes it), then republish it to the main queue
curl -s -u "$RABBITMQ_DEFAULT_USER:$RABBITMQ_DEFAULT_PASS" -H 'content-type: application/json' \
  -X POST http://127.0.0.1:15672/api/queues/%2F/notifier.orders.dlq/get \
  -d '{"count":1,"ackmode":"ack_requeue_false","encoding":"auto"}' > dead-letter.json
# republish the "payload" value from that file:
curl -s -u "$RABBITMQ_DEFAULT_USER:$RABBITMQ_DEFAULT_PASS" -H 'content-type: application/json' \
  -X POST http://127.0.0.1:15672/api/exchanges/%2F/amq.default/publish \
  -d '{"properties":{"delivery_mode":2},"routing_key":"notifier.orders","payload":"<payload from the file>","payload_encoding":"string"}'
```

Or use the "Move messages" feature of the management UI (Queues, the dead-letter queue, Move messages, destination `notifier.orders`) to replay every message at once. On Kubernetes use `kubectl port-forward` to the `platform-mq` service for the same API, or `rabbitmqadmin`. To discard a message instead, read it with `ackmode: ack_requeue_false` and do not republish it; to purge everything, "Purge messages" on the queue. Record why in the incident notes before discarding.

### Stuck or growing outbox

`outbox_unpublished_events` and `outbox_oldest_unpublished_age_seconds` (orders) show the lag. A rising count with `messages_published_total{result="error"}` means the broker is unreachable or refusing messages; the orders logs say which. Nothing needs to be done to the table: the relay retries with backoff and publishes everything once the broker is back, in creation order. Published rows are kept (a retention job is deferred), so the table only grows.

## Manifest checks

```bash
make data-check-manifests
```

See the data layer README for what it covers.

## Teardown

Do this **before `terraform destroy`**, in this order. The aim is zero leftover cloud volumes, load balancers and controller-created security groups. The order comes from the first teardown on a real EKS cluster; the reasons are in [ADR-0018](../adr/0018-secret-generation-and-ordering.md).

### With the script

```bash
scripts/teardown-prep.sh --context <EKS_CONTEXT> --region <REGION> --dry-run     # print every step, change nothing
scripts/teardown-prep.sh --context <EKS_CONTEXT> --region <REGION> --cluster-name <CLUSTER_NAME>
```

`--context` is required (the script never uses the current context). It waits for each step (`--timeout`, 600 seconds a step by default) and stops at the first one that does not finish, so it is safe to run again after fixing the cause. It deletes only the named resources in the `argocd`, `shop`, `data` and `observability` namespaces, never forces a deletion, and does not delete namespaces, the storage class, Argo CD or anything in the cloud. `--skip-aws` stops after step 11 (GKE, or no AWS credentials). It was tested against a fake `kubectl` and a fake `aws`, not against a real cluster: run `--dry-run` first and read the output.

The steps, in order:

1. Remove the cluster Secret label keys (`apps`, `data` and `observability`).
2. Wait for the `apps-*`, `data-*` and `observability-*` Applications to go. This also removes the CloudNativePG, RabbitMQ Cluster and Prometheus operators.
3. Wait for the `shop` namespace to empty.
4. If the `observability` namespace exists, wait for its pods to go.
5. If it exists, delete its PersistentVolumeClaims. There are none unless the [persistent values](../../platform/observability/README.md#sizing-and-storage) were used.
6. Delete the CloudNativePG `Database` objects (`platform-pg-orders`, `platform-pg-payments`) and wait for them.
7. Delete the CloudNativePG `Cluster`.
8. Delete the `RabbitmqCluster` and wait for it, then its StatefulSet if that survives.
9. Wait for the pods in `data` to go.
10. Delete the PersistentVolumeClaims, including `platform-valkey`.
11. Confirm `kubectl get pv` is empty.
12. to 14. AWS: no leftover tagged volumes, load balancers or security groups.

**Operators that are already gone.** Step 2 removes the operators, but a `Database` and a `RabbitmqCluster` carry a finalizer that only their operator can remove, so their deletion would otherwise hang until the timeout. In steps 6 and 8 the script deletes the object and, while it waits, checks whether the operator still has a running pod (`cnpg-system` and `rabbitmq-system` are only read). With the operator running it just waits. With the operator gone it removes the one finalizer the operator would have removed, from that one object, prints what it removed and why, and carries on:

| Object | Finalizer the script may remove | Operator it looks for |
| --- | --- | --- |
| `Database` (`databases.postgresql.cnpg.io`) | `cnpg.io/deleteDatabase` | pods labelled `app.kubernetes.io/name=cloudnative-pg` in `cnpg-system` |
| `RabbitmqCluster` (`rabbitmqclusters.rabbitmq.com`) | `deletion.finalizers.rabbitmqclusters.rabbitmq.com` | pods labelled `app.kubernetes.io/name=rabbitmq-cluster-operator` in `rabbitmq-system` |

Nothing else is ever changed. An object stuck on any other finalizer is left alone: the script times out and prints the finalizers it found. If it cannot ask the cluster whether the operator runs, it stops. The `Database` objects use `databaseReclaimPolicy: retain`, so removing them does not drop the databases; they go with the `Cluster` in step 5. Under `--dry-run` it says, per object, whether it would only wait or would remove the finalizer.

**The Prometheus Operator needs no such handling.** Its only finalizer is `monitoring.coreos.com/status-cleanup`, set on the `Prometheus` object itself (never on a `ServiceMonitor`, `PodMonitor` or rule) and only when the operator's `StatusForConfigurationResources` feature gate is on. The gate is off by default and the stack does not turn it on, so nothing holds the objects when the operator goes first (checked against the operator source at the pinned version, see [ADR-0020](../adr/0020-metrics-stack.md)). If someone enabled the gate and a `Prometheus` is stuck, step 4 times out on the pods that remain and prints this; the script does not remove that finalizer. Step 5 deletes the claims of the optional persistent volumes, which would otherwise keep billing after `terraform destroy`.

### By hand

1. **Remove the cluster Secret labels.** Delete the label keys; this is what stops the ApplicationSets from recreating Applications. Deleting an Application by hand does not work for as long as the labels select the cluster, and the Applications' finalizers delete what they own:

   ```bash
   kubectl --context <EKS_CONTEXT> -n argocd label secret cluster-in-cluster platform.example/apps- platform.example/data- platform.example/observability-
   kubectl --context <EKS_CONTEXT> -n argocd get applications | grep -E 'apps-|data-|observability-'     # wait until none remain
   ```

   Setting the labels to `false` also works (the selectors match the value `"true"`; verified against the ApplicationSet controller on a throwaway cluster, see the ADR), and the bootstrap script writes `false`. Deleting the keys is preferred because nothing then depends on the value. Delete the services' Ingress first if one was ever enabled ([service deployment runbook](service-deployment.md#teardown)).
2. **Wait for the `shop` namespace to empty:**

   ```bash
   kubectl --context <EKS_CONTEXT> -n shop get deployments,statefulsets,jobs,ingresses,pods     # nothing
   ```

3. **Delete the CloudNativePG `Database` objects, the `Cluster` and the `RabbitmqCluster`**, in that order. If the operators are already gone, the `Database` and `RabbitmqCluster` deletions hang on an operator finalizer; see [namespace stuck in Terminating](#troubleshooting). (The resources marked `Prune=false,Delete=false` deliberately stay when the Applications go). Deleting the `Cluster` removes its pod and claim. Deleting the `RabbitmqCluster` does **not** remove its StatefulSet or pod, so the claim stays `Bound`: delete the StatefulSet (named `<cluster>-server`) as well:

   ```bash
   kubectl --context <EKS_CONTEXT> -n data delete cluster.postgresql.cnpg.io platform-pg
   kubectl --context <EKS_CONTEXT> -n data delete rabbitmqcluster.rabbitmq.com platform-mq
   kubectl --context <EKS_CONTEXT> -n data get statefulset                                 # platform-mq-server survives
   kubectl --context <EKS_CONTEXT> -n data delete statefulset platform-mq-server
   kubectl --context <EKS_CONTEXT> -n data get pods                                        # wait until none remain
   ```

   If the metrics foundation was deployed with the persistent values, also delete its claims before the cloud checks below: `kubectl --context <EKS_CONTEXT> -n observability get pvc`, then delete each one by name. Without those values there are none.
4. **Delete the remaining PersistentVolumeClaims**, including `platform-valkey`, whose claim is kept on purpose, then confirm no volume is left in the cluster:

   ```bash
   kubectl --context <EKS_CONTEXT> -n data get pvc
   kubectl --context <EKS_CONTEXT> -n data delete pvc platform-valkey                      # and any other claim listed
   kubectl --context <EKS_CONTEXT> -n data get pvc                                         # No resources found
   kubectl --context <EKS_CONTEXT> get pv                                                  # No resources found
   ```

   With the `platform-data` storage class (`reclaimPolicy: Delete`) the cloud disks are removed with their claims. A claim stuck in `Terminating` means a pod still uses it: find the pod with `kubectl -n data get pods` and delete its owner (the StatefulSet) first. Do not force-delete a claim.
5. **Confirm with the cloud CLI that only the node root volumes remain.** Both commands must list nothing from this cluster.

   AWS (EKS):

   ```bash
   aws ec2 describe-volumes --region <REGION> \
     --filters Name=tag-key,Values=kubernetes.io/created-for/pvc/name \
     --query 'Volumes[].[VolumeId,State,Size,Tags[?Key==`kubernetes.io/created-for/pvc/namespace`]|[0].Value,Tags[?Key==`kubernetes.io/created-for/pvc/name`]|[0].Value]' \
     --output table
   aws ec2 describe-volumes --region <REGION> --filters Name=status,Values=available --query 'Volumes[].VolumeId'
   ```

   Node root volumes carry no `kubernetes.io/created-for/pvc/name` tag, so the first command lists nothing when only they remain. Delete any survivor by hand after checking it is not in use (`aws ec2 delete-volume --volume-id <ID>`).

   GCP (GKE):

   ```bash
   gcloud compute disks list --project <PROJECT_ID> \
     --filter='name~^pvc-' \
     --format='table(name,zone.basename(),sizeGb,status,users.basename())'
   gcloud compute disks list --project <PROJECT_ID> --filter='-users:*' --format='value(name,zone.basename())'
   ```

6. **AWS: check for load balancers and security groups created by the AWS Load Balancer Controller.** The controller tags what it creates with `elbv2.k8s.aws/cluster` (the cluster name). Both queries must come back empty; a security group can take a few minutes to go after its load balancer:

   ```bash
   aws resourcegroupstaggingapi get-resources --region <REGION> \
     --resource-type-filters elasticloadbalancing:loadbalancer \
     --tag-filters Key=elbv2.k8s.aws/cluster,Values=<CLUSTER_NAME> \
     --query 'ResourceTagMappingList[].ResourceARN'
   aws ec2 describe-security-groups --region <REGION> \
     --filters Name=tag:elbv2.k8s.aws/cluster,Values=<CLUSTER_NAME> \
     --query 'SecurityGroups[].[GroupId,GroupName]'
   ```

   A security group left behind blocks deletion of the VPC. Delete a survivor only after its load balancer and network interfaces are gone.
7. **Delete the namespaces and the storage class** (Argo CD does not prune them), then continue with the [Argo CD](argocd.md#teardown) and [EKS](aws-eks.md#destroy) or [GKE](gcp-gke.md#destroy-checklist) teardown and `terraform destroy`:

   ```bash
   kubectl --context <EKS_CONTEXT> delete namespace data shop cnpg-system rabbitmq-system
   kubectl --context <EKS_CONTEXT> delete storageclass platform-data
   ```

### Data teardown checklist

- [ ] The cluster Secret labels `platform.example/apps` and `platform.example/data` removed first; their Applications gone (not deleted by hand); the `shop` namespace empty
- [ ] `Database` objects, `Cluster` and `RabbitmqCluster` deleted (an operator finalizer cleared only where its operator was gone), the RabbitMQ StatefulSet deleted by hand, the Valkey claim deleted
- [ ] `kubectl -n data get pvc` shows nothing and `kubectl get pv` is empty
- [ ] AWS: no `kubernetes.io/created-for/pvc/name` volumes (only node root volumes remain) and no `available` volumes in the region
- [ ] AWS: no load balancer and no security group tagged `elbv2.k8s.aws/cluster` for this cluster
- [ ] GCP: no `pvc-` disks and no disks without users
- [ ] Namespaces and the `platform-data` storage class deleted

## Troubleshooting

- **The `data` namespace is stuck in `Terminating`** (or a delete in it hangs): something in it still has a finalizer. Find out what, in this order:

  ```bash
  kubectl --context <CONTEXT> get namespace data -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.message}{"\n"}{end}'
  kubectl --context <CONTEXT> api-resources --verbs=list --namespaced -o name \
    | xargs -n 1 kubectl --context <CONTEXT> -n data get --ignore-not-found --show-kind --no-headers
  kubectl --context <CONTEXT> -n data get <KIND>/<NAME> -o jsonpath='{.metadata.deletionTimestamp}{"\n"}{.metadata.finalizers}{"\n"}'
  ```

  The namespace conditions name what remains (`NamespaceContentRemaining`, `NamespaceFinalizersRemaining`). The second command lists every object left, and the third shows the finalizers of one. Then ask who owns the finalizer and whether that owner still runs. Safe to clear, by hand, only when the owner is gone for good and the object is already being deleted:

  | Object | Finalizer | Owner | Check before clearing |
  | --- | --- | --- | --- |
  | `Database` | `cnpg.io/deleteDatabase` | CloudNativePG operator | `kubectl -n cnpg-system get pods` shows no operator pod |
  | `RabbitmqCluster` | `deletion.finalizers.rabbitmqclusters.rabbitmq.com` | RabbitMQ Cluster Operator | `kubectl -n rabbitmq-system get pods` shows no operator pod |

  Clear one finalizer from one object, testing its value first so nothing else is removed (this is what the teardown script does; here the finalizer is at index 0):

  ```bash
  kubectl --context <CONTEXT> -n data patch database.postgresql.cnpg.io/<NAME> --type=json \
    -p '[{"op":"test","path":"/metadata/finalizers/0","value":"cnpg.io/deleteDatabase"},{"op":"remove","path":"/metadata/finalizers/0"}]'
  ```

  Do not clear a finalizer while its operator is running (it removes it itself, and clearing early skips the cleanup it does), do not clear a finalizer you cannot attribute to an owner, and do not use `--force` or `--grace-period=0`. The same applies when `teardown-prep.sh` times out on a `Database` or `RabbitmqCluster`: it prints the finalizers and says whether the operator is running, and it clears only the two above. Running it again continues from where it stopped.
- **`data-postgres` stays `Progressing`:** the operator or the `pg-orders` and `pg-payments` Secrets are not ready yet. Check `kubectl -n cnpg-system get pods`, `kubectl -n argocd get application data-secrets-*`, and `kubectl -n data describe cluster.postgresql.cnpg.io platform-pg`; retries continue with backoff.
- **PVC stuck `Pending`:** the `platform-data` class is missing (check `data-storage`) or no node can take the volume's zone; see `kubectl describe pvc`.
- **Pods rejected by Pod Security:** `kubectl -n data describe` shows the violated rule. `data` enforces `baseline`; a violation means a chart changed its security context.
- **RabbitMQ pods `Pending` on HA:** the HA profile needs three nodes.
- **Secret changes ignored:** the generator never overwrites existing Secrets. To rotate a credential, delete the Secret, let the next sync recreate it, and update the database role (rotation is an operator task until external secrets arrive).
- **Secrets missing (`valkey-auth`, `pg-orders`, `orders-db`, `rabbitmq-auth`...):** the generator Jobs run during a sync. Check `kubectl -n argocd get application data-secrets-<cluster> -o jsonpath='{.status.operationState.phase}'`; an empty phase means no sync ever ran, so start one: `kubectl -n argocd patch application data-secrets-<cluster> --type merge -p '{"operation":{"sync":{}}}'`. A failed Job is kept for an hour: `kubectl -n data logs job/data-secrets-generator`; it needs the API reachable and its Role (get, create on Secrets in `data` and `shop`; patch on the two `pg-` Secrets).
- **`data-postgres` stuck in PreSync:** the gate Job is waiting for the role Secrets: `kubectl -n data logs job/platform-pg-secrets-gate`. It names the Secret it is waiting for; fix `data-secrets` as above. It gives up after 15 minutes and Argo CD retries.
- **PostgreSQL roles `pending-reconciliation`** (`kubectl -n data get cluster platform-pg -o jsonpath='{.status.managedRolesStatus}'` shows `cannotReconcile` with a missing Secret): normally the PreSync gate prevents it. If the Secret was created late, CloudNativePG retries on its own within about two minutes. To make it look now, nudge the Cluster with an annotation; it is safe, and Argo CD ignores it:

  ```bash
  kubectl -n data annotate cluster.postgresql.cnpg.io/platform-pg platform.example/reconcile-nudge="$(date +%s)" --overwrite
  ```

- **A migration Job logs `database not ready`:** expected while PostgreSQL, a role or a password comes up. It retries every five seconds for up to 13 minutes without using the Job's retries, then fails with the last error. See the [service deployment runbook](service-deployment.md#migrations).
