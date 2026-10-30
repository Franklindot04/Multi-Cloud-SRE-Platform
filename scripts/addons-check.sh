#!/usr/bin/env bash
# Lint, render and schema-check every add-on under platform/addons for each cloud it targets.
#
# Per add-on and cloud this runs: helm lint, helm template, and kubeconform against the
# Kubernetes version that cloud's cluster runs. Files named ci/<cloud>-*.yaml are extra value
# sets that switch on optional features so those manifests are checked too. A file named
# ci/<cloud>-params.yaml is layered into every render for that cloud: it holds fixture values for
# the identifiers that Argo CD supplies from the cluster secret, so charts that require them render. yamllint runs over
# the values files. Nothing is installed in a cluster.
#
# Environment:
#   EKS_KUBERNETES_VERSION  schema version for aws (default 1.37.0)
#   GKE_KUBERNETES_VERSION  schema version for gcp (default 1.36.0)
#   ADDONS_UPDATE=1         refresh Chart.lock files instead of checking
set -euo pipefail

usage() {
  echo "Usage: $0 [addons-root]   (default: platform/addons)"
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

root="${1:-platform/addons}"
eks_version="${EKS_KUBERNETES_VERSION:-1.37.0}"
gke_version="${GKE_KUBERNETES_VERSION:-1.36.0}"
# CRD schemas are pinned to a commit of the datreeio CRDs-catalog (checked 2026-10-26).
crd_catalog_ref="${CRD_CATALOG_REF:-3eb90d47aba8d61919d4419dd38301536e32a94b}"
crd_catalog="https://raw.githubusercontent.com/datreeio/CRDs-catalog/${crd_catalog_ref}/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"

missing=""
for tool in helm kubeconform; do
  command -v "$tool" > /dev/null 2>&1 || missing="$missing $tool"
done
if [ -n "$missing" ]; then
  echo "missing tools:$missing; skipping add-on checks"
  exit 0
fi

# Isolated Helm state so local repositories and caches are never touched.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export HELM_CONFIG_HOME="$work/config" HELM_CACHE_HOME="$work/cache" HELM_DATA_HOME="$work/data"

schema_version() {
  case "$1" in
    aws) echo "$eks_version" ;;
    gcp) echo "$gke_version" ;;
    *)
      echo "unknown cloud: $1" >&2
      exit 1
      ;;
  esac
}

status=0
count=0

for chart_file in "$root"/*/Chart.yaml; do
  [ -e "$chart_file" ] || continue
  dir="$(dirname "$chart_file")"
  name="$(basename "$dir")"
  clouds="$(sed -n 's/^  platform\/clouds: *"\{0,1\}\([a-z,]*\)"\{0,1\} *$/\1/p' "$chart_file" | tr ',' ' ')"
  [ -n "$clouds" ] || clouds="aws gcp"

  if grep -q '^dependencies:' "$chart_file"; then
    while IFS= read -r repo; do
      helm repo add "r$(printf '%s' "$repo" | cksum | cut -d' ' -f1)" "$repo" > /dev/null
    done < <(sed -n 's/^ *repository: *//p' "$chart_file")
    if [ "${ADDONS_UPDATE:-0}" = "1" ]; then
      echo "==> $name: updating Chart.lock"
      helm dependency update "$dir" > /dev/null
      continue
    fi
    helm dependency build "$dir" > /dev/null
  fi
  [ "${ADDONS_UPDATE:-0}" = "1" ] && continue

  for cloud in $clouds; do
    base=(-f "$dir/values.yaml")
    [ -f "$dir/values-$cloud.yaml" ] && base+=(-f "$dir/values-$cloud.yaml")

    [ -f "$dir/ci/$cloud-params.yaml" ] && base+=(-f "$dir/ci/$cloud-params.yaml")
    # Charts with deployment profiles: the standard profile is part of the base render and the HA profile
    # is rendered as an extra variant on top of it.
    [ -f "$dir/values-standard.yaml" ] && base+=(-f "$dir/values-standard.yaml")

    variants=("")
    [ -f "$dir/values-ha.yaml" ] && variants+=("$dir/values-ha.yaml")
    # An optional feature that is off by default and switched on by adding this file (for example persistent volumes).
    [ -f "$dir/values-persistent.yaml" ] && variants+=("$dir/values-persistent.yaml")
    for extra in "$dir"/ci/"$cloud"-*.yaml; do
      [ -e "$extra" ] || continue
      [ "$(basename "$extra")" = "$cloud-params.yaml" ] && continue
      variants+=("$extra")
    done

    for extra in "${variants[@]}"; do
      args=("${base[@]}")
      label="$name [$cloud]"
      if [ -n "$extra" ]; then
        args+=(-f "$extra")
        label="$label + $(basename "$extra")"
      fi
      count=$((count + 1))
      echo "==> $label"
      if ! helm lint --strict "$dir" "${args[@]}" > "$work/lint.out" 2>&1; then
        cat "$work/lint.out"
        status=1
        continue
      fi
      if ! helm template "$name" "$dir" --namespace "$name" "${args[@]}" > "$work/rendered.yaml"; then
        status=1
        continue
      fi
      if [ ! -s "$work/rendered.yaml" ]; then
        echo "    renders no resources (feature disabled)"
        continue
      fi
      kubeconform -strict -summary -skip CustomResourceDefinition -kubernetes-version "$(schema_version "$cloud")" \
        -schema-location default -schema-location "$crd_catalog" "$work/rendered.yaml" || status=1
    done
  done
done

if [ "${ADDONS_UPDATE:-0}" != "1" ]; then
  if command -v yamllint > /dev/null 2>&1; then
    echo "==> yamllint $root"
    yamllint --strict "$root" || status=1
  else
    echo "yamllint not installed; skipping yaml lint"
  fi
  echo "checked $count add-on render(s)"
fi

exit "$status"
