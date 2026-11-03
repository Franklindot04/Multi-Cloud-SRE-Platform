#!/usr/bin/env bash
# Offline checks for the network policies of the shop, data and observability namespaces.
#
#   1. each set of policies renders and passes the policy contract (scripts/chart-contract-check.py network-policies):
#      a default deny for ingress and egress covers every pod, the allow rules come first (lower sync wave), and no rule
#      is empty, without ports, or open to a whole address range
#   2. all the charts are rendered together and every label and namespace a policy uses is real
#      (chart-contract-check.py policy-labels): the services, the data layer and its operators, the metrics, logging and
#      tracing stack. A policy with a guessed label selects nothing, so it would not fail anywhere else.
#   3. the flows of scripts/tests/fixtures/network-policies/flows.yaml, evaluated against the rendered policies with the standard
#      NetworkPolicy semantics (scripts/network-policy-flows.py): every connection the services and the platform need is
#      allowed, and the connections that must stay closed are denied, for the data and the memory profile of the services.
#      This proves the policies mean what we intend; whether the VPC CNI policy agent behaves the same is for a cluster
#   4. the policy charts refuse to render without the address ranges, which Argo CD supplies from the cluster
#
# The kyverno namespace (platform/security/network-policies) and the external-secrets namespace
# (platform/security/external-secrets-network-policies) and the argo-rollouts namespace (platform/delivery/argo-rollouts-network-policies) are covered
# too.
#
# Helm and the vendored chart tarballs are needed (they are fetched from the lock files, as in scripts/observability-check.sh).
# Nothing is installed in a cluster.
set -euo pipefail

case "${1:-}" in
  -h | --help)
    echo "Usage: $0"
    exit 0
    ;;
esac

cd "$(dirname "${BASH_SOURCE[0]}")/.."
have() { command -v "$1" > /dev/null 2>&1; }

if ! have helm; then
  echo "helm not installed; skipping the network policy checks"
  exit 0
