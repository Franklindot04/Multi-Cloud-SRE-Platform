# secrets

Generates the data layer credentials **inside the cluster**, once, so no password is ever committed or passes through Git, Argo CD parameters or Terraform.

The chart renders ordinary RBAC objects (a ServiceAccount, Roles limited to `get` and `create` on Secrets in the two namespaces and `patch` on the two PostgreSQL role Secrets, RoleBindings) and a ConfigMap listing the Secret names, so the Application always has something to sync and Argo CD starts the first sync by itself. A Job run as an Argo CD Sync hook (the official `curl` image and the Kubernetes API) creates each Secret only if it does not exist. Existing Secrets are never modified, so re-syncs do not rotate passwords. The Job is removed when it succeeds, and is not compared with the live state, so its disappearance never makes the Application OutOfSync. If a Secret was deleted by hand, start a sync to recreate it. The reasoning, and why a plain Job with a TTL was rejected, is in [ADR-0018](../../../docs/adr/0018-secret-generation-and-ordering.md). The `pg-` Secrets carry the label `cnpg.io/reload: "true"` so CloudNativePG watches them. Passwords are 32 random alphanumeric characters.

| Secret | Namespace | Type and keys | Read by |
| --- | --- | --- | --- |
| `pg-orders`, `pg-payments` | `data` | `kubernetes.io/basic-auth`: `username`, `password` | CloudNativePG (database role passwords) |
| `valkey-auth` | `data` | `default` (the password of Valkey's `default` user) | the Valkey chart |
| `orders-db`, `payments-db` | `shop` | `username`, `password`, `host`, `port`, `dbname` | the orders and payments services |
| `cache-auth` | `shop` | `password`, `host`, `port` | the services that use the cache |

RabbitMQ credentials are created by the RabbitMQ Cluster Operator (`platform-mq-default-user` in `data`: `username`, `password`, `host`, `port`); the next change copies what the services need into `shop`.

The Job is the interim mechanism. When an external secrets manager is introduced, the same Secret names and keys are produced by External Secrets instead, so the consumers do not change (see [ADR-0014](../../../docs/adr/0014-data-layer.md)).

The generator Job is an Argo CD Sync hook, not a plain Job: a plain Job with `ttlSecondsAfterFinished` is deleted by the TTL controller and recreated by Argo CD in a loop. Why, and how it was tested (restricted Pod Security profile, a second run leaves the Secrets untouched), is in [ADR-0018](../../../docs/adr/0018-secret-generation-and-ordering.md). `make data-check-manifests` fails if this chart renders only hooks or if the Job becomes a Helm hook.

## Two modes

**Generated (the default)** is what is described above: a Job in the cluster makes each password once.

**External** renders one ExternalSecret for each Secret in the table above, with the same name, namespace, type, labels and keys, and does **not** render the generator Job, its ServiceAccount, Roles and RoleBindings, the ConfigMap that lists the names, or any Secret with a value. The password of each Secret is read from a parameter: `postgres/orders-password` for `pg-orders` and `orders-db`, `postgres/payments-password` for `pg-payments` and `payments-db`, `valkey/default-password` for `valkey-auth` and `cache-auth`. The user names, hosts, ports and database names are chart values, built into the Secret by the ExternalSecret template. The `pg-` Secrets keep the type `kubernetes.io/basic-auth` and the label `cnpg.io/reload`.

The mode is chosen per cluster. The ApplicationSet passes `externalSecrets.enabled` from the cluster Secret label `platform.example/external-secrets` (off when the label is absent) and `externalSecrets.prefix` from the annotation `platform.example/secrets-prefix` (for example `/multi-cloud-sre/dev`); `scripts/bootstrap-argocd.sh --enable-external-secrets` sets both. The default is off, so a cluster without AWS behaves as it always did. With the mode on the chart refuses to render without the prefix.

The values are in AWS Systems Manager Parameter Store as SecureString parameters, written by `scripts/seed-secrets.sh` from [`scripts/secrets/manifest.yaml`](../../../scripts/secrets/manifest.yaml); they never pass through Git, Argo CD parameters or Terraform. The ClusterSecretStore `aws-parameter-store` and the operator are in [`platform/security`](../../security). Run the seed script before the first sync: until a parameter exists its ExternalSecret is Degraded and the Application retries. Nothing here has run on a cluster or against AWS; `make external-secrets-check` compares both modes with [`scripts/secrets/contract.yaml`](../../../scripts/secrets/contract.yaml).
