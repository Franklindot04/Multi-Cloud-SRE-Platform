# valkey

A Redis-compatible cache using **Valkey**, through the official chart `valkey` 0.12.0 (Valkey 9.1.2) from `https://valkey.io/valkey-helm/`. The choice of Valkey over Redis is explained in [ADR-0014](../../../docs/adr/0014-data-layer.md).

- **Endpoint:** `platform-valkey.data.svc:6379`.
- **Authentication is enabled.** The `default` user's password is read from the Secret `valkey-auth` (key `default`) generated in the cluster by the [`secrets`](../secrets) chart; services read `cache-auth` in `shop`. No password is committed.
- **Cache semantics:** `maxmemory 128mb` with `allkeys-lru` eviction. The 1 GiB volume only preserves data across restarts.
- **Profiles:** standard is a single instance; `values-ha.yaml` runs a primary and two replicas with spread and a disruption budget. The chart replicates but does not fail over automatically.
- **Security:** non-root (UID 1000), read-only root filesystem, no privilege escalation, all capabilities dropped, `RuntimeDefault` seccomp: it meets the `restricted` Pod Security level.
- **Volumes:** the claim is annotated `Prune=false,Delete=false` and kept on uninstall (`keepPvc`); removed deliberately in the teardown runbook.
