# secrets

The Secret `grafana-admin` in the `observability` namespace (`admin-user`, `admin-password`), which Grafana reads through `admin.existingSecret` in [`kube-prometheus-stack`](../kube-prometheus-stack).

## Two modes

**Generated (the default)**: a Job run as an Argo CD Sync hook makes the Secret once, with a random password, and never changes an existing one.

**External**: an ExternalSecret makes the same Secret (same name, namespace and keys) with `admin-user` fixed to `admin` and `admin-password` read from the parameter `grafana/admin-password`. The generator Job, its ServiceAccount, Role and RoleBinding and the ConfigMap that lists the names are **not** rendered, and no Secret with a value is.

The mode is chosen per cluster. The ApplicationSet passes `externalSecrets.enabled` from the cluster Secret label `platform.example/external-secrets` (off when the label is absent) and `externalSecrets.prefix` from the annotation `platform.example/secrets-prefix` (for example `/multi-cloud-sre/dev`); `scripts/bootstrap-argocd.sh --enable-external-secrets` sets both. The default is off, so a cluster without AWS behaves as it always did. With the mode on the chart refuses to render without the prefix.

The values are in AWS Systems Manager Parameter Store as SecureString parameters, written by `scripts/seed-secrets.sh` from [`scripts/secrets/manifest.yaml`](../../../scripts/secrets/manifest.yaml); they never pass through Git, Argo CD parameters or Terraform. The ClusterSecretStore `aws-parameter-store` and the operator are in [`platform/security`](../../security). Run the seed script before the first sync: until a parameter exists its ExternalSecret is Degraded and the Application retries. Nothing here has run on a cluster or against AWS; `make external-secrets-check` compares both modes with [`scripts/secrets/contract.yaml`](../../../scripts/secrets/contract.yaml).
