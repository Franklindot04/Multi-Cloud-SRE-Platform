# Data layer

GitOps-ready definitions of the platform's data components: **PostgreSQL**, a **Redis-compatible cache** and a **message broker**, plus the namespaces, storage class and in-cluster credential generation they need. Argo CD deploys them from this directory to clusters labelled `platform.example/data=true` (off by default). **Nothing is installed by these definitions themselves, and the application services are not changed or wired to them yet.** Design rationale is in [ADR-0014](../../docs/adr/0014-data-layer.md); operations are in the [data layer runbook](../../docs/runbooks/data-layer.md).

## Components, versions and findings

Checked on **2026-10-27** against each project's chart repository, release page and repository.

| Component | Pinned | Source | Licence | Maintenance |
| --- | --- | --- | --- | --- |
| CloudNativePG operator | chart `cloudnative-pg` **0.29.1**, operator **1.30.1** (released 2026-09-23) | `https://cloudnative-pg.github.io/charts` | Apache-2.0 | Active (commits within a day of the check); a CNCF project |
| PostgreSQL image | `ghcr.io/cloudnative-pg/postgresql:18.6-minimal-trixie` | CloudNativePG project images | PostgreSQL licence | Rebuilt by the project for every PostgreSQL release |
| Valkey | chart `valkey` **0.12.0**, Valkey **9.1.2** (9.1.3 was released a day before the check; the chart lags by one patch) | official `valkey-io/valkey-helm`, `https://valkey.io/valkey-helm/` | BSD-3-Clause | Active (charts released on 2026-10-23, Valkey commits within hours); a Linux Foundation project |
| RabbitMQ Cluster Operator | **2.23.1** (released 2026-10-13), vendored release manifest | `github.com/rabbitmq/cluster-operator` releases | MPL-2.0 | Active (commits within a day) |
| RabbitMQ | `rabbitmq:4.4.0-management` | Docker Official Image | MPL-2.0 | Maintained by the RabbitMQ team |

### What was found, and what followed

- **Redis versus Valkey.** Redis Open Source since version 8 is offered under a tri-licence (RSALv2, SSPLv1 or AGPLv3), none of which is a permissive open-source licence; Redis 7.4 moved to RSALv2/SSPLv1. Valkey is the Linux Foundation fork under BSD-3-Clause, API-compatible, actively released, and has an official Helm chart with ACL authentication from an existing Secret. **Valkey is used.**
- **RabbitMQ has no official Helm chart.** The supported install is the operator's release manifest, so the exact release manifest is vendored (with its checksum) in [`rabbitmq-operator`](rabbitmq-operator). The only chart is the Bitnami `rabbitmq-cluster-operator` (4.4.34), which is stale (operator 2.16.1) and references images from the Bitnami Debian 12 catalogue that Bitnami has moved to a legacy registry, so it is **not used**.
- **The RabbitMQ operator depends on cert-manager** (its manifest creates an `Issuer` and `Certificate` for its webhooks), which the baseline add-ons already provide.
- **Schemas for the custom resources exist** for CloudNativePG (`Cluster`, `Database`) and RabbitMQ (`RabbitmqCluster`) in the pinned `datreeio/CRDs-catalog` commit `3eb90d47`, so they are validated strictly (see below).

## Layout

| Directory | Kind | Purpose |
| --- | --- | --- |
| [`namespaces`](namespaces) | local chart | Namespaces `data` and `shop` with Pod Security labels |
| [`storage`](storage) | local chart | StorageClass `platform-data` (EBS gp3 on EKS, Persistent Disk balanced on GKE) |
| [`secrets`](secrets) | local chart | In-cluster generation of credentials (a PreSync hook Job) |
| [`cloudnative-pg`](cloudnative-pg) | wrapper chart | The PostgreSQL operator |
| [`postgres`](postgres) | local chart | The PostgreSQL `Cluster` and `Database` resources |
| [`valkey`](valkey) | wrapper chart | The cache, from the official chart |
| [`rabbitmq-operator`](rabbitmq-operator) | vendored manifest | The RabbitMQ Cluster Operator release manifest |
| [`rabbitmq`](rabbitmq) | local chart | The `RabbitmqCluster` resource |

**Operators and their custom resources are separate charts.** The custom resources need the operator's CRDs and webhooks, so they sync afterwards (Argo CD sync waves, `SkipDryRunOnMissingResource` and retries with backoff) and can be upgraded and rolled back independently. Wrapper charts with committed `Chart.lock` files are used for upstream charts, as for the add-ons.

