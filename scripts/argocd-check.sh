#!/usr/bin/env bash
# Offline checks for the Argo CD hub and its GitOps definitions under platform/argocd.
#
#   1. helm lint, helm template and kubeconform on the install chart (default and HA values)
#   2. kubeconform on the Application, ApplicationSet and AppProject files, with the Argo CD CRD
#      schemas taken from a pinned commit of the datreeio CRDs-catalog
#   3. yamllint on platform/argocd
#   4. shellcheck on scripts/*.sh
#   5. a render test: every path and values file an Application or ApplicationSet refers to must
#      exist, every project must be defined, and every templated Helm parameter must change the
#      rendered output of the chart it targets (which catches misspelt parameter names)
#      and none of those paths, nor any file under them, may be matched by a .gitignore rule
#      (scripts/gitignore-match.sh: file reads and pattern matching only; see its header for the limits)
#
# Tools that are not installed are skipped with a message. Nothing is installed in a cluster.
#
# Environment:
#   KUBERNETES_VERSION  schema version for the hub, which runs on EKS (default 1.37.0)
#   CRD_CATALOG_REF     commit of datreeio/CRDs-catalog for the Argo CD CRD schemas
set -euo pipefail

usage() {
  echo "Usage: $0 [argocd-root]   (default: platform/argocd)"
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

root="${1:-platform/argocd}"
k8s_version="${KUBERNETES_VERSION:-1.37.0}"
# Pinned commit of the CRDs-catalog (checked 2026-10-26).
crd_catalog_ref="${CRD_CATALOG_REF:-3eb90d47aba8d61919d4419dd38301536e32a94b}"
crd_catalog="https://raw.githubusercontent.com/datreeio/CRDs-catalog/${crd_catalog_ref}/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"

have() { command -v "$1" > /dev/null 2>&1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export HELM_CONFIG_HOME="$work/config" HELM_CACHE_HOME="$work/cache" HELM_DATA_HOME="$work/data"

status=0

# Add the chart repositories a chart depends on and fetch its dependencies into charts/.
build_dependencies() {
  local dir="$1" repo
  grep -q '^dependencies:' "$dir/Chart.yaml" || return 0
  while IFS= read -r repo; do
    helm repo add "r$(printf '%s' "$repo" | cksum | cut -d' ' -f1)" "$repo" > /dev/null
  done < <(sed -n 's/^ *repository: *//p' "$dir/Chart.yaml")
  helm dependency build "$dir" > /dev/null
}

kubeconform_run() {
  # kubeconform_run FILE_OR_DIR...
  kubeconform -strict -summary -skip CustomResourceDefinition -kubernetes-version "$k8s_version" \
    -schema-location default -schema-location "$crd_catalog" "$@"
}

# --- 1. install chart ---

if have helm && have kubeconform; then
  install_dir="$root/install"
  echo "==> install chart"
  build_dependencies "$install_dir"
  if ! helm lint --strict "$install_dir" -f "$install_dir/values.yaml" > "$work/lint.out" 2>&1; then
    cat "$work/lint.out"
    status=1
  fi
  for profile in default ha; do
    if [ "$profile" = "ha" ]; then
      helm template argocd "$install_dir" --namespace argocd \
        -f "$install_dir/values.yaml" -f "$install_dir/values-ha.yaml" > "$work/install.yaml" || status=1
    else
      helm template argocd "$install_dir" --namespace argocd -f "$install_dir/values.yaml" > "$work/install.yaml" || status=1
    fi
    echo "    rendered profile: $profile"
    kubeconform_run "$work/install.yaml" || status=1
  done

  # --- 2. Applications, ApplicationSets and AppProjects ---

  echo "==> Applications, ApplicationSets and AppProjects"
  kubeconform_run "$root/bootstrap" "$root/apps" || status=1
else
  echo "helm or kubeconform not installed; skipping chart rendering and schema checks"
fi

# --- 3. yamllint ---

if have yamllint; then
  echo "==> yamllint $root"
  yamllint --strict "$root" || status=1
else
  echo "yamllint not installed; skipping yaml lint"
fi

# --- 4. shellcheck ---

# Same flags and version as CI: see scripts/shellcheck.sh.
echo "==> shellcheck scripts"
./scripts/shellcheck.sh || status=1

# --- 5. render test (references and parameters) ---

# Print "KIND value" lines describing what an Application or ApplicationSet file refers to.
scan_file() {
  awk '
    function strip(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); gsub(/^[\047"]|[\047"]$/, "", s); return s }
    /^[[:space:]]*path:[[:space:]]/ { sub(/^[[:space:]]*path:[[:space:]]*/, ""); print "PATH " strip($0); next }
    /^[[:space:]]*project:[[:space:]]/ { sub(/^[[:space:]]*project:[[:space:]]*/, ""); print "PROJECT " strip($0); next }
    /platform\.example\/cloud:[[:space:]]*(aws|gcp)[[:space:]]*$/ { sub(/.*cloud:[[:space:]]*/, ""); print "CLOUD " strip($0); next }
    /^[[:space:]]*valueFiles:[[:space:]]*$/ { invf = 1; next }
    invf && /^[[:space:]]*-[[:space:]]/ { sub(/^[[:space:]]*-[[:space:]]*/, ""); print "VALUEFILE " strip($0); next }
    { invf = 0 }
    /^[[:space:]]*-[[:space:]]name:[[:space:]]/ { sub(/^[[:space:]]*-[[:space:]]name:[[:space:]]*/, ""); pname = strip($0); next }
    /^[[:space:]]*value:[[:space:]]/ && pname != "" {
      v = $0; sub(/^[[:space:]]*value:[[:space:]]*/, "", v)
      if (v ~ /\{\{/) print "PARAM " pname; else print "STATICPARAM " pname "=" strip(v)
      pname = ""
    }
  ' "$1"
}

echo "==> render test: references and parameters"

# Every path an Application or ApplicationSet refers to (and every file under it) is collected here and then
# compared with the .gitignore rules, so a rule that hides a chart from Git fails here instead of in CI.
refs="$work/refs.txt"
: > "$refs"
./scripts/gitignore-match.sh --self-test > /dev/null || {
  echo "    the .gitignore matcher failed its self-test"
  status=1
}

if have helm; then
  # Projects that are defined in bootstrap/.
  projects=" "
  for f in "$root"/bootstrap/appproject-*.yaml; do
    [ -e "$f" ] || continue
    projects="$projects$(awk '/^metadata:/{m=1;next} m&&/^  name:/{print $2; exit}' "$f") "
  done

  checked=0
  for f in "$root"/apps/*.yaml "$root"/bootstrap/root-application.yaml; do
    [ -e "$f" ] || continue
    checked=$((checked + 1))
    scan_file "$f" > "$work/scan.txt"

    path=""
    clouds=""
    valuefiles=""
    params=""
    statics=""
    project=""
    while IFS= read -r line; do
      kind="${line%% *}"
      val="${line#* }"
      case "$kind" in
        PATH) path="$val" ;;
        PROJECT) project="$val" ;;
        CLOUD) clouds="$clouds $val" ;;
        VALUEFILE) valuefiles="$valuefiles
$val" ;;
        PARAM) params="$params
$val" ;;
        STATICPARAM) statics="$statics
$val" ;;
      esac
    done < "$work/scan.txt"

    if [ -n "$project" ] && [ -n "${projects# }" ]; then
      case "$projects" in
        *" $project "*) ;;
        *)
          echo "    $f: project '$project' is not defined in $root/bootstrap"
          status=1
          ;;
      esac
    fi

    [ -n "$path" ] || continue
    if [ ! -d "$path" ]; then
      echo "    $f: path '$path' does not exist"
      status=1
      continue
    fi

    printf 'd %s\n' "$path" >> "$refs"
    # Locally downloaded chart dependencies (charts/) are ignored on purpose and are not committed.
    find "$path" -type f -not -path '*/charts/*' | sed 's/^/f /' >> "$refs"

    # Templated value file names resolve to the cloud(s) the file selects; default to both.
    [ -n "$clouds" ] || clouds=" aws gcp"
    set_args=""
    for cloud in $clouds; do
      values_args=""
      while IFS= read -r vf; do
        [ -n "$vf" ] || continue
        # A data-profile placeholder stands for the standard and ha profiles: both files must exist, and the
        # standard one is used for the render below. Any other placeholder stands for the cloud.
        case "$vf" in
          *data-profile*) profiles="standard ha" ;;
          *) profiles="-" ;;
        esac
        for profile in $profiles; do
          resolved="$(printf '%s' "$vf" | sed -e "s/{{[^}]*data-profile[^}]*}}/$profile/g" -e "s/{{[^}]*}}/$cloud/g")"
          if [ ! -f "$path/$resolved" ]; then
            echo "    $f: values file '$path/$resolved' does not exist"
            status=1
          elif [ "$profile" = "-" ] || [ "$profile" = "standard" ]; then
            values_args="$values_args -f $path/$resolved"
          fi
        done
      done << EOF
$valuefiles
EOF

      # Every templated parameter must take effect when the chart is rendered with it set.
      [ -n "$params" ] || [ -n "$statics" ] || continue
      build_dependencies "$path"
      i=0
      tokens=""
      set_args=""
      while IFS= read -r pname; do
        [ -n "$pname" ] || continue
        i=$((i + 1))
        case "$pname" in
          *.enabled)
            set_args="$set_args --set $pname=true"
            ;;
          *)
            set_args="$set_args --set-string $pname=ARGOCD_CHECK_TOKEN_$i"
            tokens="$tokens ARGOCD_CHECK_TOKEN_$i=$pname"
            ;;
        esac
      done << EOF
$params
EOF
      while IFS= read -r sp; do
        [ -n "$sp" ] || continue
        set_args="$set_args --set ${sp%%=*}=${sp#*=}"
      done << EOF
$statics
EOF
      # shellcheck disable=SC2086
      if ! helm template check "$path" $values_args $set_args > "$work/param-render.yaml" 2> "$work/param-render.err"; then
        echo "    $f [$cloud]: chart does not render with the ApplicationSet parameters"
        cat "$work/param-render.err"
        status=1
        continue
      fi
      for entry in $tokens; do
        if ! grep -qF "${entry%%=*}" "$work/param-render.yaml"; then
          echo "    $f [$cloud]: parameter '${entry#*=}' has no effect on the rendered chart (misspelt name?)"
          status=1
        fi
      done
    done
  done
  ignored="$(sort -u "$refs" | ./scripts/gitignore-match.sh)"
  if [ -n "$ignored" ]; then
    while IFS= read -r line; do
      echo "    $line"
    done << EOF
$ignored
EOF
    echo "    the paths above are referenced by an Application or ApplicationSet but matched by .gitignore:"
    echo "    they would not be committed, and Argo CD could not find them. Narrow the .gitignore rule."
    status=1
  fi
  echo "    checked $checked Application and ApplicationSet file(s)"
else
  echo "helm not installed; skipping the render test"
fi

exit "$status"
