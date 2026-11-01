#!/usr/bin/env bash
# Offline checks for the service deployment: the shared chart in deploy/helm/service, its values, and the
# RabbitMQ credential copy chart in platform/data/rabbitmq-credentials.
#
#   1. helm lint --strict and helm template for every service under every values profile (memory, data) and
#      cloud (aws, gcp), plus extra renders with the optional features on (ingress, certificate,
#      ServiceMonitor, scrape annotations, internal load balancer) so those templates are checked too
#   2. kubeconform against the Kubernetes version each cloud runs; custom resources (Certificate,
#      ServiceMonitor, BackendConfig) against CRD schemas from a pinned commit of datreeio/CRDs-catalog
#   3. security properties of the rendered output, not only schema validity (scripts/rendered-security-check.py):
#      non-root numeric user, no privilege escalation, all capabilities dropped, seccomp profile, resource
#      limits, read-only root filesystem, no host namespaces or hostPath, no privileged containers, no mounted
#      service account token (except the credential copier), no LoadBalancer or NodePort Service, no secret
#      values, no :latest images. A failure names the offending resource.
#   4. the image values file has a registry and a tag, and (scripts/chart-contract-check.py, run on every render)
#      no Job that creates Secrets is a Helm hook and the credential copy chart is not hooks only
#   5. network policies (scripts/chart-contract-check.py network-policies): every pod of every service render is covered by a
#      default deny for ingress and egress, the allows are applied before the deny, nothing is open to a whole range, and
#      an enabled ingress needs the load balancer's source range
#   6. yamllint on the non-template files, and shellcheck through scripts/shellcheck.sh
#
# Tools that are not installed are skipped with a message. Nothing is installed in a cluster.
#
# Environment:
#   EKS_KUBERNETES_VERSION  schema version for aws (default 1.37.0)
#   GKE_KUBERNETES_VERSION  schema version for gcp (default 1.36.0)
#   CRD_CATALOG_REF         commit of datreeio/CRDs-catalog
set -euo pipefail

