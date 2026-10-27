# rabbitmq

The platform message broker, declared as a `RabbitmqCluster` for the RabbitMQ Cluster Operator ([`rabbitmq-operator`](../rabbitmq-operator)). Separate chart because the resource needs the operator's CRD and webhooks first.

- **Name and endpoints:** `platform-mq`; AMQP `platform-mq.data.svc:5672`, management UI on `:15672` (cluster-internal; use a port-forward). The operator creates the credentials in the Secret `platform-mq-default-user` (`username`, `password`).
- **Profiles:** `values.yaml` (+ `values-standard.yaml`) is one replica, 2 GiB, 200m / 512Mi requests, 1 CPU / 1Gi limits. `values-ha.yaml` is three replicas, 10 GiB, `pause_minority` partition handling, a PodDisruptionBudget (`maxUnavailable: 1`) and required spread across nodes (three nodes needed). Use quorum queues for replicated queues.
- **Security:** the operator's pods run as a fixed non-root user; RabbitMQ needs a writable root filesystem, so this workload is why the `data` namespace enforces `baseline` rather than `restricted` (see [`namespaces`](../namespaces)).
- **Volumes:** the resource carries `Prune=false` and `Delete=false`; volumes are removed deliberately in the teardown runbook.
- **Kafka** is the alternative considered; see [ADR-0014](../../../docs/adr/0014-data-layer.md).
