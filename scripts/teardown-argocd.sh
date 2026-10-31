#!/usr/bin/env bash
# Removes Argo CD from a cluster, after scripts/teardown-prep.sh and before terraform destroy. Argo CD removes
# itself when platform-root is deleted (the argocd Application is part of what platform-root manages), and
# that leaves the argocd Application and the AppProjects holding the finalizer
# resources-finalizer.argocd.argoproj.io with no controller left to clear it. This script deletes what is
# left in the right order and clears that one finalizer when nothing else can.
#
#   scripts/teardown-argocd.sh --context CONTEXT [--timeout SECONDS] [--dry-run]
#
# Steps, in this order. Each one waits for its result and the script stops at the first step that does not
# complete within the timeout; nothing later runs after a failure.
#
#   1. refuse to start (also in a dry run) while kubectl get pv lists a volume or a claim exists in the data
#      namespace; run scripts/teardown-prep.sh first
#   2. delete the namespaces data, shop and observability, if they exist, and wait until they are gone
#   3. delete the storage class platform-data, if it exists
#   4. delete the Application platform-root, then the ApplicationSets in the argocd namespace
#   5. wait until no Application is left in the argocd namespace
#   6. helm uninstall argocd (a release that is not found is fine; the Argo CD CRDs are kept, they go with
#      the cluster)
#   7. wait until the Argo CD application controller has no running pod
#   8. remove the Argo CD finalizer from any AppProject left in the argocd namespace
#   9. delete the argocd namespace and wait until it is gone
#
# Anything that is already gone is skipped. Nothing is forced: a deletion that does not finish is reported
# and the script stops. It deletes no cloud resource; terraform destroy is the next, separate step.
#
# The one finalizer this script removes. Applications and AppProjects carry
# resources-finalizer.argocd.argoproj.io, and only the Argo CD application controller removes it. In step 5,
# if the controller has no running pod and an Application is stuck on it (it has a deletion timestamp), the
# script says so and removes that one finalizer from that one Application with a JSON patch whose first
# operation tests the finalizer value at its position, so nothing else can change. With the controller
# running it only waits. In step 8 the controller is gone, and the same patch is applied to each AppProject
# that still has the finalizer. Any other finalizer, on these or on any other object, is never touched.
#
# Options:
#   --context CONTEXT   kubectl context of the cluster; required (it is also the helm kube-context)
#   --timeout SECONDS   time each step may take (default 600)
#   --dry-run           print what would run, run no change; read-only kubectl queries are still used to name
#                       the resources
#   -h, --help          show this help
#
# Environment: TEARDOWN_POLL_SECONDS sets the wait between checks (default 5).
# Exit status: 0 done, 1 refused, or a step failed or timed out, 2 bad arguments.
set -euo pipefail

CONTEXT=""
DRY_RUN=0
TIMEOUT=600
POLL="${TEARDOWN_POLL_SECONDS:-5}"

ARGO_NS="argocd"
ARGO_RELEASE="argocd"
ARGO_FINALIZER="resources-finalizer.argocd.argoproj.io"
ARGO_CONTROLLER_SELECTOR="app.kubernetes.io/name=argocd-application-controller"
ROOT_APP="platform-root"
DATA_NS="data"
STORAGE_CLASS="platform-data"
WORKLOAD_NAMESPACES="data shop observability"

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

usage_error() {
  printf 'error: %s\n' "$*" >&2
  usage >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --context)
      [ "$#" -ge 2 ] || usage_error "--context needs a value"
      CONTEXT="$2"
      shift 2
      ;;
    --timeout)
      [ "$#" -ge 2 ] || usage_error "--timeout needs a value"
      TIMEOUT="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) usage_error "unknown argument: $1" ;;
  esac
done

[ -n "$CONTEXT" ] || usage_error "--context is required (the cluster is never taken from the current context)"
case "$TIMEOUT" in
  '' | *[!0-9]*) usage_error "--timeout must be a number of seconds" ;;
esac
case "$POLL" in
  '' | *[!0-9]* | 0) usage_error "TEARDOWN_POLL_SECONDS must be a positive number of seconds" ;;
esac

command -v kubectl > /dev/null 2>&1 || usage_error "kubectl is not installed"
if [ "$DRY_RUN" -eq 0 ]; then
  command -v helm > /dev/null 2>&1 || usage_error "helm is not installed"
fi

k() { kubectl --context "$CONTEXT" "$@"; }

TOTAL=9
n=0
DETAIL=""

