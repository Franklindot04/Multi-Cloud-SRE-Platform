#!/usr/bin/env bash
# Offline checks for the policy engine under platform/security (Kyverno and the network policies of its namespace) and its
# Argo CD definitions.
#
#   1. helm lint, helm template and kubeconform for both charts (scripts/addons-check.sh), including the high availability
#      values of Kyverno, plus yamllint
#   2. contracts that a schema check cannot see (scripts/chart-contract-check.py), on the rendered charts:
#      - restricted: every Kyverno pod meets the restricted Pod Security level that the kyverno namespace enforces
#      - kyverno: the four controllers have requests and limits and, with their replicas, request under 600m CPU and 1Gi of
#        memory; the webhooks fail open and skip kube-system, kube-node-lease, argocd and kyverno; metrics are on port 8000;
#        no webhook configuration and no Helm pre-delete hook is rendered; the ApplicationSet syncs with ServerSideApply=true
#        because a CRD is larger than client-side apply can store
#      - project-fit: everything rendered is allowed by the platform-addons AppProject, in the kyverno namespace
#      - network-policies: the policies of the kyverno namespace (the flows are checked by scripts/network-policies-check.sh)
#      - policies: the admission policies (platform/security/policies) are ValidatingPolicy and ImageValidatingPolicy of
#        policies.kyverno.io/v1, scoped to shop, failing open, Audit by default and Deny with values-enforce.yaml (the signature
#        policy stays Audit), matching pods and not their subresources (the ephemeral debug container of the runbook), with
#        autogen for the controllers, the registry of deploy/helm/values/images.yaml, and the signature policy asking for what
#        scripts/verify-image.sh asks for (the same issuer, identity, transparency log, SBOM and provenance)
#   3. the Kyverno ServiceMonitor of the monitors chart selects the Services the chart creates
#   4. the Kyverno CLI, at the version of the chart's app, from the image the chart's own hook Job uses, pinned here by digest and run
#      with Docker (skipped with a message when Docker is not running):
#      - kyverno test: platform/security/policies/tests, a resource that passes and one for each way to fail, for every policy,
#        including Argo Rollouts (the probe policy matches the Rollout; the pod policies are tested on the pods it creates)
#      - the tests can fail: the registry policy is changed to allow everything, and the tests must notice
#      - the reality check: the service chart under every profile and the RabbitMQ credentials chart are rendered and must pass the
#        policies that apply to them, so the policies cannot block our own workloads
#      - the ImageValidatingPolicy is loaded (its CEL is compiled) against a pod it does not match; the signature check itself
#        needs the registry and the Sigstore services, so it is checked by the policies contract above and not run
#   5. shellcheck on the scripts, through scripts/shellcheck.sh
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
kyverno="$root/kyverno"
netpol="$root/network-policies"
admission="$root/policies"
images_values="deploy/helm/values/images.yaml"
verify_script="scripts/verify-image.sh"
project="platform/argocd/bootstrap/appproject-platform-addons.yaml"
appset="platform/argocd/apps/84-policy-kyverno.yaml"

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
helm repo add kyverno-check "$(sed -n 's/^ *repository: *//p' "$kyverno/Chart.yaml")" > /dev/null
helm dependency build "$kyverno" > /dev/null || status=1

echo "==> chart contracts"
contracts=0
contract() {
  # contract CHECK LABEL FILE [EXTRA...]
  local check="$1" label="$2" file="$3"
  shift 3
  contracts=$((contracts + 1))
  "$py" scripts/chart-contract-check.py "$check" "$label" "$@" < "$file" || status=1
}
helm template kyverno "$kyverno" --namespace kyverno -f "$kyverno/values.yaml" --include-crds > "$work/kyverno.yaml" || status=1
helm template kyverno "$kyverno" --namespace kyverno -f "$kyverno/values.yaml" -f "$kyverno/values-ha.yaml" --include-crds > "$work/kyverno-ha.yaml" || status=1
helm template policy-network-policies "$netpol" --namespace kyverno -f "$netpol/ci/aws-params.yaml" > "$work/policies.yaml" || status=1

contract restricted "kyverno" "$work/kyverno.yaml"
contract restricted "kyverno + values-ha.yaml" "$work/kyverno-ha.yaml"
contract kyverno "kyverno" "$work/kyverno.yaml" "$appset"
# The controllers rank with the add-ons, above the services. The chart has no setting for the priority class of its migration Job (a
# post-upgrade hook that runs once and ends), so that Job is named as an exception.
contract priority "kyverno" "$work/kyverno.yaml" platform-addons-critical Job/kyverno-migrate-resources
contract priority "kyverno + values-ha.yaml" "$work/kyverno-ha.yaml" platform-addons-critical Job/kyverno-migrate-resources
contract kyverno "kyverno + values-ha.yaml" "$work/kyverno-ha.yaml" "$appset"
contract project-fit "kyverno" "$work/kyverno.yaml" "$project" kyverno
contract project-fit "kyverno-network-policies" "$work/policies.yaml" "$project" kyverno
contract network-policies "kyverno-network-policies" "$work/policies.yaml"
contract hooks "kyverno-network-policies" "$work/policies.yaml"
echo "    ran $contracts contract check(s)"

