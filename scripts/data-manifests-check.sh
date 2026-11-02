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
#   6. contracts that a schema check cannot see (scripts/chart-contract-check.py): no chart renders only hook
#      resources, no Job that creates Secrets is a Helm hook, the PostgreSQL chart has its PreSync gate for the
#      role Secrets (the sync waves are checked by scripts/argocd-check.sh), the PostgreSQL cluster has one, two or three
#      instances as asked, with the instances kept off one node, asynchronous replication, switchover updates and the
#      operator's own disruption budgets, and every pod of the data layer has the priority class platform-addons-critical
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

# --- 6. contracts ---

echo "==> chart contracts"
contract_py="$(./scripts/python-with-yaml.sh)" || contract_py=""
if ! have helm; then
  echo "helm not installed; skipping the chart contract checks"
elif [ -z "$contract_py" ]; then
  echo "no Python with PyYAML found (installing yamllint provides it); the contract checks fail without it"
  status=1
else
  contract_work="$(mktemp -d)"
  export HELM_CONFIG_HOME="$contract_work/config" HELM_CACHE_HOME="$contract_work/cache" HELM_DATA_HOME="$contract_work/data"
  contracts=0
  for chart in platform/data/*/; do
    chart="${chart%/}"
    [ -f "$chart/Chart.yaml" ] || continue
    # Charts with dependencies need a network to build; the rule is about templates this repository owns.
    grep -q '^dependencies:' "$chart/Chart.yaml" && continue
    args=()
    [ ! -f "$chart/values-aws.yaml" ] || args+=(-f "$chart/values-aws.yaml")
    # Fixture values for what Argo CD supplies from the cluster secret (the VPC range of the network policies).
    [ ! -f "$chart/ci/aws-params.yaml" ] || args+=(-f "$chart/ci/aws-params.yaml")
    if ! helm template "$(basename "$chart")" "$chart" --namespace data ${args[@]+"${args[@]}"} > "$contract_work/render.yaml" 2> "$contract_work/render.err"; then
      echo "    FAIL [$chart] helm template"
      cat "$contract_work/render.err"
      status=1
      continue
    fi
    "$contract_py" scripts/chart-contract-check.py hooks "$chart" < "$contract_work/render.yaml" || status=1
    "$contract_py" scripts/chart-contract-check.py secret-jobs "$chart" < "$contract_work/render.yaml" || status=1
    if [ "$(basename "$chart")" = postgres ]; then
      "$contract_py" scripts/chart-contract-check.py postgres-gate "$chart" < "$contract_work/render.yaml" || status=1
    fi
    contracts=$((contracts + 1))
  done

  # PostgreSQL: two instances in the standard profile (a primary and an asynchronous replica), one when the value says so, three in the
  # high availability profile.
  pg=platform/data/postgres
  pg_render() { helm template postgres "$pg" --namespace data -f "$pg/values.yaml" -f "$pg/values-standard.yaml" "$@"; }
  pg_check() {
    local label="$1" want="$2"
    shift 2
    if pg_render "$@" > "$contract_work/pg.yaml" 2> "$contract_work/render.err"; then
      "$contract_py" scripts/chart-contract-check.py postgres-ha "$label" "$want" < "$contract_work/pg.yaml" || status=1
      contracts=$((contracts + 1))
    else
      echo "    FAIL [$label] helm template"
      cat "$contract_work/render.err"
      status=1
    fi
  }
  pg_check "postgres (standard profile)" 2
  pg_check "postgres (cluster.instances=1)" 1 --set cluster.instances=1
  pg_check "postgres (values-ha.yaml)" 3 -f "$pg/values-ha.yaml"
  if [ "$(helm template postgres "$pg" --namespace data -f "$pg/values.yaml" -f "$pg/values-standard.yaml" -f "$pg/values-ha.yaml" 2> /dev/null \
    | grep -c 'podAntiAffinityType: required')" != 1 ]; then
    echo "    FAIL the high availability profile does not require the instances to be on different nodes"
    status=1
  fi

  # The data layer ranks with the add-ons (platform-addons-critical), above the services (platform-apps). The RabbitMQ Cluster Operator
  # is a vendored manifest that is checked against a SHA-256 and cannot be given a class without changing it, so it is named as an exception.
  data_prio() {
    local label="$1" chart="$2"
    shift 2
    if helm template "$(basename "$chart")" "$chart" --namespace data -f "$chart/values.yaml" "$@" > "$contract_work/prio.yaml" 2> "$contract_work/render.err"; then
      "$contract_py" scripts/chart-contract-check.py priority "$label" platform-addons-critical < "$contract_work/prio.yaml" || status=1
      contracts=$((contracts + 1))
    else
      echo "    FAIL [$label] helm template"
      cat "$contract_work/render.err"
      status=1
    fi
  }
  data_prio "cloudnative-pg" platform/data/cloudnative-pg -f platform/data/cloudnative-pg/values-standard.yaml
  data_prio "postgres" "$pg" -f "$pg/values-standard.yaml"
  data_prio "postgres + values-ha.yaml" "$pg" -f "$pg/values-standard.yaml" -f "$pg/values-ha.yaml"
  data_prio "valkey" platform/data/valkey -f platform/data/valkey/values-standard.yaml
  data_prio "rabbitmq" platform/data/rabbitmq -f platform/data/rabbitmq/values-standard.yaml
  data_prio "data-secrets" platform/data/secrets
  data_prio "rabbitmq-credentials" platform/data/rabbitmq-credentials
  "$contract_py" scripts/chart-contract-check.py priority "rabbitmq-operator (vendored manifest)" platform-addons-critical \
    Deployment/rabbitmq-cluster-operator < platform/data/rabbitmq-operator/cluster-operator.yml || status=1

  rm -rf "$contract_work"
  echo "    checked $contracts chart(s)"
fi

# --- 5. shell scripts ---

echo "==> shellcheck"
./scripts/shellcheck.sh || status=1

exit "$status"