fail() {
  printf '\nerror: %s\n' "$*" >&2
  printf 'Stopped. Nothing after this step was run. Fix the cause and run the script again; every step is safe to repeat.\n' >&2
  exit 1
}

# refuse MESSAGE: stop before anything is changed.
refuse() {
  printf '\nerror: %s\n' "$*" >&2
  printf 'Nothing was changed. Run scripts/teardown-prep.sh --context %s first, then run this script again.\n' "$CONTEXT" >&2
  exit 1
}

step() {
  n=$((n + 1))
  printf '\n[%s/%s] %s\n' "$n" "$TOTAL" "$1"
}

# run COMMAND...: show the command, run it unless this is a dry run, stop the script if it fails.
run() {
  if [ "$1" = k ]; then
    printf '  + kubectl --context %s %s\n' "$CONTEXT" "${*:2}"
  else
    printf '  + %s\n' "$*"
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "    dry run: not executed"
    return 0
  fi
  local out
  if out="$("$@" 2>&1)"; then
    [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/    /'
  else
    [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail "command failed or did not finish within ${TIMEOUT}s: $*"
  fi
}

# wait_for DESCRIPTION CHECK: polls the function CHECK until it succeeds; CHECK may set DETAIL.
wait_for() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  dry run: would wait until $1"
    return 0
  fi
  local waited=0
  while ! "$2"; do
    [ "$waited" -lt "$TIMEOUT" ] || fail "timed out after ${TIMEOUT}s waiting until $1.${DETAIL:+ Still present:
$DETAIL}"
    printf '  waiting (%ss of %ss): %s\n' "$waited" "$TIMEOUT" "$1"
    sleep "$POLL"
    waited=$((waited + POLL))
  done
  echo "  ok: $1"
}

# names_in NAMESPACE KIND...: object names (kind/name), one per line; fails if the query itself fails.
names_in() {
  local ns="$1"
  shift
  k -n "$ns" get "$@" -o name
}

namespace_present() { k get namespace "$1" -o name > /dev/null 2>&1; }

crd_present() { k get crd "$1" -o name > /dev/null 2>&1; }

# controller_running: succeeds when an Argo CD application controller pod is Running and fails when there is
# none. If the cluster cannot be asked, the script stops: a controller that cannot be seen is not one that is gone.
controller_running() {
  local out
  out="$(k -n "$ARGO_NS" get pods -l "$ARGO_CONTROLLER_SELECTOR" --field-selector=status.phase=Running -o name 2>&1)" ||
    fail "could not check whether the Argo CD application controller is running in namespace $ARGO_NS: $out"
  [ -n "$out" ]
}

# Checks used by wait_for. Each returns 0 when the condition holds and leaves what is still there in DETAIL.
WAIT_NAMESPACES=""

namespaces_gone() {
  local ns
  DETAIL=""
  for ns in $WAIT_NAMESPACES; do
    if namespace_present "$ns"; then DETAIL="${DETAIL:+$DETAIL
}namespace/$ns"; fi
  done
  if [ -n "$DETAIL" ]; then
    DETAIL="$DETAIL
A namespace stays in Terminating while something in it is not deleted. Look at: kubectl --context $CONTEXT get namespace <name> -o jsonpath='{.status.conditions}'"
    return 1
  fi
}

controller_gone() {
  if controller_running; then
    DETAIL="The Argo CD application controller still has a running pod in the $ARGO_NS namespace."
    return 1
  fi
}

# finalizer_position OBJECT: sets FINALIZERS (all of them, on one line) and POSITION (where ARGO_FINALIZER is in
# the list, counting from 1; empty when it is not there).
FINALIZERS=""
POSITION=""
finalizer_position() {
  local list
  list="$(k -n "$ARGO_NS" get "$1" -o 'jsonpath={range .metadata.finalizers[*]}{@}{"\n"}{end}' 2> /dev/null || true)"
  FINALIZERS="$(printf '%s' "$list" | tr '\n' ' ')"
  POSITION="$(printf '%s\n' "$list" | grep -nFx -- "$ARGO_FINALIZER" | head -n 1 | cut -d: -f1 || true)"
}

# clear_finalizer OBJECT: remove ARGO_FINALIZER, at POSITION, and nothing else. The first operation of the patch
# tests the value at that position, so a list that changed in the meantime makes the patch fail instead of
# removing something else.
clear_finalizer() {
  run k -n "$ARGO_NS" patch "$1" --type=json -p \
    "[{\"op\":\"test\",\"path\":\"/metadata/finalizers/$((POSITION - 1))\",\"value\":\"$ARGO_FINALIZER\"},{\"op\":\"remove\",\"path\":\"/metadata/finalizers/$((POSITION - 1))\"}]"
}

