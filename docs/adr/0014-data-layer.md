# ADR-0014: Data layer

- Status: Accepted
- Date: 2026-10-27

## Context

The sample application keeps orders and payments in memory behind repository interfaces ([ADR-0013](0013-sample-application-design.md)). The next change wires the services to real PostgreSQL, a cache and a message broker. The platform runs on two small non-production clusters (two Spot nodes of 2 vCPU and 8 GiB on EKS), delivers everything through Argo CD ([ADR-0012](0012-argocd-hub-and-gitops-structure.md)), and avoids committing any identifier or credential to a public repository. This decision defines the data components and how they are deployed; the services are not changed here.

## Decision

In-cluster versus managed services

- The data layer runs **in the clusters, through operators**, for now. Reasons: cost (a managed database, cache and broker each carry a minimum monthly charge that is large next to spare capacity on nodes that are already paid for, and they are billed while the platform is idle), portability (the same operators, manifests and failure behaviour on EKS and GKE, where RDS, ElastiCache and Amazon MQ differ from Cloud SQL, Memorystore and Pub/Sub), and learning value (operating stateful workloads and their failure modes is part of what the platform demonstrates).
- The cost is operational burden: upgrades, backups, capacity and recovery are ours, and stateful workloads on small Spot nodes are fragile. **For production this changes:** either managed services behind the same Secret contract (the services only see a host, port and credentials), or the HA profiles on on-demand nodes with tested backups and restores. The decision is revisited with the disaster recovery change.

Components

- **PostgreSQL through CloudNativePG** (Apache-2.0, CNCF, active). It runs PostgreSQL declaratively (clusters, databases and roles as resources), handles replication and failover, and keeps PostgreSQL itself unmodified. The standard profile is one instance; the HA profile is three instances on separate nodes.
- **Valkey** (BSD-3-Clause, Linux Foundation) for the Redis-compatible cache. Redis Open Source is now offered only under RSALv2, SSPLv1 or AGPLv3 (Redis 8 added AGPLv3 to the source-available licences), which carries obligations a permissively licensed platform repository should avoid. Valkey is wire-compatible, actively released and has an official chart with ACL authentication from an existing Secret. The chart replicates but has no automatic failover; the cache is not authoritative, so that is acceptable. The official chart is used; the Bitnami charts are not.
- **RabbitMQ through its official Cluster Operator** (MPL-2.0). RabbitMQ publishes no Helm chart; the supported install is the release manifest, so the exact release is vendored with a checksum rather than using the stale Bitnami chart (operator 2.16.1, images moved to a legacy registry). The standard profile is one replica; HA is three with quorum queues.
- **Kafka was considered and not chosen now.** The workload is task-style messaging (an order event consumed by the notifier) that needs queues, acknowledgements and retries, not an ordered replayable log, stream processing or very high throughput. Kafka (for example through Strimzi) would need several brokers and controllers, far more memory than two small nodes offer, and more operational depth for no present benefit. It remains the choice if event replay or analytics consumers appear.

One cluster, many databases

- A single PostgreSQL cluster hosts one database and one login role per service (`orders`, `payments`), created declaratively. This keeps resource use low on small nodes while preserving isolation at the database level: each service has its own credentials and the roles cannot connect to each other's database. It does not isolate failure or load between services; separating clusters later is a values change plus new roles, because the contract is a Secret with host, port and database name.

Credential handling and the path to external secrets

