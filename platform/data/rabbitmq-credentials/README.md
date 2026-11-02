# rabbitmq-credentials

Copies the RabbitMQ default user credentials from the `data` namespace into the `shop` namespace so the services can read them, without committing or printing any credential.

A Job run as an Argo CD Sync hook (sync wave 8, after the broker) waits for, then reads the Secret `platform-mq-default-user` (created by the RabbitMQ Cluster Operator) and creates or patches `rabbitmq-auth` in `shop` with `username`, `password`, `host` and `port`. The values stay base64 encoded from one Secret to the other.

The ServiceAccount, Roles and RoleBindings are ordinary resources, so the Application always has something to sync ([ADR-0018](../../../docs/adr/0018-secret-generation-and-ordering.md)). Permissions (no cluster-wide role):

| Where | Allowed |
| --- | --- |
| `data` | `get` on the Secret `platform-mq-default-user` only |
| `shop` | `get`, `update`, `patch` on the Secret `rabbitmq-auth` only, and `create` on Secrets |

Kubernetes RBAC cannot limit `create` to a name, so the Job could create other Secrets in `shop`, but it can read, change and delete none of them. If the source Secret does not exist yet the Job waits for it inside the pod for up to 25 minutes (checking every ten seconds, without using its retries), then fails with a clear message and Argo CD retries the sync. Re-sync the Application to propagate a changed source Secret.

Later this is replaced by External Secrets producing the same `rabbitmq-auth` from the cloud's secret manager ([ADR-0016](../../../docs/adr/0016-service-deployment-model.md)).

Run again with an unchanged source, the Job leaves `rabbitmq-auth` as it is; if the operator changes its Secret, the copy follows it, because the operator owns that credential. `make deploy-check` fails if this chart renders only hooks or if the Job becomes a Helm hook.

## Two modes

**Copied (the default)** is what is described above: a Job copies the operator's default user into `shop`.

**External** renders one ExternalSecret that makes `rabbitmq-auth` in `shop` (`username`, `password`, `host`, `port`, as before) from the parameters `rabbitmq/default-username` and `rabbitmq/default-password`. The Job, its ServiceAccount, Roles and RoleBindings are **not** rendered, so the public `curl` image and the exempt label of the admission policies are not used. The broker starts with the same two parameters (see [`rabbitmq`](../rabbitmq)).

The mode is chosen per cluster. The ApplicationSet passes `externalSecrets.enabled` from the cluster Secret label `platform.example/external-secrets` (off when the label is absent) and `externalSecrets.prefix` from the annotation `platform.example/secrets-prefix` (for example `/multi-cloud-sre/dev`); `scripts/bootstrap-argocd.sh --enable-external-secrets` sets both. The default is off, so a cluster without AWS behaves as it always did. With the mode on the chart refuses to render without the prefix.

The values are in AWS Systems Manager Parameter Store as SecureString parameters, written by `scripts/seed-secrets.sh` from [`scripts/secrets/manifest.yaml`](../../../scripts/secrets/manifest.yaml); they never pass through Git, Argo CD parameters or Terraform. The ClusterSecretStore `aws-parameter-store` and the operator are in [`platform/security`](../../security). Run the seed script before the first sync: until a parameter exists its ExternalSecret is Degraded and the Application retries. Nothing here has run on a cluster or against AWS; `make external-secrets-check` compares both modes with [`scripts/secrets/contract.yaml`](../../../scripts/secrets/contract.yaml).