helm template policies "$admission" --namespace kyverno -f "$admission/values.yaml" > "$work/admission.yaml" || status=1
helm template policies "$admission" --namespace kyverno -f "$admission/values.yaml" -f "$admission/values-enforce.yaml" > "$work/admission-enforce.yaml" || status=1
contract policies "admission" "$work/admission.yaml" audit "$images_values" "$verify_script"
contract policies "admission + values-enforce.yaml" "$work/admission-enforce.yaml" enforce "$images_values" "$verify_script"
contract project-fit "admission" "$work/admission.yaml" "$project" kyverno
contract project-fit "admission + values-enforce.yaml" "$work/admission-enforce.yaml" "$project" kyverno
echo "    ran $contracts contract check(s) in all"

echo "==> the Kyverno ServiceMonitor"
helm template observability-monitors platform/observability/monitors --namespace observability > "$work/monitors.yaml" || status=1
if ! grep -q 'app.kubernetes.io/name: kyverno-monitor' "$work/monitors.yaml"; then
  echo "    FAIL the monitors chart renders no ServiceMonitor for Kyverno"
  status=1
elif ! "$py" - "$work/monitors.yaml" "$work/kyverno.yaml" << 'PYEND'; then
import sys

import yaml

yaml.SafeLoader.add_constructor("tag:yaml.org,2002:value", lambda loader, node: loader.construct_scalar(node))
monitor = next(d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d["kind"] == "ServiceMonitor" and d["metadata"]["name"] == "kyverno")
services = [d for d in yaml.safe_load_all(open(sys.argv[2])) if d and d["kind"] == "Service"]
match = monitor["spec"]["selector"]["matchLabels"]
port = monitor["spec"]["endpoints"][0]["port"]
hits = [s["metadata"]["name"] for s in services if all((s["metadata"].get("labels") or {}).get(k) == v for k, v in match.items())
        and any(p.get("name") == port for p in s["spec"]["ports"])]
if monitor["spec"]["namespaceSelector"]["matchNames"] != ["kyverno"] or len(hits) != 4:
    print("    FAIL the Kyverno ServiceMonitor selects {} Services with the port {} (four metrics Services are expected)".format(len(hits), port))
    sys.exit(1)
print("    the Kyverno ServiceMonitor selects the four metrics Services: " + ", ".join(sorted(hits)))
PYEND
  status=1
fi