- **No credential is committed or passed through Git, Argo CD parameters or Terraform.** A Job run by Argo CD during the sync (an Argo CD Sync hook; see [ADR-0018](0018-secret-generation-and-ordering.md)) generates random passwords inside the cluster, once, and creates the Secrets only if they do not exist (never overwriting them). The services read Secrets in the `shop` namespace with a documented, stable shape (`orders-db`, `payments-db`, `cache-auth`). RabbitMQ and CloudNativePG-managed credentials follow the same idea.
- The interim has known limits: it does not rotate, and the password exists as a Kubernetes Secret (base64, not encrypted beyond the cluster's own encryption at rest). The path forward is External Secrets Operator reading the cloud's secret manager and producing the same Secret names and keys, after which the generator is removed and consumers do not change. Rotation then becomes a secret-manager operation plus role password updates by the operator.

Ordering, hooks and teardown (revised by [ADR-0018](0018-secret-generation-and-ordering.md))

- The first run on a real cluster showed that a chart containing only hooks never syncs under Argo CD, so the credential charts now render ordinary RBAC resources next to the Sync hook Job, and a check fails if a data chart renders only hooks or a Job that creates Secrets is a Helm hook.
- Sync waves order resources inside one Application and do not make one Application wait for another. The data waves (secrets 6, then PostgreSQL, Valkey and RabbitMQ 7, then the credential copy 8) state the intended order, and the consumers enforce what they need: a PreSync gate in the PostgreSQL chart holds back the `Cluster` until the role Secrets exist. In the real run the managed roles stayed pending for about 17 minutes after the Secrets appeared and needed a manual nudge; that could not be reproduced locally, so the gate is the primary fix and the annotation nudge a fallback.
- Teardown starts by deleting the `platform.example/apps` and `platform.example/data` labels from the cluster Secret, deletes the kept `Cluster`, `RabbitmqCluster`, RabbitMQ StatefulSet and claims explicitly, and `scripts/teardown-prep.sh` automates the sequence with waits.

Storage and volume lifecycle

- One StorageClass `platform-data` per cloud (EBS gp3 encrypted, Persistent Disk balanced), so charts do not vary by cloud, with `reclaimPolicy: Delete` and `WaitForFirstConsumer`.
- **Volumes are created by the cluster, not Terraform, and survive `terraform destroy`**, continuing to bill. To make data loss deliberate, Argo CD never prunes or deletes the database resources, claims, namespaces or storage class (`Prune=false,Delete=false`), automated pruning is last, and the teardown runbook makes deleting every claim in the data namespace and confirming the cloud volumes are gone a required step before destroying the cluster.

Pod Security and sizing

- The `data` namespace enforces `baseline` and warns and audits `restricted`, because the operator-created RabbitMQ pods are not documented as `restricted`-compliant; PostgreSQL and Valkey meet `restricted`. The `shop` namespace for the services enforces `restricted`. Sizes are modest (whole data layer about 0.75 vCPU and 1.7 GiB requested), with HA profiles ready for three nodes.

Backups and what is protected today

- **Backups are deferred to the disaster recovery change.** Today: volumes are encrypted at rest; the HA profiles replicate across instances and nodes; nothing protects against deletion, corruption or loss of the standard profile's single volume, and there are no snapshots, no point-in-time recovery and no tested restore. The cache is disposable by design. The data is treated as non-production and re-creatable.

Deferred

- Backups and restore tests; wiring the services to the data layer; per-service RabbitMQ users and permissions through the Messaging Topology Operator; connection pooling (PgBouncer); metrics and alerts for the data components (with the observability work); network policies between namespaces; TLS for in-cluster connections; External Secrets.

## Consequences

- Both clouds get the same data platform at the marginal cost of existing node capacity, and the contract the services see (Secrets in `shop`) is independent of how the data is hosted.
- Stateful workloads share small Spot nodes with everything else, so interruptions and drains will hurt the standard profile until the HA profile or on-demand nodes are used.
- The vendored RabbitMQ manifest must be updated by hand, with a checksum and diff review.
- Leftover volumes are the main cost risk; the process and checks in the runbook exist for that reason.
- Credentials in Kubernetes Secrets are readable by anyone with Secret access to those namespaces until external secrets and tighter RBAC arrive.

## Alternatives considered

- Managed cloud databases, caches and brokers: less operational work and real durability, at a recurring cost and with different APIs per cloud; chosen for production only after a deliberate decision.
- Redis under its current licences, or the Bitnami Redis and RabbitMQ charts: licensing obligations and, for Bitnami, stale charts and images moved out of the free registry.
- A separate PostgreSQL cluster per service: better isolation, double the memory on small nodes.
- Passwords in Helm values or Git, even encrypted (sealed or SOPS): they would still put credential material in a public repository and require key management now.
- Generating Secrets with Helm `lookup` or random functions at render time: Argo CD renders without cluster access, so the values would change on every render.
- Kafka: see above.
