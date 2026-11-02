#!/usr/bin/env bash
# Offline checks for the Argo Rollouts controller under platform/delivery (the controller and the network policies of its namespace) and its
# Argo CD definitions.
#
#   1. helm lint, helm template and kubeconform for both charts (scripts/addons-check.sh), including the high availability values of the
#      controller, plus yamllint
#   2. contracts that a schema check cannot see (scripts/chart-contract-check.py), on the rendered charts:
#      - restricted: the controller pod meets the restricted Pod Security level that the argo-rollouts namespace enforces
#      - argo-rollouts: one Deployment, with requests and limits, a non-root pod with a RuntimeDefault seccomp profile, no privilege
#        escalation, a read-only root filesystem and all capabilities dropped, the priority class platform-addons-critical, --leader-elect
#        when it has more than one replica; metrics on 8090 behind a Service; the five CRDs; no dashboard, no notifications, no webhook, no
#        Rollout or analysis object and no traffic router rights; the ApplicationSet syncs with ServerSideApply=true
#      - priority: every pod uses platform-addons-critical
#      - project-fit: everything rendered is allowed by the platform-addons AppProject, in the argo-rollouts namespace
#      - network-policies: the policies of the argo-rollouts namespace (the flows are checked by scripts/network-policies-check.sh)
#   3. the render that scripts/test-scripts.sh uses (scripts/tests/fixtures/delivery/argo-rollouts.yaml) is the real one
#   4. the wiring agrees: the label of the ApplicationSets is the one scripts/bootstrap-argocd.sh writes, the flag exists, the waves and the
#      numbering are the documented ones, and the AppProject has the namespace
#   5. the ServiceMonitor of the monitors chart selects the Service the controller creates and sets honorLabels, so the namespace label of
#      the rollouts is kept (the alerts and the dashboard select on it)
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

root="platform/delivery"
controller="$root/argo-rollouts"
netpol="$root/argo-rollouts-network-policies"
project="platform/argocd/bootstrap/appproject-platform-addons.yaml"
appset="platform/argocd/apps/99-delivery-argo-rollouts.yaml"
netpol_appset="platform/argocd/apps/100-delivery-network-policies.yaml"

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
helm repo add delivery-check "$(sed -n 's/^ *repository: *//p' "$controller/Chart.yaml")" > /dev/null
helm dependency build "$controller" > /dev/null || status=1

echo "==> chart contracts"
contracts=0
contract() {
  # contract CHECK LABEL FILE [EXTRA...]
  local check="$1" label="$2" file="$3"
  shift 3
  contracts=$((contracts + 1))
  "$py" scripts/chart-contract-check.py "$check" "$label" "$@" < "$file" || status=1
}
helm template argo-rollouts "$controller" --namespace argo-rollouts -f "$controller/values.yaml" -f "$controller/ci/aws-params.yaml" --include-crds > "$work/controller.yaml" || status=1
helm template argo-rollouts "$controller" --namespace argo-rollouts -f "$controller/values.yaml" -f "$controller/values-ha.yaml" -f "$controller/ci/aws-params.yaml" --include-crds > "$work/controller-ha.yaml" || status=1
helm template delivery-network-policies "$netpol" --namespace argo-rollouts -f "$netpol/values.yaml" -f "$netpol/ci/aws-params.yaml" > "$work/policies.yaml" || status=1

contract restricted "argo-rollouts" "$work/controller.yaml"
contract restricted "argo-rollouts + values-ha.yaml" "$work/controller-ha.yaml"
contract argo-rollouts "argo-rollouts" "$work/controller.yaml" "$appset"
contract argo-rollouts "argo-rollouts + values-ha.yaml" "$work/controller-ha.yaml" "$appset"
contract priority "argo-rollouts" "$work/controller.yaml" platform-addons-critical
contract priority "argo-rollouts + values-ha.yaml" "$work/controller-ha.yaml" platform-addons-critical
contract project-fit "argo-rollouts" "$work/controller.yaml" "$project" argo-rollouts
contract project-fit "argo-rollouts-network-policies" "$work/policies.yaml" "$project" argo-rollouts
contract network-policies "argo-rollouts-network-policies" "$work/policies.yaml"
contract hooks "argo-rollouts-network-policies" "$work/policies.yaml"
echo "    ran $contracts contract check(s)"

