# rabbitmq

The platform message broker, declared as a `RabbitmqCluster` for the RabbitMQ Cluster Operator ([`rabbitmq-operator`](../rabbitmq-operator)). Separate chart because the resource needs the operator's CRD and webhooks first.

- **Name and endpoints:** `platform-mq`; AMQP `platform-mq.data.svc:5672`, management UI on `:15672` (cluster-internal; use a port-forward). The operator creates the credentials in the Secret `platform-mq-default-user` (`username`, `password`).
- **Profiles:** `values.yaml` (+ `values-standard.yaml`) is one replica, 2 GiB, 200m / 512Mi requests, 1 CPU / 1Gi limits. `values-ha.yaml` is three replicas, 10 GiB, `pause_minority` partition handling, a PodDisruptionBudget (`maxUnavailable: 1`) and required spread across nodes (three nodes needed). Use quorum queues for replicated queues.
- **Security:** the operator's pods run as a fixed non-root user; RabbitMQ needs a writable root filesystem, so this workload is why the `data` namespace enforces `baseline` rather than `restricted` (see [`namespaces`](../namespaces)).
- **Volumes:** the resource carries `Prune=false` and `Delete=false`; volumes are removed deliberately in the teardown runbook.
- **Kafka** is the alternative considered; see [ADR-0014](../../../docs/adr/0014-data-layer.md).

## Two modes

**Generated (the default)**: the RabbitMQ Cluster Operator generates the default user and the Secret `platform-mq-default-user`.

**External**: the RabbitmqCluster has `spec.secretBackend.externalSecret.name: platform-mq-default-user`, so the operator generates none, and an ExternalSecret makes that Secret in `data` from the parameters `rabbitmq/default-username` and `rabbitmq/default-password`. It has the keys `default_user.conf` (the broker's default user and password), `username` and `password`. Per the operator's documentation (2.23.1) the StatefulSet waits until the Secret exists. The operator's example also lists `host`, `port`, `provider` and `type`; nothing reads them from this Secret, so they are left out. [`rabbitmq-credentials`](../rabbitmq-credentials) makes `rabbitmq-auth` for the services from the same parameters.

The mode is chosen per cluster. The ApplicationSet passes `externalSecrets.enabled` from the cluster Secret label `platform.example/external-secrets` (off when the label is absent) and `externalSecrets.prefix` from the annotation `platform.example/secrets-prefix` (for example `/multi-cloud-sre/dev`); `scripts/bootstrap-argocd.sh --enable-external-secrets` sets both. The default is off, so a cluster without AWS behaves as it always did. With the mode on the chart refuses to render without the prefix.

The values are in AWS Systems Manager Parameter Store as SecureString parameters, written by `scripts/seed-secrets.sh` from [`scripts/secrets/manifest.yaml`](../../../scripts/secrets/manifest.yaml); they never pass through Git, Argo CD parameters or Terraform. The ClusterSecretStore `aws-parameter-store` and the operator are in [`platform/security`](../../security). Run the seed script before the first sync: until a parameter exists its ExternalSecret is Degraded and the Application retries. Nothing here has run on a cluster or against AWS; `make external-secrets-check` compares both modes with [`scripts/secrets/contract.yaml`](../../../scripts/secrets/contract.yaml).

RabbitMQ stays a single instance in the standard profile.
