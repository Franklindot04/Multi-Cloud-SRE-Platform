# cloudnative-pg

The CloudNativePG operator, which runs PostgreSQL clusters declared as `Cluster` resources (see [`postgres`](../postgres)). Wrapper around the official chart `cloudnative-pg` 0.29.1 (operator 1.30.1) from `https://cloudnative-pg.github.io/charts`.

- **Namespace:** `cnpg-system`, with Pod Security `restricted` enforced (the operator meets it).
- **Resources:** 50m / 128Mi requests, 250m / 256Mi limits; `platform-addons-critical` priority class.
- **HA:** `values-ha.yaml` runs two operator replicas.
- **CRDs:** installed by the chart; applied with server-side apply.
