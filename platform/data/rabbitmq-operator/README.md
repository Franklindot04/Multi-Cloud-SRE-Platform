# rabbitmq-operator

The official RabbitMQ Cluster Operator, deployed as the **unmodified release manifest**.

| | |
| --- | --- |
| Version | 2.23.1 (released 2026-10-13) |
| Source | `https://github.com/rabbitmq/cluster-operator/releases/download/v2.23.1/cluster-operator.yml` |
| SHA-256 | `ae35a547751656bc64bb734026249a845d226d96aba5a73783e05c5ec3444687` (also in `cluster-operator.yml.sha256`, verified by `make data-check-manifests`) |
| Licence | MPL-2.0 |
| Operator image | `ghcr.io/rabbitmq/cluster-operator:2.23.1` |

## Why a vendored manifest and not a chart

RabbitMQ publishes no Helm chart for the operator; the supported install is this manifest. The only chart is the Bitnami `rabbitmq-cluster-operator`, which is stale (operator 2.16.1, seven releases behind) and ships images from the Bitnami Debian 12 catalogue that Bitnami has moved out of its free registry, so it is not used. Vendoring the exact release keeps the deployment pinned, reviewable and checkable offline. Argo CD applies the directory as plain manifests with server-side apply (the CRD is large).

## What it contains

Namespace `rabbitmq-system`, the `RabbitmqCluster` CRD, RBAC, the operator Deployment (runs as non-root with a `RuntimeDefault` seccomp profile and 200m CPU and 500Mi memory), and mutating and validating webhooks whose certificates come from cert-manager (a self-signed `Issuer` and `Certificate` in the manifest). **cert-manager must therefore be installed first**, which the add-on ordering already guarantees.

## Updating

Download the new release's `cluster-operator.yml`, replace the file, update the checksum file and the table above, review the diff for new permissions and CRD changes, and run `make data-check-manifests`.