# The Applications whose finalizer has been removed during this run, one per line, so each is patched once.
CLEARED=""

# Check used by wait_for: no Application is left. For an Application that is being deleted and is stuck on the
# Argo CD finalizer, remove that finalizer, once, when the controller is not running.
apps_gone() {
  local out app stamp running lines=""
  out="$(k -n "$ARGO_NS" get applications.argoproj.io -o name 2> /dev/null)" || {
    DETAIL="could not list Applications"
    return 1
  }
  [ -n "$out" ] || return 0
  running="not running"
  if controller_running; then running="running"; fi
  while IFS= read -r app; do
    stamp="$(k -n "$ARGO_NS" get "$app" -o 'jsonpath={.metadata.deletionTimestamp}' 2> /dev/null || true)"
    finalizer_position "$app"
    if [ -z "$stamp" ]; then
      lines="${lines:+$lines
}$app
Finalizers: $FINALIZERS
It is not being deleted (no deletion timestamp), so its finalizers are left alone."
    elif [ "$running" = "running" ]; then
      lines="${lines:+$lines
}$app
Finalizers: $FINALIZERS
The Argo CD application controller is running, so it is expected to remove its finalizer; this script only waits."
    elif [ -n "$POSITION" ] && ! printf '%s\n' "$CLEARED" | grep -Fxq -- "$app"; then
      echo "  the Argo CD application controller is not running, so nothing is left to run the finalizer $ARGO_FINALIZER on $app."
      echo "  Removing that finalizer from $app only; no other finalizer or object is changed."
      clear_finalizer "$app"
      CLEARED="${CLEARED:+$CLEARED
}$app"
      lines="${lines:+$lines
}$app
The finalizer $ARGO_FINALIZER was just removed"
    else
      lines="${lines:+$lines
}$app
Finalizers: $FINALIZERS
The Argo CD application controller is not running. This script removes only the finalizer $ARGO_FINALIZER, once per Application. It changed nothing else on $app."
    fi
  done << EOF
$out
EOF
  DETAIL="$lines"
  return 1
}

echo "Argo CD removal for the cluster in kubectl context: $CONTEXT"
[ "$DRY_RUN" -eq 0 ] || echo "DRY RUN: no change is made."

# Refuse to guess: the context must exist.
k config get-contexts -o name > /dev/null 2>&1 || usage_error "kubectl could not read its configuration"
if ! k config get-contexts -o name 2> /dev/null | grep -Fxq -- "$CONTEXT"; then
  usage_error "kubectl context '$CONTEXT' does not exist (see: kubectl config get-contexts)"
fi

step "Check that scripts/teardown-prep.sh has run: no persistent volume and no claim in the $DATA_NS namespace"
pvs="$(k get pv -o name 2> /dev/null)" || fail "could not list persistent volumes"
pvcs="$(names_in "$DATA_NS" persistentvolumeclaims 2> /dev/null)" || fail "could not list claims in the $DATA_NS namespace"
if [ -n "$pvs" ] || [ -n "$pvcs" ]; then
  [ -z "$pvs" ] || printf '%s\n' "$pvs" | sed 's/^/  persistent volume: /' >&2
  [ -z "$pvcs" ] || printf '%s\n' "$pvcs" | sed 's/^/  claim in the data namespace: /' >&2
  refuse "the cluster still holds volumes or claims. Removing Argo CD now could leave them behind, billing, after terraform destroy."
fi
echo "  ok: kubectl get pv lists nothing and the $DATA_NS namespace has no claims"

step "Delete the namespaces $WORKLOAD_NAMESPACES, if they exist"
WAIT_NAMESPACES=""
for ns in $WORKLOAD_NAMESPACES; do
  if namespace_present "$ns"; then
    run k delete namespace "$ns" --wait=false
    WAIT_NAMESPACES="${WAIT_NAMESPACES:+$WAIT_NAMESPACES }$ns"
  else
    echo "  no $ns namespace: nothing to delete"
  fi
done
if [ -n "$WAIT_NAMESPACES" ]; then
  wait_for "the namespaces $WAIT_NAMESPACES are gone" namespaces_gone
fi

step "Delete the storage class $STORAGE_CLASS, if it exists"
if k get storageclass "$STORAGE_CLASS" -o name > /dev/null 2>&1; then
  run k delete storageclass "$STORAGE_CLASS" --wait=true --timeout="${TIMEOUT}s"
else
  echo "  no storage class $STORAGE_CLASS: nothing to delete"
fi

