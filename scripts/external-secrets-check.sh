#!/usr/bin/env bash
# Offline checks for the External Secrets Operator under platform/security (the operator, the ClusterSecretStore and the network
# policies of its namespace) and its Argo CD definitions.
#
#   1. helm lint, helm template and kubeconform for the three charts (scripts/addons-check.sh), plus yamllint
#   2. contracts that a schema check cannot see (scripts/chart-contract-check.py), on the rendered charts:
#      - restricted: every pod of the operator meets the restricted Pod Security level that the external-secrets namespace enforces
#      - external-secrets: the controller, the webhook and the certificate controller are the only workloads, each container has
#        requests and limits, together under 200m CPU and 300Mi of memory; the validating webhooks fail open (a dead operator cannot
#        block the cluster); the controller runs as the service account external-secrets (the one the IAM role trusts) and that
#        account carries the role annotation; no store and no ExternalSecret is rendered; metrics are on port 8080; the ApplicationSet
#        syncs with ServerSideApply=true because the CRDs are larger than client-side apply can store
#      - priority: every pod uses platform-addons-critical
#      - eso-store: one ClusterSecretStore aws-parameter-store of external-secrets.io/v1 for Parameter Store, signing in with the
#        service account of the operator, and no credential of any kind
#      - project-fit: everything rendered is allowed by the platform-addons AppProject, in the external-secrets namespace
#      - network-policies: the policies of the external-secrets namespace (the flows are checked by scripts/network-policies-check.sh)
#   3. the charts refuse to render without what Argo CD supplies from the cluster Secret: the role ARN, the region and the parameter path
#   4. the platform's credential charts (platform/data/secrets, rabbitmq, rabbitmq-credentials and platform/observability/secrets) in
#      both modes, against scripts/secrets/contract.yaml and the seed manifest (scripts/chart-contract-check.py):
#      - secrets-generated: in the default mode the generator Jobs make every Secret of the contract, with its keys, type and labels
#      - secrets-external: in external mode no Secret with a value, no Job that makes a Secret and no exempt label are rendered; every
#        ExternalSecret reads the store with a 1h refresh and creationPolicy Owner; every remote key is an entry of the seed manifest;
#        each Secret has the name, namespace, type, labels and keys of the contract; every manifest entry is read by one
#      - everything rendered in external mode is allowed by the AppProject that deploys the chart
#   5. the ServiceMonitor of the monitors chart selects the three metrics Services the operator creates
#   6. shellcheck on the scripts, through scripts/shellcheck.sh
#
# Helm and a network connection for the vendored chart (fetched from Chart.lock) are needed. Nothing is installed in a cluster.
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

root="platform/security"
operator="$root/external-secrets"
store="$root/external-secrets-store"
netpol="$root/external-secrets-network-policies"
project="platform/argocd/bootstrap/appproject-platform-addons.yaml"
operator_appset="platform/argocd/apps/87-eso-operator.yaml"
store_appset="platform/argocd/apps/88-eso-store.yaml"

echo "==> charts"
./scripts/addons-check.sh "$root" || status=1

if ! have helm; then
  echo "helm not installed; skipping the contract checks"
  ./scripts/shellcheck.sh || status=1
  exit "$status"
