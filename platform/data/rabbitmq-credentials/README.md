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
