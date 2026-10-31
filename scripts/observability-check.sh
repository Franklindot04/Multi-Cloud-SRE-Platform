#!/usr/bin/env bash
# Offline checks for the metrics and logging stack under platform/observability and its Argo CD definitions.
#
#   1. helm lint, helm template and kubeconform for every chart and cloud (scripts/addons-check.sh), including the
#      optional persistent-volume values of the stack, plus yamllint; custom resources (Prometheus, ServiceMonitor,
#      PodMonitor) are validated against CRD schemas from a pinned commit of the datreeio CRDs-catalog
#   2. the Prometheus Operator CRDs the stack renders are present and well formed, and the Application syncs them with
#      ServerSideApply=true (kubeconform has no schema for the CustomResourceDefinition kind, so addons-check skips it)
#   3. the vendored charts are pinned: Chart.lock matches Chart.yaml, and the downloaded tarball matches the lock
#   4. contracts that a schema check cannot see (scripts/chart-contract-check.py), on the default render of each chart:
#        - the stack, the secrets chart and the collector meet the restricted Pod Security level that the
#          observability namespace enforces (node-exporter would not, which is why it is off)
#        - no persistent volume, Alertmanager, Ingress, LoadBalancer or NodePort in the default profile, and the
#          persistent values really switch the volumes on
#        - Grafana reads its admin account from the Secret grafana-admin and no password is rendered anywhere
#        - the collector image is pinned by digest
#        - Loki is single tenant with the TSDB index (schema v13), filesystem storage and retention on; Alloy reads
#          logs only through the Kubernetes API from the shop and data namespaces, turns no log field into a label and
#          cannot read Secrets; both meet the restricted level, render no claim, hostPath volume or Ingress by default,
#          and values-persistent.yaml of Loki really switches its volume on
#        - the secrets chart renders an ordinary resource and its Job is not a Helm hook
#        - everything every chart renders is allowed by the platform-observability AppProject
#        - every Grafana dashboard is valid JSON with a unique uid and title, uses the data source variable and no
#          fixed data source uid, is held by a ConfigMap that carries the label the Grafana sidecar selects, and
#          uses only metric names confirmed in the service code, the vendored CloudNativePG chart, the vendored
#          stack chart or platform/observability/dashboards/confirmed-upstream.txt; Loki panels use only the log
#          stream labels and the level, and no selector can match the empty value
#   5. the OpenTelemetry Collector configuration passes `validate` of the pinned image, the Loki configuration passes
#      -verify-config and the Alloy configuration passes `validate` of the images the charts deploy, and the LogQL of
#      the dashboards is run against a Loki container with sample lines (JSON with a lower-case level, JSON with an
#      upper-case level, plain text) and must parse and return what is expected (needs a running Docker; the
#      collector image is pulled by digest, the other two by the tag the chart sets; the Loki container is removed
#      afterwards)
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
logql_container=""
trap 'rm -rf "$work"; [ -z "$logql_container" ] || docker rm -f "$logql_container" > /dev/null 2>&1 || true' EXIT
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
build_dependencies "$root/loki" || status=1
build_dependencies "$root/alloy" || status=1
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

for chart in loki alloy; do
  dir="$root/$chart"
  want_chart="$(sed -n 's/^    version: *//p' "$dir/Chart.yaml")"
  have_chart="$(sed -n 's/^  version: *//p' "$dir/Chart.lock" 2> /dev/null || true)"
  if [ -n "$want_chart" ] && [ "$want_chart" = "$have_chart" ]; then
    echo "    Chart.yaml and Chart.lock both pin $chart $want_chart"
  else
    echo "    FAIL $dir: Chart.yaml pins '$want_chart' but Chart.lock has '$have_chart'; run helm dependency update"
    status=1
  fi
  if [ ! -f "$dir/charts/$chart-$want_chart.tgz" ]; then
    echo "    FAIL $dir/charts/$chart-$want_chart.tgz is missing after helm dependency build"
    status=1
  fi
  if ! helm dependency list "$dir" | awk 'NR > 1 && NF > 0 && $NF != "ok" { bad = 1 } END { exit bad }'; then
    echo "    FAIL helm dependency list reports a dependency of $dir that is not ok"
    status=1
  fi
