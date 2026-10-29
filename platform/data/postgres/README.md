# postgres

The platform PostgreSQL cluster, declared as CloudNativePG resources in a **separate chart from the operator**, because the custom resources need the operator's CRDs and must sync after it (Argo CD sync waves, `SkipDryRunOnMissingResource` and retries).

- **One cluster, one database and role per service:** `orders` and `payments`, created declaratively (`Database` resources and `spec.managed.roles`). The cluster name is `platform-pg`; the read-write service is `platform-pg-rw.data.svc:5432`. A bootstrap database `platform` exists but is not used by services.
- **Credentials** are never in Git: the role passwords come from the Secrets `pg-orders` and `pg-payments` generated in the cluster by the [`secrets`](../secrets) chart. The services read `orders-db` / `payments-db` in `shop`.
- **Ordering:** a PreSync gate Job (`templates/gate.yaml`, values `gate.*`) waits until the role Secrets exist before the `Cluster` or the `Database` resources are applied, because a `Cluster` applied first leaves its managed roles `pending-reconciliation`. It is the primary protection; the annotation `platform.example/reconcile-nudge` on the `Cluster` is only a fallback for a cluster already in that state ([ADR-0018](../../../docs/adr/0018-secret-generation-and-ordering.md)). `make data-check-manifests` fails if the gate is missing.
- **Profiles:** `values.yaml` (+ `values-standard.yaml`) is one instance with 5 GiB; `values-ha.yaml` is three instances (required anti-affinity, so three nodes are needed), 20 GiB, larger limits.
- **Sizing (standard):** 250m / 512Mi requests, 1 CPU / 1Gi limits, `shared_buffers` 128MB.
- **Security:** CloudNativePG runs PostgreSQL as a non-root user with a read-only root filesystem, restricted-compatible. Superuser access is disabled (`enableSuperuserAccess: false`).
- **Disruption:** the operator manages a PodDisruptionBudget only when there is more than one instance (a budget on a single instance would block node drains).
- **Volumes:** the `Cluster` carries `Prune=false` and `Delete=false`, so neither automated pruning nor deleting the Argo CD Application removes the database or its volumes. They are removed deliberately in the teardown runbook.
- **Storage class:** `platform-data` (see [`storage`](../storage)).