echo "==> Kyverno CLI"
# The CLI image is the one the chart's migration Job uses, so it is always the version of the app. Pinned by digest (the index of
# the multi-architecture image, read from the registry on 2026-11-02); move the digest together with the chart.
cli_tag="v1.19.2"
cli_image="reg.kyverno.io/kyverno/kyverno-cli:${cli_tag}@sha256:322ec5044d600930cb3af0e56dc33154a2d1d1fba58f4cadad3f47be7e78b11c"
chart_cli="$(sed -n 's#^ *image: *"\{0,1\}reg.kyverno.io/kyverno/kyverno-cli:\([^"@ ]*\).*#\1#p' "$work/kyverno.yaml" | head -1)"
if [ "$chart_cli" != "$cli_tag" ]; then
  echo "    FAIL the Kyverno chart uses the CLI image tag '$chart_cli' and this script pins $cli_tag: move the pin (tag and digest) with the chart"
  status=1
elif ! have docker || ! docker info > /dev/null 2>&1; then
  echo "    Docker is not running: the Kyverno tests and the reality check are skipped (they run in CI). Start Docker and run this again."
else
  kyverno_cli() {
    # kyverno_cli DIR ARGS...: the CLI with DIR mounted read-only as the working directory.
    local dir="$1"
    shift
    docker run --rm -v "$dir:/t:ro" -w /t "$cli_image" "$@"
  }
  admission_policies() {
    # admission_policies FILE: the rendered policies without the ImageValidatingPolicy.
    "$py" scripts/policy-test-inputs.py policies "$work/admission.yaml" "$1" > /dev/null
  }

  unit="$work/unit"
  mkdir -p "$unit"
  cp "$admission/tests/kyverno-test.yaml" "$admission/tests/resources.yaml" "$unit/"
  admission_policies "$unit/policies.yaml"
  if kyverno_cli "$unit" test . --fail-only > "$work/unit.out" 2>&1; then
    echo "    kyverno test: $(sed -n 's/^Test Summary: *//p' "$work/unit.out" | head -1) ($(grep -c '^kind: ' "$admission/tests/resources.yaml") resources)"
  else
    echo "    FAIL kyverno test on platform/security/policies/tests"
    sed 's/\x1b\[[0-9;]*m//g' "$work/unit.out" | tail -30
    status=1
  fi

  # The tests must be able to fail: a registry policy that allows everything has to be noticed.
  broken="$work/broken"
  mkdir -p "$broken"
  cp "$unit/kyverno-test.yaml" "$unit/resources.yaml" "$broken/"
  "$py" - "$unit/policies.yaml" "$broken/policies.yaml" << 'PYEND'
import sys

import yaml

docs = list(yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")))
for doc in docs:
    if doc["metadata"]["name"] == "restrict-image-registries":
        doc["spec"]["validations"][0]["expression"] = "true"
yaml.safe_dump_all(docs, open(sys.argv[2], "w", encoding="utf-8"), sort_keys=False)
PYEND
  if cmp -s "$unit/policies.yaml" "$broken/policies.yaml"; then
    echo "    FAIL the self-check could not change the registry policy"
    status=1
  elif kyverno_cli "$broken" test . --fail-only > /dev/null 2>&1; then
    echo "    FAIL the tests did not notice a registry policy that allows every image"
    status=1
  else
    echo "    the tests notice a registry policy that allows every image"
  fi

  # The reality check.
  reality="$work/reality"
  mkdir -p "$reality"
  values=deploy/helm/values
  entries=()
  for profile in memory data; do
    for svc in gateway orders payments notifier; do
      for cloud in aws gcp; do
        args=(-f "$values/images.yaml" -f "$values/$svc.yaml" -f "$values/$svc-$profile.yaml")
        if [ "$svc" = gateway ]; then
          args+=(-f "$values/cloud-$cloud.yaml")
        elif [ "$cloud" = gcp ]; then
          continue
        fi
        file="$work/render-$svc-$profile-$cloud.yaml"
        helm template "$svc" deploy/helm/service --namespace shop "${args[@]}" --set networkPolicy.serviceCidr=203.0.113.0/24 > "$file" || status=1
        entries+=("$svc-$profile-$cloud=$file")
      done
    done
  done
  # The gateway as an Argo Rollout, as Argo CD renders it on a cluster with the controller (the data profile): the pods are the same, and
  # the probe policy has to cover the Rollout itself.
  for cloud in aws gcp; do
    file="$work/render-gateway-rollout-$cloud.yaml"
    helm template gateway deploy/helm/service --namespace shop -f "$values/images.yaml" -f "$values/gateway.yaml" -f "$values/gateway-data.yaml" \
      -f "$values/cloud-$cloud.yaml" -f "$values/gateway-rollout.yaml" --set rollout.enabled=true --set rollout.analysis.enabled=true \
      --set networkPolicy.serviceCidr=203.0.113.0/24 > "$file" || status=1
    entries+=("gateway-rollout-$cloud=$file")
  done
  helm template data-rabbitmq-credentials platform/data/rabbitmq-credentials --namespace shop > "$work/render-credentials.yaml" || status=1
  entries+=("rabbitmq-credentials=$work/render-credentials.yaml")
  admission_policies "$reality/policies.yaml"
  "$py" scripts/policy-test-inputs.py reality "$reality" "${entries[@]}" > "$work/reality.txt" || status=1
  if kyverno_cli "$reality" test . --fail-only --detailed-results > "$work/reality.out" 2>&1; then
    echo "    reality check: $(cat "$work/reality.txt"): every workload passes the policies that apply to it ($(sed -n 's/^Test Summary: *//p' "$work/reality.out" | head -1))"
  else
    echo "    FAIL a workload of ours would not pass the admission policies:"
    sed 's/\x1b\[[0-9;]*m//g' "$work/reality.out" | tail -30
    status=1
  fi

  # The signature policy is loaded: the CLI compiles its CEL, and a pod whose image it does not match gives no network call.
  mkdir -p "$work/ivp"
  helm template policies "$admission" --namespace kyverno -f "$admission/values.yaml" -s templates/verify-image-signatures.yaml | grep -v '^# Source' > "$work/ivp/policy.yaml"
  cat > "$work/ivp/pod.yaml" << 'PODEOF'
apiVersion: v1
kind: Pod
metadata:
  name: other
  namespace: shop
spec:
  containers:
    - name: app
      image: docker.io/library/busybox@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
PODEOF
  if kyverno_cli "$work/ivp" apply policy.yaml --resource pod.yaml 2>&1 | grep -q 'error: 0'; then
    echo "    the signature policy loads (its CEL compiles); the signature check itself is not run offline"
  else
    echo "    FAIL the signature policy does not load"
    status=1
  fi
fi

echo "==> shellcheck"
./scripts/shellcheck.sh || status=1

exit "$status"
