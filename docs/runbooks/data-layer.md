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

Setting `platform.example/data` back to `false` stops Argo CD managing the data Applications, but **it does not delete the data** (see teardown).

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

`make data-check` verifies that each service role reaches only its own PostgreSQL database, that Valkey refuses unauthenticated commands and round-trips an authenticated SET and GET, and that a message published to RabbitMQ is read back. The application services are not wired to these yet.

## Manifest checks

```bash
make data-check-manifests
```

See the data layer README for what it covers.

## Teardown

Do this **before `terraform destroy`**, in this order. The aim is zero leftover cloud volumes.

1. **Stop the services using the data** (the application Applications, once they exist).
2. **Stop Argo CD managing the data layer.** Set the cluster label to `false` so the Applications are deleted (their `Delete=false` resources stay):

   ```bash
   kubectl --context <EKS_CONTEXT> -n argocd label secret cluster-in-cluster platform.example/data=false --overwrite
   kubectl -n argocd get applications | grep data-        # wait until they are gone
   ```

3. **Delete the data resources, which are deliberately kept:**

   ```bash
   kubectl -n data delete cluster.postgresql.cnpg.io --all
   kubectl -n data delete rabbitmqcluster --all
   kubectl -n data delete deployment,statefulset --all    # Valkey, if any remains
   ```

4. **Delete every PersistentVolumeClaim in the data namespace, then confirm none remain:**

   ```bash
   kubectl -n data delete pvc --all
   kubectl -n data get pvc                                 # No resources found
   kubectl get pv                                          # none with claim data/...
   ```

   With the `platform-data` storage class (`reclaimPolicy: Delete`) the cloud disks are removed with their claims. A volume stuck in `Terminating` means a pod still uses it; delete the pod's owner first.
5. **Delete the namespaces and the storage class** (they are not pruned by Argo CD):

   ```bash
   kubectl delete namespace data shop cnpg-system rabbitmq-system
   kubectl delete storageclass platform-data
   ```

6. **Confirm the cloud volumes are gone.** Both commands must list nothing from this cluster.

   AWS (EKS):

   ```bash
   aws ec2 describe-volumes --region eu-north-1 \
     --filters Name=tag-key,Values=kubernetes.io/created-for/pvc/name \
     --query 'Volumes[].[VolumeId,State,Size,Tags[?Key==`kubernetes.io/created-for/pvc/namespace`]|[0].Value,Tags[?Key==`kubernetes.io/created-for/pvc/name`]|[0].Value]' \
     --output table
   aws ec2 describe-volumes --region eu-north-1 --filters Name=status,Values=available --query 'Volumes[].VolumeId'
   ```

   GCP (GKE):

   ```bash
   gcloud compute disks list --project <PROJECT_ID> \
     --filter='name~^pvc-' \
     --format='table(name,zone.basename(),sizeGb,status,users.basename())'
   gcloud compute disks list --project <PROJECT_ID> --filter='-users:*' --format='value(name,zone.basename())'
   ```

   Delete any survivor by hand (`aws ec2 delete-volume --volume-id <ID>`, `gcloud compute disks delete <NAME> --zone <ZONE>`) after checking it is not in use.
7. Continue with the [Argo CD](argocd.md#teardown) and [EKS](aws-eks.md#destroy-checklist) or [GKE](gcp-gke.md#destroy-checklist) teardown.

### Data teardown checklist

- [ ] Data Applications deleted; `Cluster`, `RabbitmqCluster` and Valkey resources deleted
- [ ] `kubectl -n data get pvc` shows nothing and `kubectl get pv` has no `data/` claims
- [ ] Namespaces and the `platform-data` storage class deleted
- [ ] AWS: no `kubernetes.io/created-for/pvc/name` volumes and no `available` volumes in `eu-north-1`
- [ ] GCP: no `pvc-` disks and no disks without users

## Troubleshooting

- **`data-postgres` stays `Progressing`:** the operator or the `pg-orders` and `pg-payments` Secrets are not ready yet. Check `kubectl -n cnpg-system get pods`, `kubectl -n argocd get application data-secrets-*`, and `kubectl -n data describe cluster.postgresql.cnpg.io platform-pg`; retries continue with backoff.
- **PVC stuck `Pending`:** the `platform-data` class is missing (check `data-storage`) or no node can take the volume's zone; see `kubectl describe pvc`.
- **Pods rejected by Pod Security:** `kubectl -n data describe` shows the violated rule. `data` enforces `baseline`; a violation means a chart changed its security context.
- **RabbitMQ pods `Pending` on HA:** the HA profile needs three nodes.
- **Secret changes ignored:** the generator never overwrites existing Secrets. To rotate a credential, delete the Secret, let the next sync recreate it, and update the database role (rotation is an operator task until external secrets arrive).
- **Hook Job failed:** `kubectl -n data logs job/data-secrets-generator`; it needs the API reachable and RBAC to create Secrets in `data` and `shop`.