done

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

  render loki "$root/loki" -f "$root/loki/values.yaml" > "$work/loki.yaml" || status=1
  render loki "$root/loki" -f "$root/loki/values.yaml" -f "$root/loki/values-persistent.yaml" > "$work/loki-persistent.yaml" || status=1
  render alloy "$root/alloy" -f "$root/alloy/values.yaml" > "$work/alloy.yaml" || status=1
  for check in restricted ephemeral loki; do contract "$check" "loki" "$work/loki.yaml"; done
  contract project-fit "loki" "$work/loki.yaml" "$project" "$namespace"
  for check in restricted loki; do contract "$check" "loki + values-persistent.yaml" "$work/loki-persistent.yaml"; done
  contract project-fit "loki + values-persistent.yaml" "$work/loki-persistent.yaml" "$project" "$namespace"
  # The persistent values must switch the volume on, or the documented option does nothing.
  if "$contract_py" scripts/chart-contract-check.py ephemeral persistent < "$work/loki-persistent.yaml" > /dev/null; then
    echo "    FAIL the Loki values-persistent.yaml does not render any persistent storage"
    status=1
  fi
  contracts=$((contracts + 1))
  for check in restricted ephemeral alloy; do contract "$check" "alloy" "$work/alloy.yaml"; done
  contract project-fit "alloy" "$work/alloy.yaml" "$project" "$namespace"

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

echo "==> Collector, Loki and Alloy configuration"
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
  # Loki and Alloy: the configuration the chart renders, checked by the image the chart deploys.
  loki_image="$(helm template loki "$root/loki" --namespace "$namespace" | sed -n 's/^ *image: *//p' | head -1)"
  mkdir -p "$work/loki-config"
  helm template loki "$root/loki" --namespace "$namespace" -s charts/loki/templates/config.yaml \
    | "$contract_py" -c 'import sys, yaml; print(next(yaml.safe_load_all(sys.stdin))["data"]["config.yaml"], end="")' > "$work/loki-config/config.yaml"
  if docker run --rm -v "$work/loki-config:/etc/loki/config:ro" "$loki_image" -config.file=/etc/loki/config/config.yaml -verify-config > /dev/null 2> "$work/loki-verify.err"; then
    echo "    the Loki configuration is valid for $loki_image"
  else
    echo "    FAIL the Loki configuration is not valid for $loki_image"
    cat "$work/loki-verify.err"
    status=1
  fi
  # The LogQL of the dashboards, run against that Loki with sample lines (scripts/logql-check.py).
  mkdir -p "$work/loki-runtime"
  : > "$work/loki-runtime/runtime-config.yaml"
  logql_container="observability-check-loki-$$"
  if docker run -d --rm --name "$logql_container" -p 127.0.0.1::3100 --tmpfs /var/loki:uid=10001 \
    -v "$work/loki-config:/etc/loki/config:ro" -v "$work/loki-runtime:/etc/loki/runtime-config:ro" \
    "$loki_image" -config.file=/etc/loki/config/config.yaml -target=all > /dev/null 2> "$work/logql.err"; then
    loki_port="$(docker port "$logql_container" 3100/tcp | head -1 | sed 's/.*://')"
    if "$contract_py" scripts/logql-check.py "http://127.0.0.1:$loki_port" "$root/dashboards/files" > "$work/logql.out" 2>&1; then
      echo "    the dashboards' LogQL parses and returns the expected lines on $loki_image"
      sed -n 's/^    ran /    ran /p' "$work/logql.out"
    else
      echo "    FAIL the dashboards' LogQL against $loki_image"
      cat "$work/logql.out"
      status=1
    fi
    docker rm -f "$logql_container" > /dev/null 2>&1 || true
    logql_container=""
  else
    echo "    FAIL could not start Loki to run the dashboards' LogQL"
    cat "$work/logql.err"
    logql_container=""
    status=1
  fi
  alloy_image="$(helm template alloy "$root/alloy" --namespace "$namespace" | sed -n 's/^ *image: *\(.*grafana\/alloy:.*\)$/\1/p' | head -1)"
  mkdir -p "$work/alloy-config"
  helm template alloy "$root/alloy" --namespace "$namespace" -s charts/alloy/templates/configmap.yaml \
    | "$contract_py" -c 'import sys, yaml; print(next(yaml.safe_load_all(sys.stdin))["data"]["config.alloy"], end="")' > "$work/alloy-config/config.alloy"
  if docker run --rm -v "$work/alloy-config:/cfg:ro" "$alloy_image" validate /cfg/config.alloy > /dev/null 2> "$work/alloy-validate.err"; then
    echo "    the Alloy configuration is valid for $alloy_image"
  else
    echo "    FAIL the Alloy configuration is not valid for $alloy_image"
    cat "$work/alloy-validate.err"
    status=1
  fi
else
  echo "docker is not available; skipping the collector, Loki and Alloy configuration checks"
fi

# --- 6. shell scripts ---

echo "==> shellcheck"
./scripts/shellcheck.sh || status=1

exit "$status"