step "Delete the Application $ROOT_APP, then the ApplicationSets, in the $ARGO_NS namespace"
if crd_present applications.argoproj.io; then
  root="$(k -n "$ARGO_NS" get "application.argoproj.io/$ROOT_APP" --ignore-not-found -o name)" || fail "could not query the Application $ROOT_APP"
  if [ -n "$root" ]; then
    run k -n "$ARGO_NS" delete "$root" --wait=false
  else
    echo "  no Application $ROOT_APP in the $ARGO_NS namespace"
  fi
else
  echo "  the applications.argoproj.io CRD is not installed: nothing to delete"
fi
if crd_present applicationsets.argoproj.io; then
  sets="$(names_in "$ARGO_NS" applicationsets.argoproj.io)" || fail "could not list ApplicationSets in the $ARGO_NS namespace"
  if [ -z "$sets" ]; then
    echo "  no ApplicationSet in the $ARGO_NS namespace"
  else
    while IFS= read -r appset; do
      run k -n "$ARGO_NS" delete "$appset" --ignore-not-found --wait=false
    done << EOF
$sets
EOF
  fi
else
  echo "  the applicationsets.argoproj.io CRD is not installed: nothing to delete"
fi

step "Wait for the Applications in the $ARGO_NS namespace to be deleted"
if ! crd_present applications.argoproj.io; then
  echo "  the applications.argoproj.io CRD is not installed: nothing to wait for"
else
  if [ "$DRY_RUN" -eq 1 ]; then
    if controller_running; then
      echo "  dry run: the Argo CD application controller is running; would wait for the Applications to be deleted"
    else
      echo "  dry run: the Argo CD application controller is not running; if an Application stays stuck on the finalizer $ARGO_FINALIZER, would remove that one finalizer"
    fi
  fi
  wait_for "no Application remains in the $ARGO_NS namespace" apps_gone
fi

step "Uninstall the Helm release $ARGO_RELEASE (the Argo CD CRDs are kept)"
printf '  + helm --kube-context %s uninstall %s -n %s\n' "$CONTEXT" "$ARGO_RELEASE" "$ARGO_NS"
if [ "$DRY_RUN" -eq 1 ]; then
  echo "    dry run: not executed"
else
  if out="$(helm --kube-context "$CONTEXT" uninstall "$ARGO_RELEASE" -n "$ARGO_NS" 2>&1)"; then
    [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/    /'
  elif printf '%s\n' "$out" | grep -qi 'release: not found'; then
    printf '%s\n' "$out" | sed 's/^/    /'
    echo "  the release $ARGO_RELEASE is not installed: nothing to uninstall"
  else
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail "command failed: helm --kube-context $CONTEXT uninstall $ARGO_RELEASE -n $ARGO_NS"
  fi
fi

step "Wait for the Argo CD application controller to be gone"
wait_for "the Argo CD application controller has no running pod" controller_gone

step "Remove the Argo CD finalizer from the AppProjects that are left"
if crd_present appprojects.argoproj.io; then
  projects="$(names_in "$ARGO_NS" appprojects.argoproj.io)" || fail "could not list AppProjects in the $ARGO_NS namespace"
  if [ -z "$projects" ]; then
    echo "  no AppProject in the $ARGO_NS namespace"
  else
    while IFS= read -r project; do
      finalizer_position "$project"
      if [ -n "$POSITION" ]; then
        echo "  $project still has the finalizer $ARGO_FINALIZER and the controller that would remove it is gone."
        echo "  Removing that finalizer from $project only; no other finalizer or object is changed."
        clear_finalizer "$project"
      else
        echo "  $project does not have the finalizer $ARGO_FINALIZER: left as it is"
      fi
    done << EOF
$projects
EOF
  fi
else
  echo "  the appprojects.argoproj.io CRD is not installed: nothing to do"
fi

step "Delete the $ARGO_NS namespace"
if namespace_present "$ARGO_NS"; then
  run k delete namespace "$ARGO_NS" --wait=false
  WAIT_NAMESPACES="$ARGO_NS"
  wait_for "the $ARGO_NS namespace is gone" namespaces_gone
else
  echo "  no $ARGO_NS namespace: nothing to delete"
fi

echo
if [ "$DRY_RUN" -eq 1 ]; then
  echo "Dry run finished. Nothing was changed."
else
  echo "Argo CD is removed. The data, shop and observability namespaces, the storage class and the argocd namespace are gone;"
  echo "the Argo CD CRDs are left and go with the cluster."
  echo "Next: terraform destroy (docs/runbooks/aws-eks.md)."
fi