echo "==> the render that scripts/test-scripts.sh uses"
# The tests of the check scripts run on a committed render of the controller chart (they do not build the downloaded dependency). It has to
# be the real render, without the CRDs and the stand-ins for the five of them.
if ! "$py" - "$work/controller.yaml" scripts/tests/fixtures/delivery/argo-rollouts.yaml << 'PYEND'; then
import sys

import yaml


def without_crds(path):
    return [d for d in yaml.safe_load_all(open(path, encoding="utf-8")) if d and d["kind"] != "CustomResourceDefinition"]


if without_crds(sys.argv[1]) != without_crds(sys.argv[2]):
    print("    FAIL scripts/tests/fixtures/delivery/argo-rollouts.yaml is not the render of platform/delivery/argo-rollouts any more: render it again (helm template with values.yaml and ci/aws-params.yaml), replace each CRD by a small stand-in, and replace the file")
    sys.exit(1)
print("    the committed render of the controller is the real one")
PYEND
  status=1
fi

echo "==> the wiring"
label_ok=1
# shellcheck disable=SC2016 # the pattern is literal text of the script
grep -q '"platform.example/progressive-delivery": \$progressive_delivery' scripts/bootstrap-argocd.sh || label_ok=0
grep -q -e '--enable-progressive-delivery)' scripts/bootstrap-argocd.sh || label_ok=0
for f in "$appset" "$netpol_appset"; do
  grep -q 'platform.example/progressive-delivery: "true"' "$f" || label_ok=0
done
if [ "$label_ok" -ne 1 ]; then
  echo "    FAIL the label platform.example/progressive-delivery is not written by scripts/bootstrap-argocd.sh (flag --enable-progressive-delivery) and selected by both ApplicationSets"
  status=1
else
  echo "    the flag writes the label that both ApplicationSets select"
fi
if ! grep -q 'namespace: argo-rollouts$' "$project"; then
  echo "    FAIL the platform-addons project has no destination for the argo-rollouts namespace"
  status=1
fi
"$py" scripts/chart-contract-check.py waves platform/argocd/apps platform/argocd/README.md || status=1
if ! helm template check "$netpol" > /dev/null 2>&1; then
  echo "    the network policies refuse to render without the Service range"
else
  echo "    FAIL the network policies rendered without the Service range"
  status=1
fi

echo "==> the ServiceMonitor of the Argo Rollouts controller"
helm template observability-monitors platform/observability/monitors --namespace observability > "$work/monitors.yaml" || status=1
if ! "$py" - "$work/monitors.yaml" "$work/controller.yaml" << 'PYEND'; then
import sys

import yaml

monitor = next(d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d["kind"] == "ServiceMonitor" and d["metadata"]["name"] == "argo-rollouts")
services = [d for d in yaml.safe_load_all(open(sys.argv[2])) if d and d["kind"] == "Service"]
match = monitor["spec"]["selector"]["matchLabels"]
port = monitor["spec"]["endpoints"][0]["port"]
hits = [s["metadata"]["name"] for s in services if all((s["metadata"].get("labels") or {}).get(k) == v for k, v in match.items())
        and any(p.get("name") == port for p in s["spec"]["ports"])]
if monitor["spec"]["namespaceSelector"]["matchNames"] != ["argo-rollouts"] or len(hits) != 1:
    print("    FAIL the Argo Rollouts ServiceMonitor selects {} Services with the port {} (one metrics Service is expected)".format(len(hits), port))
    sys.exit(1)
if monitor["spec"]["endpoints"][0].get("honorLabels") is not True:
    print("    FAIL the Argo Rollouts ServiceMonitor does not set honorLabels: Prometheus would rename the namespace label of the rollouts to exported_namespace, and the alerts on namespace=\"shop\" would never match")
    sys.exit(1)
print("    the Argo Rollouts ServiceMonitor selects the metrics Service: " + ", ".join(sorted(hits)) + " (and keeps the namespace label of the rollouts)")
PYEND
  status=1
fi

echo "==> shellcheck"
./scripts/shellcheck.sh || status=1

exit "$status"