fi
py="$(./scripts/python-with-yaml.sh)" || {
  echo "no Python with PyYAML found (installing yamllint provides it); the network policy checks fail without it"
  exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export HELM_CONFIG_HOME="$work/config" HELM_CACHE_HOME="$work/cache" HELM_DATA_HOME="$work/data"
status=0
check="scripts/chart-contract-check.py"

# The wrapper charts are rendered from their vendored tarballs, which are downloaded and not committed.
build_dependencies() {
  local dir="$1" repo
  grep -q '^dependencies:' "$dir/Chart.yaml" || return 0
  while IFS= read -r repo; do
    helm repo add "r$(printf '%s' "$repo" | cksum | cut -d' ' -f1)" "$repo" > /dev/null
  done < <(sed -n 's/^ *repository: *//p' "$dir/Chart.yaml")
  helm dependency build "$dir" > /dev/null
}
for dir in platform/observability/kube-prometheus-stack platform/observability/loki platform/observability/alloy \
  platform/observability/tempo platform/data/cloudnative-pg platform/data/valkey platform/security/kyverno platform/security/external-secrets platform/delivery/argo-rollouts; do
  build_dependencies "$dir" || status=1
done

echo "==> policies of each namespace"
values=deploy/helm/values
# The Service range that Argo CD supplies from the cluster secret, as the policy charts' ci fixtures have it (a documentation range).
service_cidr=203.0.113.0/24
for svc in gateway orders payments notifier; do
  helm template "$svc" deploy/helm/service --namespace shop -f "$values/images.yaml" -f "$values/$svc.yaml" -f "$values/$svc-data.yaml" \
    --set networkPolicy.serviceCidr="$service_cidr" > "$work/shop-$svc.yaml" || status=1
  "$py" "$check" network-policies "shop/$svc" < "$work/shop-$svc.yaml" || status=1
done
cidr_args=(-f platform/data/network-policies/ci/aws-params.yaml)
helm template data-network-policies platform/data/network-policies --namespace data "${cidr_args[@]}" > "$work/data-policies.yaml" || status=1
"$py" "$check" network-policies "data" < "$work/data-policies.yaml" || status=1
helm template observability-network-policies platform/observability/network-policies --namespace observability \
  -f platform/observability/network-policies/ci/aws-params.yaml > "$work/observability-policies.yaml" || status=1
"$py" "$check" network-policies "observability" < "$work/observability-policies.yaml" || status=1
helm template policy-network-policies platform/security/network-policies --namespace kyverno \
  -f platform/security/network-policies/ci/aws-params.yaml > "$work/kyverno-policies.yaml" || status=1
"$py" "$check" network-policies "kyverno" < "$work/kyverno-policies.yaml" || status=1
helm template eso-network-policies platform/security/external-secrets-network-policies --namespace external-secrets \
  -f platform/security/external-secrets-network-policies/ci/aws-params.yaml > "$work/eso-policies.yaml" || status=1
"$py" "$check" network-policies "external-secrets" < "$work/eso-policies.yaml" || status=1
helm template delivery-network-policies platform/delivery/argo-rollouts-network-policies --namespace argo-rollouts \
  -f platform/delivery/argo-rollouts-network-policies/ci/aws-params.yaml > "$work/rollouts-policies.yaml" || status=1
"$py" "$check" network-policies "argo-rollouts" < "$work/rollouts-policies.yaml" || status=1

echo "==> labels and namespaces used by the policies"
obs=platform/observability
data=platform/data
helm template kube-prometheus-stack "$obs/kube-prometheus-stack" --namespace observability -f "$obs/kube-prometheus-stack/values.yaml" > "$work/stack.yaml" || status=1
helm template observability-secrets "$obs/secrets" --namespace observability > "$work/obs-secrets.yaml" || status=1
helm template otel-collector "$obs/otel-collector" --namespace observability > "$work/collector.yaml" || status=1
helm template observability-monitors "$obs/monitors" --namespace observability > "$work/monitors.yaml" || status=1
helm template loki "$obs/loki" --namespace observability -f "$obs/loki/values.yaml" > "$work/loki.yaml" || status=1
helm template alloy "$obs/alloy" --namespace observability -f "$obs/alloy/values.yaml" > "$work/alloy.yaml" || status=1
helm template tempo "$obs/tempo" --namespace observability -f "$obs/tempo/values.yaml" > "$work/tempo.yaml" || status=1
helm template data-secrets "$data/secrets" --namespace data > "$work/data-secrets.yaml" || status=1
helm template data-postgres "$data/postgres" --namespace data -f "$data/postgres/values.yaml" -f "$data/postgres/values-standard.yaml" > "$work/postgres.yaml" || status=1
helm template data-valkey "$data/valkey" --namespace data -f "$data/valkey/values.yaml" -f "$data/valkey/values-standard.yaml" > "$work/valkey.yaml" || status=1
helm template kyverno platform/security/kyverno --namespace kyverno -f platform/security/kyverno/values.yaml > "$work/kyverno.yaml" || status=1
helm template external-secrets platform/security/external-secrets --namespace external-secrets \
  -f platform/security/external-secrets/values.yaml -f platform/security/external-secrets/ci/aws-params.yaml > "$work/eso.yaml" || status=1
helm template argo-rollouts platform/delivery/argo-rollouts --namespace argo-rollouts \
  -f platform/delivery/argo-rollouts/values.yaml -f platform/delivery/argo-rollouts/ci/aws-params.yaml > "$work/rollouts.yaml" || status=1
helm template data-cnpg-operator "$data/cloudnative-pg" --namespace cnpg-system -f "$data/cloudnative-pg/values.yaml" -f "$data/cloudnative-pg/values-standard.yaml" > "$work/cnpg.yaml" || status=1
(
  cd "$work"
  cat shop-*.yaml data-policies.yaml observability-policies.yaml kyverno-policies.yaml kyverno.yaml eso-policies.yaml eso.yaml rollouts-policies.yaml rollouts.yaml stack.yaml obs-secrets.yaml collector.yaml monitors.yaml \
    loki.yaml alloy.yaml tempo.yaml data-secrets.yaml postgres.yaml valkey.yaml cnpg.yaml
  printf '\n---\n'
  cat "$OLDPWD/$data/rabbitmq-operator/cluster-operator.yml"
) > "$work/all.yaml"
"$py" "$check" policy-labels "all charts" kube-system observability shop data kyverno external-secrets argo-rollouts cnpg-system rabbitmq-system < "$work/all.yaml" || status=1

echo "==> flows"
for svc in gateway orders payments notifier; do
  helm template "$svc" deploy/helm/service --namespace shop -f "$values/images.yaml" -f "$values/$svc.yaml" -f "$values/$svc-memory.yaml" \
    --set networkPolicy.serviceCidr="$service_cidr" > "$work/shop-memory-$svc.yaml" || status=1
done
flows="scripts/tests/fixtures/network-policies/flows.yaml"
others=("data:$work/data-policies.yaml" "observability:$work/observability-policies.yaml" "kyverno:$work/kyverno-policies.yaml"
  "kyverno:$work/kyverno.yaml" "external-secrets:$work/eso-policies.yaml" "external-secrets:$work/eso.yaml" "argo-rollouts:$work/rollouts-policies.yaml" "argo-rollouts:$work/rollouts.yaml" "observability:$work/stack.yaml"
  "observability:$work/obs-secrets.yaml" "observability:$work/collector.yaml" "observability:$work/loki.yaml"
  "observability:$work/alloy.yaml" "observability:$work/tempo.yaml" "data:$work/data-secrets.yaml" "data:$work/postgres.yaml"
  "data:$work/valkey.yaml" "cnpg-system:$work/cnpg.yaml" "rabbitmq-system:$work/rabbitmq-operator.yaml")
cp "$data/rabbitmq-operator/cluster-operator.yml" "$work/rabbitmq-operator.yaml"
"$py" scripts/network-policy-flows.py --profile data "$flows" \
  "shop:$work/shop-gateway.yaml" "shop:$work/shop-orders.yaml" "shop:$work/shop-payments.yaml" "shop:$work/shop-notifier.yaml" \
  "${others[@]}" || status=1
"$py" scripts/network-policy-flows.py --profile memory "$flows" \
  "shop:$work/shop-memory-gateway.yaml" "shop:$work/shop-memory-orders.yaml" "shop:$work/shop-memory-payments.yaml" "shop:$work/shop-memory-notifier.yaml" \
  "${others[@]}" || status=1

echo "==> the policy charts need the address ranges"
# The Service range is required by every policy chart (a deny must not land without the rule for DNS and the API), and the
# observability chart also needs the VPC range (the kubelets and the API server addresses Prometheus reaches by address).
for chart in platform/data/network-policies platform/observability/network-policies platform/security/network-policies platform/security/external-secrets-network-policies platform/delivery/argo-rollouts-network-policies; do
  if helm template check "$chart" > /dev/null 2>&1; then
    echo "    FAIL $chart rendered without its address ranges"
    status=1
  fi
done
if helm template check platform/data/network-policies --set vpcCidr=192.0.2.0/24 > /dev/null 2>&1; then
  echo "    FAIL platform/data/network-policies rendered without serviceCidr"
  status=1
fi
if helm template check platform/observability/network-policies --set serviceCidr="$service_cidr" > /dev/null 2>&1; then
  echo "    FAIL platform/observability/network-policies rendered without vpcCidr"
  status=1
fi
if helm template check platform/observability/network-policies --set vpcCidr=192.0.2.0/24 > /dev/null 2>&1; then
  echo "    FAIL platform/observability/network-policies rendered without serviceCidr"
  status=1
fi

if helm template check platform/security/network-policies --set vpcCidr=192.0.2.0/24 > /dev/null 2>&1; then
  echo "    FAIL platform/security/network-policies rendered without serviceCidr"
  status=1
fi
if helm template check platform/security/network-policies --set serviceCidr="$service_cidr" > /dev/null 2>&1; then
  echo "    FAIL platform/security/network-policies rendered without vpcCidr (the API server reaches the webhook from the VPC)"
  status=1
fi

if helm template check platform/security/external-secrets-network-policies --set vpcCidr=192.0.2.0/24 > /dev/null 2>&1; then
  echo "    FAIL platform/security/external-secrets-network-policies rendered without serviceCidr"
  status=1
fi
if helm template check platform/security/external-secrets-network-policies --set serviceCidr="$service_cidr" > /dev/null 2>&1; then
  echo "    FAIL platform/security/external-secrets-network-policies rendered without vpcCidr (the API server reaches the webhook from the VPC)"
  status=1
fi

if helm template check platform/delivery/argo-rollouts-network-policies > /dev/null 2>&1; then
  echo "    FAIL platform/delivery/argo-rollouts-network-policies rendered without serviceCidr"
  status=1
fi

echo "==> the policy charts can be switched off"
for chart in platform/data/network-policies platform/observability/network-policies platform/security/network-policies platform/security/external-secrets-network-policies platform/delivery/argo-rollouts-network-policies; do
  if helm template check "$chart" --set enabled=false 2> /dev/null | grep -q '^kind:'; then
    echo "    FAIL $chart renders policies with enabled=false"
    status=1
  fi
done

if [ "$status" -eq 0 ]; then
  echo "    network policy checks passed"
fi
exit "$status"
