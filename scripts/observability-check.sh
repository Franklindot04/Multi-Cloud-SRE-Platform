#!/usr/bin/env bash
# Offline checks for the metrics foundation under platform/observability and its Argo CD definitions.
#
#   1. helm lint, helm template and kubeconform for every chart and cloud (scripts/addons-check.sh), including the
#      optional persistent-volume values of the stack, plus yamllint; custom resources (Prometheus, ServiceMonitor,
#      PodMonitor) are validated against CRD schemas from a pinned commit of the datreeio CRDs-catalog
#   2. the Prometheus Operator CRDs the stack renders are present and well formed, and the Application syncs them with
#      ServerSideApply=true (kubeconform has no schema for the CustomResourceDefinition kind, so addons-check skips it)
#   3. the vendored chart is pinned: Chart.lock matches Chart.yaml, and the downloaded tarball matches the lock
#   4. contracts that a schema check cannot see (scripts/chart-contract-check.py), on the default render of each chart:
#        - the stack, the secrets chart and the collector meet the restricted Pod Security level that the
#          observability namespace enforces (node-exporter would not, which is why it is off)
#        - no persistent volume, Alertmanager, Ingress, LoadBalancer or NodePort in the default profile, and the
#          persistent values really switch the volumes on
#        - Grafana reads its admin account from the Secret grafana-admin and no password is rendered anywhere
#        - the collector image is pinned by digest
#        - the secrets chart renders an ordinary resource and its Job is not a Helm hook
#        - everything every chart renders is allowed by the platform-observability AppProject
#        - every Grafana dashboard is valid JSON with a unique uid and title, uses the data source variable and no
#          fixed data source uid, is held by a ConfigMap that carries the label the Grafana sidecar selects, and
#          uses only metric names confirmed in the service code, the vendored CloudNativePG chart, the vendored
#          stack chart or platform/observability/dashboards/confirmed-upstream.txt
#   5. the OpenTelemetry Collector configuration passes `validate` of the pinned image (needs a running Docker; the
#      image is pulled by digest)
#   6. shellcheck on the scripts, through scripts/shellcheck.sh (same flags and version as CI)
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

root="platform/observability"
project="platform/argocd/bootstrap/appproject-platform-observability.yaml"
namespace="observability"
stack="$root/kube-prometheus-stack"

# --- 1. charts and yamllint ---

echo "==> charts"
./scripts/addons-check.sh "$root" || status=1

if ! have helm; then
  echo "helm not installed; skipping the CRD, pinning, contract and collector checks"
  echo "==> shellcheck"
  ./scripts/shellcheck.sh || status=1
  exit "$status"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export HELM_CONFIG_HOME="$work/config" HELM_CACHE_HOME="$work/cache" HELM_DATA_HOME="$work/data"

# The tarballs under charts/ are downloaded, not committed; fetch them from the pinned lock files.
build_dependencies() {
  local dir="$1" repo
  grep -q '^dependencies:' "$dir/Chart.yaml" || return 0
  while IFS= read -r repo; do
    helm repo add "r$(printf '%s' "$repo" | cksum | cut -d' ' -f1)" "$repo" > /dev/null
  done < <(sed -n 's/^ *repository: *//p' "$dir/Chart.yaml")
  helm dependency build "$dir" > /dev/null
}
build_dependencies "$stack" || status=1
# The dashboards are checked against the metric names in the vendored CloudNativePG chart, so that one is fetched too.
build_dependencies "platform/data/cloudnative-pg" || status=1

# --- 2. the operator's CRDs ---

# kubeconform has no schema for the CustomResourceDefinition kind (neither the default location nor the catalog has
# one), so addons-check skips it. The CRDs the stack renders are checked here instead, by scripts/chart-contract-check.py
# crds: the ones the platform relies on exist, each has one storage version and a schema, and the Application that
# deploys them syncs with ServerSideApply=true. The custom resources themselves (Prometheus, ServiceMonitor, PodMonitor)
# are validated against the catalog schemas in step 1.
echo "==> Prometheus Operator CRDs"
crd_py="$(./scripts/python-with-yaml.sh)" || crd_py=""
if [ -z "$crd_py" ]; then
  echo "no Python with PyYAML found (installing yamllint provides it); the CRD check fails without it"
  status=1
else
  helm template kube-prometheus-stack "$stack" --namespace "$namespace" -f "$stack/values.yaml" --include-crds > "$work/stack-crds.yaml" || status=1
  echo "    the stack renders $(grep -c '^kind: CustomResourceDefinition$' "$work/stack-crds.yaml" || true) CRDs"
  "$crd_py" scripts/chart-contract-check.py crds kube-prometheus-stack platform/argocd/apps/91-observability-stack.yaml < "$work/stack-crds.yaml" || status=1
fi

# --- 3. the pinned chart ---

echo "==> vendored chart pinning"
if [ -f "$stack/Chart.lock" ]; then
  want="$(sed -n 's/^    version: *//p' "$stack/Chart.yaml")"
  have_lock="$(sed -n 's/^  version: *//p' "$stack/Chart.lock")"
  if [ "$want" = "$have_lock" ] && [ -n "$want" ]; then
    echo "    Chart.yaml and Chart.lock both pin kube-prometheus-stack $want"
  else
    echo "    FAIL Chart.yaml pins '$want' but Chart.lock has '$have_lock'; run helm dependency update"
    status=1
  fi
  if [ -f "$stack/charts/kube-prometheus-stack-$want.tgz" ]; then
    echo "    the downloaded tarball is kube-prometheus-stack-$want.tgz"
  else
    echo "    FAIL charts/kube-prometheus-stack-$want.tgz is missing after helm dependency build"
    status=1
  fi
  if helm dependency list "$stack" | awk 'NR > 1 && NF > 0 && $NF != "ok" { bad = 1 } END { exit bad }'; then
    echo "    helm dependency list reports every dependency as ok"
  else
    echo "    FAIL helm dependency list reports a dependency that is not ok"
    helm dependency list "$stack"
    status=1
  fi