fi
py="$(./scripts/python-with-yaml.sh)" || {
  echo "no Python with PyYAML found (installing yamllint provides it); the contract checks fail without it"
  exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export HELM_CONFIG_HOME="$work/config" HELM_CACHE_HOME="$work/cache" HELM_DATA_HOME="$work/data"
helm repo add eso-check "$(sed -n 's/^ *repository: *//p' "$operator/Chart.yaml")" > /dev/null
helm dependency build "$operator" > /dev/null || status=1

echo "==> chart contracts"
contracts=0
contract() {
  # contract CHECK LABEL FILE [EXTRA...]
  local check="$1" label="$2" file="$3"
  shift 3
  contracts=$((contracts + 1))
  "$py" scripts/chart-contract-check.py "$check" "$label" "$@" < "$file" || status=1
}
helm template external-secrets "$operator" --namespace external-secrets -f "$operator/values.yaml" -f "$operator/ci/aws-params.yaml" --include-crds > "$work/operator.yaml" || status=1
helm template external-secrets-store "$store" --namespace external-secrets -f "$store/values.yaml" -f "$store/ci/aws-params.yaml" > "$work/store.yaml" || status=1
helm template eso-network-policies "$netpol" --namespace external-secrets -f "$netpol/values.yaml" -f "$netpol/ci/aws-params.yaml" > "$work/policies.yaml" || status=1

contract restricted "external-secrets" "$work/operator.yaml"
contract external-secrets "external-secrets" "$work/operator.yaml" "$operator_appset"
# Every pod ranks with the add-ons, above the services. The chart has no hook Job to leave out.
contract priority "external-secrets" "$work/operator.yaml" platform-addons-critical
contract project-fit "external-secrets" "$work/operator.yaml" "$project" external-secrets
contract eso-store "external-secrets-store" "$work/store.yaml" "$store_appset"
contract project-fit "external-secrets-store" "$work/store.yaml" "$project" external-secrets
contract project-fit "external-secrets-network-policies" "$work/policies.yaml" "$project" external-secrets
contract network-policies "external-secrets-network-policies" "$work/policies.yaml"
contract hooks "external-secrets-network-policies" "$work/policies.yaml"
echo "    ran $contracts contract check(s)"

echo "==> the charts refuse to render without what the cluster Secret supplies"
refuses() {
  # refuses CHART MESSAGE [HELM ARGS...]: the render must fail and say MESSAGE.
  local chart="$1" message="$2"
  shift 2
  if helm template check "$chart" --namespace external-secrets "$@" > "$work/refused.out" 2>&1; then
    echo "    FAIL $chart rendered without the value that $message names"
    status=1
  elif ! grep -q -- "$message" "$work/refused.out"; then
    echo "    FAIL $chart failed, but the message does not say '$message'"
    status=1
  fi
}
refuses "$operator" "roleArn must be set" -f "$operator/values.yaml"
refuses "$store" "region must be set" --set parameterPrefix=/multi-cloud-sre/dev
refuses "$store" "parameterPrefix must be set" --set region=eu-north-1
echo "    the operator needs its role, and the store needs the region and the parameter path"

echo "==> the credential charts, in both modes"
cred_charts="platform/data/secrets platform/data/rabbitmq platform/data/rabbitmq-credentials platform/observability/secrets"
prefix="/multi-cloud-sre/dev"
: > "$work/generated.yaml"
: > "$work/external.yaml"
for chart in $cred_charts; do
  helm template "$(basename "$chart")" "$chart" --namespace "$(basename "$(dirname "$chart")")" -f "$chart/values.yaml" > "$work/g.yaml" || status=1
  helm template "$(basename "$chart")" "$chart" --namespace "$(basename "$(dirname "$chart")")" -f "$chart/values.yaml" \
    --set externalSecrets.enabled=true --set externalSecrets.prefix="$prefix" > "$work/e.yaml" || status=1
  printf '\n---\n' >> "$work/generated.yaml"
  cat "$work/g.yaml" >> "$work/generated.yaml"
  printf '\n---\n' >> "$work/external.yaml"
  cat "$work/e.yaml" >> "$work/external.yaml"
  # Each chart on its own: the default mode is as it was, and the external mode renders ordinary resources.
  "$py" scripts/chart-contract-check.py hooks "$chart (external)" < "$work/e.yaml" || status=1
  "$py" scripts/chart-contract-check.py secret-jobs "$chart (external)" < "$work/e.yaml" || status=1
done
contract secrets-generated "credential charts, default mode" "$work/generated.yaml" scripts/secrets/contract.yaml
contract secrets-external "credential charts, external mode" "$work/external.yaml" "$prefix" scripts/secrets/contract.yaml scripts/secrets/manifest.yaml
data_project="platform/argocd/bootstrap/appproject-platform-data.yaml"
obs_project="platform/argocd/bootstrap/appproject-platform-observability.yaml"
for chart in platform/data/secrets platform/data/rabbitmq platform/data/rabbitmq-credentials; do
  helm template "$(basename "$chart")" "$chart" --namespace data -f "$chart/values.yaml" --set externalSecrets.enabled=true --set externalSecrets.prefix="$prefix" > "$work/e.yaml" || status=1
  contract project-fit "$chart (external)" "$work/e.yaml" "$data_project" data
done
helm template observability-secrets platform/observability/secrets --namespace observability -f platform/observability/secrets/values.yaml \
  --set externalSecrets.enabled=true --set externalSecrets.prefix="$prefix" > "$work/e.yaml" || status=1
contract project-fit "platform/observability/secrets (external)" "$work/e.yaml" "$obs_project" observability
echo "    the default mode and the external mode of the four charts agree with the contract"

echo "==> the ServiceMonitor of the External Secrets Operator"
helm template observability-monitors platform/observability/monitors --namespace observability > "$work/monitors.yaml" || status=1
if ! "$py" - "$work/monitors.yaml" "$work/operator.yaml" << 'PYEND'; then
import sys

import yaml

monitor = next(d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d["kind"] == "ServiceMonitor" and d["metadata"]["name"] == "external-secrets")
services = [d for d in yaml.safe_load_all(open(sys.argv[2])) if d and d["kind"] == "Service"]
match = monitor["spec"]["selector"]["matchLabels"]
port = monitor["spec"]["endpoints"][0]["port"]
hits = [s["metadata"]["name"] for s in services if all((s["metadata"].get("labels") or {}).get(k) == v for k, v in match.items())
        and any(p.get("name") == port for p in s["spec"]["ports"])]
if monitor["spec"]["namespaceSelector"]["matchNames"] != ["external-secrets"] or len(hits) != 3:
    print("    FAIL the External Secrets ServiceMonitor selects {} Services with the port {} (three metrics Services are expected)".format(len(hits), port))
    sys.exit(1)
print("    the External Secrets ServiceMonitor selects the three metrics Services: " + ", ".join(sorted(hits)))
PYEND
  status=1
fi

echo "==> shellcheck"
./scripts/shellcheck.sh || status=1

exit "$status"
