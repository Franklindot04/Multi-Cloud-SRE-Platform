# secrets

Generates the data layer credentials **inside the cluster**, once, so no password is ever committed or passes through Git, Argo CD parameters or Terraform.

A pre-sync hook Job (the official `curl` image and the Kubernetes API, with a Role limited to `get` and `create` on Secrets in the two namespaces) creates each Secret only if it does not exist. Existing Secrets are never modified, so re-syncs do not rotate passwords. Passwords are 32 random alphanumeric characters.

| Secret | Namespace | Type and keys | Read by |
| --- | --- | --- | --- |
| `pg-orders`, `pg-payments` | `data` | `kubernetes.io/basic-auth`: `username`, `password` | CloudNativePG (database role passwords) |
| `valkey-auth` | `data` | `default` (the password of Valkey's `default` user) | the Valkey chart |
| `orders-db`, `payments-db` | `shop` | `username`, `password`, `host`, `port`, `dbname` | the orders and payments services |
| `cache-auth` | `shop` | `password`, `host`, `port` | the services that use the cache |

RabbitMQ credentials are created by the RabbitMQ Cluster Operator (`platform-mq-default-user` in `data`: `username`, `password`, `host`, `port`); the next change copies what the services need into `shop`.

The Job is the interim mechanism. When an external secrets manager is introduced, the same Secret names and keys are produced by External Secrets instead, so the consumers do not change (see [ADR-0014](../../../docs/adr/0014-data-layer.md)).