else
  echo "    FAIL $stack/Chart.lock is missing"
  status=1
fi

# --- 4. contracts ---

echo "==> chart contracts"
contract_py="$(./scripts/python-with-yaml.sh)" || contract_py=""
if [ -z "$contract_py" ]; then
  echo "no Python with PyYAML found (installing yamllint provides it); the contract checks fail without it"
  status=1
else
  contract() {
    # contract CHECK LABEL FILE [EXTRA...]: run one check on a rendered file and count it.
    local check="$1" label="$2" file="$3"
    shift 3
    contracts=$((contracts + 1))
    "$contract_py" scripts/chart-contract-check.py "$check" "$label" "$@" < "$file" || status=1
  }
  contracts=0
  render() {
    # render NAME DIR [HELM ARGS...] > file
    local name="$1" dir="$2"
    shift 2
    helm template "$name" "$dir" --namespace "$namespace" "$@"
  }

  render kube-prometheus-stack "$stack" -f "$stack/values.yaml" --include-crds > "$work/stack.yaml" || status=1
  render kube-prometheus-stack "$stack" -f "$stack/values.yaml" -f "$stack/values-persistent.yaml" --include-crds > "$work/stack-persistent.yaml" || status=1
  render observability-secrets "$root/secrets" > "$work/secrets.yaml" || status=1
  render otel-collector "$root/otel-collector" > "$work/collector.yaml" || status=1
  render observability-monitors "$root/monitors" > "$work/monitors.yaml" || status=1

  for check in restricted ephemeral grafana-admin; do contract "$check" "kube-prometheus-stack" "$work/stack.yaml"; done
  contract project-fit "kube-prometheus-stack" "$work/stack.yaml" "$project" "$namespace"
  contract restricted "kube-prometheus-stack + values-persistent.yaml" "$work/stack-persistent.yaml"
  contract grafana-admin "kube-prometheus-stack + values-persistent.yaml" "$work/stack-persistent.yaml"
  contract project-fit "kube-prometheus-stack + values-persistent.yaml" "$work/stack-persistent.yaml" "$project" "$namespace"
  # The persistent values must switch the volumes on, or the documented option does nothing.
  if "$contract_py" scripts/chart-contract-check.py ephemeral persistent < "$work/stack-persistent.yaml" > /dev/null; then
    echo "    FAIL values-persistent.yaml does not render any persistent storage"
    status=1
  fi
  contracts=$((contracts + 1))

  contract hooks "observability-secrets" "$work/secrets.yaml"
  contract secret-jobs "observability-secrets" "$work/secrets.yaml"
  contract restricted "observability-secrets" "$work/secrets.yaml"
  contract project-fit "observability-secrets" "$work/secrets.yaml" "$project" "$namespace"

  for check in restricted ephemeral digest-pinned; do contract "$check" "otel-collector" "$work/collector.yaml"; done
  contract project-fit "otel-collector" "$work/collector.yaml" "$project" "$namespace"

  contract project-fit "observability-monitors" "$work/monitors.yaml" "$project" "$namespace"

  render observability-dashboards "$root/dashboards" > "$work/dashboards.yaml" || status=1
  contract project-fit "observability-dashboards" "$work/dashboards.yaml" "$project" "$namespace"
  cnpg_chart=""
  for f in platform/data/cloudnative-pg/charts/cloudnative-pg-*.tgz; do cnpg_chart="$f"; done
  if [ ! -f "$cnpg_chart" ]; then
    echo "    FAIL the vendored CloudNativePG chart tarball is missing, so the dashboards' metric names cannot be checked"
    status=1
  else
    contract dashboards "observability-dashboards" "$work/dashboards.yaml" "$root/dashboards/files" "$stack/values.yaml" \
      apps "$cnpg_chart" "$stack/charts/kube-prometheus-stack-$want.tgz" "$root/dashboards/confirmed-upstream.txt"
  fi
  echo "    ran $contracts contract check(s)"
fi

# --- 5. collector configuration ---

echo "==> OpenTelemetry Collector configuration"
if have docker && docker info > /dev/null 2>&1 && [ -n "$contract_py" ]; then
  collector="$root/otel-collector"
  image="$(helm template otel-collector "$collector" --namespace "$namespace" | sed -n 's/^ *image: *//p' | head -1)"
  mkdir -p "$work/collector-config"
  helm template otel-collector "$collector" --namespace "$namespace" -s templates/configmap.yaml \
    | "$contract_py" -c 'import sys, yaml; print(next(yaml.safe_load_all(sys.stdin))["data"]["config.yaml"], end="")' > "$work/collector-config/config.yaml"
  if docker run --rm -e MY_POD_IP=localhost -v "$work/collector-config:/etc/otelcol:ro" "$image" validate --config=/etc/otelcol/config.yaml > /dev/null 2> "$work/validate.err"; then
    echo "    the configuration is valid for $image"
  else
    echo "    FAIL the configuration is not valid for $image"
    cat "$work/validate.err"
    status=1
  fi
else
  echo "docker is not available; skipping the collector configuration check"
fi

# --- 6. shell scripts ---

echo "==> shellcheck"
./scripts/shellcheck.sh || status=1

exit "$status"