Profiles are values files: `values.yaml` (shared, the standard profile) + `values-standard.yaml`, or + `values-ha.yaml`. The profile comes from the cluster label `platform.example/data-profile` (`standard` by default).

| Component | Standard (non-production) | HA |
| --- | --- | --- |
| PostgreSQL | 1 instance, 5 GiB, 250m / 512Mi requests | 3 instances on separate nodes, 20 GiB, 500m / 1Gi |
| Valkey | 1 pod, 1 GiB, `maxmemory` 128mb | primary and 2 replicas with a disruption budget, 2 GiB each |
| RabbitMQ | 1 replica, 2 GiB, 200m / 512Mi | 3 replicas, 10 GiB, disruption budget, `pause_minority` |

The HA profiles need at least three schedulable nodes. The standard profile fits the two Spot nodes (2 vCPU and 8 GiB each) with room to spare: the whole data layer requests about 0.75 vCPU and 1.7 GiB of memory, including the two operators.

## Namespaces and Pod Security

| Namespace | Holds | Pod Security |
| --- | --- | --- |
| `data` | PostgreSQL, Valkey, RabbitMQ | **enforce `baseline`**, warn and audit `restricted` |
| `shop` | the application services (next change) | enforce `restricted` |
| `cnpg-system` | CloudNativePG operator | enforce `restricted` |
| `rabbitmq-system` | RabbitMQ Cluster Operator | not labelled (created by the vendored manifest) |

`baseline` is the strictest level that the `data` namespace allows today: the RabbitMQ pods are created by the operator, whose pod spec is not documented as `restricted`-compliant, and the broker writes to its root filesystem. PostgreSQL and Valkey meet `restricted`. Because `warn` and `audit` are `restricted`, the first deployment shows exactly which pods would fail it; tighten `data` once those warnings are clean.

## Database design and credentials

One PostgreSQL cluster (`platform-pg`, read-write service `platform-pg-rw.data.svc:5432`) with **a database and a login role per service**, created declaratively: `orders` and `payments`. The operator creates them from `spec.managed.roles` and `Database` resources.

**No credential is ever committed.** Passwords are generated inside the cluster by the [`secrets`](secrets) chart's hook Job, once, and never modified afterwards. The conventions the services consume:

| Secret | Namespace | Keys | Used by |
| --- | --- | --- | --- |
| `orders-db` | `shop` | `username`, `password`, `host`, `port`, `dbname` | orders service |
| `payments-db` | `shop` | `username`, `password`, `host`, `port`, `dbname` | payments service |
| `cache-auth` | `shop` | `password`, `host`, `port` | services using the cache |
| `pg-orders`, `pg-payments` | `data` | `username`, `password` (type `basic-auth`) | the operator (role passwords) |
| `valkey-auth` | `data` | `default` | the Valkey chart |
| `platform-mq-default-user` | `data` | `username`, `password` (created by the RabbitMQ operator) | RabbitMQ; copied to `shop` by the next change |

This in-cluster generation is the interim mechanism. It is replaced by external secrets management later (ADR-0014): External Secrets would produce the same Secret names and keys from the cloud's secret manager, so consumers do not change.

## Storage and volume lifecycle

Every data component uses the StorageClass `platform-data`, so the charts are identical on both clouds. `reclaimPolicy: Delete` removes the cloud disk when its claim is deleted. **The volumes are not managed by Terraform and are not removed by `terraform destroy`; they keep billing until the claims are deleted.** To keep Argo CD from deleting data, the `Cluster`, `RabbitmqCluster`, the Valkey claim, the namespaces and the StorageClass carry `Prune=false,Delete=false`, so neither pruning nor deleting the Application removes them. Deleting them is a deliberate teardown step.

## Backups

**There are no backups yet.** They arrive with the disaster recovery change. Today the data is protected only by volume encryption and, in the HA profiles, replication; the standard profile loses data if its disk or node is lost. See ADR-0014 for what is and is not protected.

## Checks

```bash
make data-check-manifests
```

Runs `helm lint --strict`, `helm template` and `kubeconform` for every chart and cloud with the standard profile as the base and the HA profile as an extra render; verifies the vendored RabbitMQ manifest against its SHA-256; validates the CloudNativePG `Cluster` and `Database` and the `RabbitmqCluster` strictly against CRD schemas from the pinned catalog commit; validates the local compose file; runs `yamllint` and `shellcheck`. Local development: `make data-up`, `make data-check`, `make data-down` (see the runbook).
