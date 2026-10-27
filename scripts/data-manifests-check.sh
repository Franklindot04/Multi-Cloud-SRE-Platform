#!/usr/bin/env bash
# Offline checks for the data layer definitions under platform/data and its local compose file.
#
#   1. helm lint, helm template and kubeconform for every chart and cloud, with the standard profile as the
#      base and the HA profile as an extra render (scripts/addons-check.sh), plus yamllint
#   2. the vendored RabbitMQ Cluster Operator manifest still matches its recorded SHA-256, and passes
#      kubeconform
#   3. the custom resources (CloudNativePG Cluster and Database, RabbitmqCluster) are validated against CRD
#      schemas from a pinned commit of the datreeio CRDs-catalog
#   4. apps/docker-compose.data.yml is valid compose when given apps/.env.example
#   5. shellcheck on the scripts, through scripts/shellcheck.sh (same flags and version as CI)
#
# Tools that are not installed are skipped with a message. Nothing is installed in a cluster.
#
# Environment: see scripts/addons-check.sh (EKS_KUBERNETES_VERSION, GKE_KUBERNETES_VERSION, CRD_CATALOG_REF)
set -euo pipefail

case "${1:-}" in
  -h | --help)
    echo "Usage: $0"
    exit 0
    ;;
esac

cd "$(dirname "${BASH_SOURCE[0]}")/.."
have() { command -v "$1" > /dev/null 2>&1; }
status=0

# --- 1. charts, custom resources (CRD schemas are used by addons-check) and yamllint ---

echo "==> charts"
./scripts/addons-check.sh platform/data || status=1

# --- 2. vendored operator manifest ---

operator_dir="platform/data/rabbitmq-operator"
echo "==> vendored RabbitMQ operator manifest"
if have shasum; then
  (cd "$operator_dir" && shasum -a 256 -c cluster-operator.yml.sha256) || status=1
elif have sha256sum; then
  (cd "$operator_dir" && sha256sum -c cluster-operator.yml.sha256) || status=1
else
  echo "neither shasum nor sha256sum installed; skipping the checksum"
fi

if have kubeconform; then
  catalog_ref="${CRD_CATALOG_REF:-3eb90d47aba8d61919d4419dd38301536e32a94b}"
  kubeconform -strict -summary -skip CustomResourceDefinition -kubernetes-version "${EKS_KUBERNETES_VERSION:-1.37.0}" \
    -schema-location default \
    -schema-location "https://raw.githubusercontent.com/datreeio/CRDs-catalog/${catalog_ref}/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
    "$operator_dir/cluster-operator.yml" || status=1
else
  echo "kubeconform not installed; skipping the operator manifest schema check"
fi

# --- 4. local compose file ---

echo "==> local compose file"
if have docker && docker compose version > /dev/null 2>&1; then
  docker compose -f apps/docker-compose.data.yml --env-file apps/.env.example config -q || status=1
  echo "apps/docker-compose.data.yml is valid"
else
  echo "docker compose not installed; skipping the compose file check"
fi

# --- 5. shell scripts ---

echo "==> shellcheck"
./scripts/shellcheck.sh || status=1

exit "$status"
