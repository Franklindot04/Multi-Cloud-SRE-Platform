# rabbitmq-credentials

Copies the RabbitMQ default user credentials from the `data` namespace into the `shop` namespace so the services can read them, without committing or printing any credential.

A PreSync hook Job (sync wave 8, after the broker) reads the Secret `platform-mq-default-user` (created by the RabbitMQ Cluster Operator) and creates or patches `rabbitmq-auth` in `shop` with `username`, `password`, `host` and `port`. The values stay base64 encoded from one Secret to the other.

Permissions (all hooks, so they exist only while the Job runs, with no cluster-wide role):

| Where | Allowed |
| --- | --- |
| `data` | `get` on the Secret `platform-mq-default-user` only |
| `shop` | `get`, `update`, `patch` on the Secret `rabbitmq-auth` only, and `create` on Secrets |

Kubernetes RBAC cannot limit `create` to a name, so the Job could create other Secrets in `shop`, but it can read, change and delete none of them. If the source Secret does not exist yet the Job fails and is retried until its deadline (15 minutes). Re-sync the Application to propagate a changed source Secret.

Later this is replaced by External Secrets producing the same `rabbitmq-auth` from the cloud's secret manager ([ADR-0016](../../../docs/adr/0016-service-deployment-model.md)).