usage() {
  echo "Usage: $0"
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

cd "$(dirname "${BASH_SOURCE[0]}")/.."
have() { command -v "$1" > /dev/null 2>&1; }

chart="deploy/helm/service"
values="deploy/helm/values"
creds_chart="platform/data/rabbitmq-credentials"
services="gateway orders payments notifier"
profiles="memory data"
eks_version="${EKS_KUBERNETES_VERSION:-1.37.0}"
gke_version="${GKE_KUBERNETES_VERSION:-1.36.0}"
crd_catalog_ref="${CRD_CATALOG_REF:-3eb90d47aba8d61919d4419dd38301536e32a94b}"
crd_catalog="https://raw.githubusercontent.com/datreeio/CRDs-catalog/${crd_catalog_ref}/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"

status=0

if ! have helm; then
  echo "helm not installed; skipping the chart checks"
else
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  export HELM_CONFIG_HOME="$work/config" HELM_CACHE_HOME="$work/cache" HELM_DATA_HOME="$work/data"

  # A Python with PyYAML for the security check: the one yamllint runs on has it.
  py=""
  if python3 -c 'import yaml' > /dev/null 2>&1; then
    py="python3"
  elif have yamllint; then
    candidate="$(head -n 1 "$(command -v yamllint)" | sed 's/^#!//')"
    "$candidate" -c 'import yaml' > /dev/null 2>&1 && py="$candidate"
  fi
  [ -n "$py" ] || echo "no Python with PyYAML found (installing yamllint provides it); the security checks will fail"

  schema_version() {
    case "$1" in
      aws) echo "$eks_version" ;;
      gcp) echo "$gke_version" ;;
    esac
  }

  # validate LABEL CLOUD FILE: kubeconform and the security check on a rendered manifest.
  validate() {
    local label="$1" cloud="$2" file="$3"
    if have kubeconform; then
      kubeconform -strict -summary -kubernetes-version "$(schema_version "$cloud")" \
        -schema-location default -schema-location "$crd_catalog" "$file" > "$work/kubeconform.out" 2>&1 || {
        echo "    FAIL [$label] kubeconform"
        cat "$work/kubeconform.out"
        status=1
      }
    fi
    if [ -n "$py" ]; then
      "$py" scripts/rendered-security-check.py "$label" < "$file" || status=1
      "$py" scripts/chart-contract-check.py secret-jobs "$label" < "$file" || status=1
    else
      status=1
    fi
  }

  echo "==> helm lint"
  for svc in $services; do
    for profile in $profiles; do
      helm lint --strict "$chart" -f "$values/images.yaml" -f "$values/$svc.yaml" -f "$values/$svc-$profile.yaml" \
        > "$work/lint.out" 2>&1 || {
        echo "    FAIL [$svc-$profile] helm lint"
        cat "$work/lint.out"
        status=1
      }
    done
  done
  helm lint --strict "$creds_chart" > "$work/lint.out" 2>&1 || {
    echo "    FAIL [rabbitmq-credentials] helm lint"
    cat "$work/lint.out"
    status=1
  }

  echo "==> render, schema and security checks"
  count=0
  for cloud in aws gcp; do
    for svc in $services; do
      for profile in $profiles; do
        args=(-f "$values/images.yaml" -f "$values/$svc.yaml" -f "$values/$svc-$profile.yaml")
        [ "$svc" != "gateway" ] || args+=(-f "$values/cloud-$cloud.yaml")
        label="$svc/$profile/$cloud"
        if helm template "$svc" "$chart" --namespace shop "${args[@]}" > "$work/render.yaml" 2> "$work/render.err"; then
          validate "$label" "$cloud" "$work/render.yaml"
          [ -z "$py" ] || "$py" scripts/chart-contract-check.py network-policies "$label" < "$work/render.yaml" || status=1
        else
          echo "    FAIL [$label] helm template"
          cat "$work/render.err"
          status=1
        fi
        count=$((count + 1))
      done
    done

    # Optional features, on the gateway where the ingress lives: every combination must render and pass.
    for scheme in internet-facing internal; do
      label="gateway/data/$cloud/features-$scheme"
      if helm template gateway "$chart" --namespace shop \
        -f "$values/images.yaml" -f "$values/gateway.yaml" -f "$values/gateway-data.yaml" -f "$values/cloud-$cloud.yaml" \
        --set ingress.enabled=true --set ingress.scheme="$scheme" --set ingress.host=shop.example.test \
        --set certificate.enabled=true --set metrics.serviceMonitor.enabled=true --set metrics.scrapeAnnotations=true \
        --set 'networkPolicy.ingressCidrs[0]=192.0.2.0/24' \
        > "$work/render.yaml" 2> "$work/render.err"; then
        validate "$label" "$cloud" "$work/render.yaml"
        [ -z "$py" ] || "$py" scripts/chart-contract-check.py network-policies "$label" < "$work/render.yaml" || status=1
        if ! grep -q 'name: gateway-allow-load-balancer' "$work/render.yaml"; then
          echo "    FAIL [$label] the enabled ingress has no network policy for the load balancer"
          status=1
        fi
        # The ingress must not make the Service itself reachable from outside.
        if grep -Eq 'type: (LoadBalancer|NodePort)' "$work/render.yaml"; then
          echo "    FAIL [$label] a Service is exposed"
          status=1
        fi
      else
        echo "    FAIL [$label] helm template"
        cat "$work/render.err"
        status=1
      fi
      count=$((count + 1))
    done

    if helm template data-rabbitmq-credentials "$creds_chart" --namespace shop > "$work/render.yaml" 2> "$work/render.err"; then
      validate "rabbitmq-credentials/$cloud" "$cloud" "$work/render.yaml"
      # The copy is a hook Job: the chart must also render something ordinary, or Argo CD never syncs it.
      if [ -n "$py" ]; then
        "$py" scripts/chart-contract-check.py hooks "rabbitmq-credentials/$cloud" < "$work/render.yaml" || status=1
      fi
    else
      echo "    FAIL [rabbitmq-credentials/$cloud] helm template"
      cat "$work/render.err"
      status=1
    fi
    count=$((count + 1))
  done
  echo "    rendered and checked $count manifest set(s)"

  # The ingress must refuse to render without a cloud, and the chart must not render a Secret.
  if helm template gateway "$chart" -f "$values/gateway.yaml" --set ingress.enabled=true > /dev/null 2>&1; then
    echo "    FAIL the ingress rendered without ingress.cloud"
    status=1
  fi

  # With the ingress on, the load balancer's source range is required: without it the default deny would drop the traffic.
  if helm template gateway "$chart" -f "$values/gateway.yaml" -f "$values/cloud-aws.yaml" --set ingress.enabled=true --set ingress.host=shop.example.test > /dev/null 2>&1; then
    echo "    FAIL the ingress rendered without networkPolicy.ingressCidrs"
    status=1
  fi

  echo "==> image values"
  if ! grep -Eq '^  registry: [a-z0-9./-]+$' "$values/images.yaml" || ! grep -Eq '^  tag: "?[^" ]+"?$' "$values/images.yaml"; then
    echo "    FAIL $values/images.yaml needs image.registry (lower case) and image.tag"
    status=1
  fi
fi

echo "==> yamllint"
if have yamllint; then
  yamllint --strict deploy platform/data/rabbitmq-credentials platform/argocd || status=1
else
  echo "yamllint not installed; skipping yaml lint"
fi

echo "==> shellcheck"
./scripts/shellcheck.sh || status=1

exit "$status"
