#!/usr/bin/env bash
# Prepares a cluster for `terraform destroy`: removes what Argo CD and the data layer leave behind that
# Terraform does not manage (volumes, load balancers, security groups). Run it before terraform destroy.
#
#   scripts/teardown-prep.sh --context CONTEXT [--region REGION] [--cluster-name NAME] [--dry-run]
#
# Steps, in this order. Each one waits for its result and the script stops at the first step that does not
# complete within the timeout; nothing later runs after a failure.
#
#    1. remove the cluster Secret labels platform.example/apps, platform.example/data and
#       platform.example/observability (the label keys are deleted, not set to false), so the ApplicationSets stop
#       recreating Applications
#    2. wait until the apps-*, data-* and observability-* Applications are gone (this also removes the
#       CloudNativePG, RabbitMQ Cluster and Prometheus operators)
#    3. wait until the shop namespace holds no workloads
#    4. if the observability namespace exists, wait until it holds no pods
#    5. if it exists, delete its PersistentVolumeClaims (there are none unless values-persistent.yaml was used)
#    6. delete the CloudNativePG Database objects in the data namespace and wait for them
#    7. delete the CloudNativePG Clusters in the data namespace
#    8. delete the RabbitmqClusters in the data namespace and wait for them, then their StatefulSets if those
#       survive (the operator does not remove them)
#    9. wait until no pods are left in the data namespace
#   10. delete the PersistentVolumeClaims in the data namespace (including platform-valkey)
#   11. confirm kubectl get pv is empty
#   12. AWS: confirm no EBS volume tagged kubernetes.io/created-for/pvc/name remains, so only node root
#       volumes are left
#   13. AWS: confirm no load balancer created by the AWS Load Balancer Controller remains
#   14. AWS: confirm no security group created by the AWS Load Balancer Controller remains
#
# Deletions name the resource and the namespace (argocd, shop, data and observability are the only namespaces
# changed; cnpg-system and rabbitmq-system are only read, to see whether an operator is still running). Nothing is
# forced: a deletion that does not finish is reported and the script stops. It does not delete namespaces, the
# storage class, Argo CD or any cloud resource; terraform destroy is a separate, manual step.
#
# Finalizers of operators that are gone. Step 2 removes the operators, and a Database or a RabbitmqCluster
# carries a finalizer that only its operator removes. For these two kinds, and only these, steps 6 and 8 look
# at whether the operator is running while they wait:
#
#   Database          finalizer cnpg.io/deleteDatabase
#                     operator  pods labelled app.kubernetes.io/name=cloudnative-pg in cnpg-system
#   RabbitmqCluster   finalizer deletion.finalizers.rabbitmqclusters.rabbitmq.com
#                     operator  pods labelled app.kubernetes.io/name=rabbitmq-cluster-operator in rabbitmq-system
#
# If the operator has no running pod and the object, already deleted, is stuck on exactly that finalizer, the
# script removes that one finalizer from that one object, prints what it removed and why, and goes on. Any
# other finalizer, on these or on any other resource, is never touched: the script waits, times out and names
# what is holding the object. With the operator running it only waits.
#
# The Prometheus Operator needs no such handling here. The only finalizer it ever sets is
# monitoring.coreos.com/status-cleanup, on the Prometheus (and Alertmanager, ThanosRuler and PrometheusAgent)
# objects themselves, never on ServiceMonitors, PodMonitors or rules, and only when its feature gate
# StatusForConfigurationResources is on. The gate is off by default and platform/observability does not turn it
# on, so nothing holds these objects when the operator goes first. If the gate was switched on by hand and the
# finalizer is stuck, step 4 times out on the pods that remain and says so; this script does not remove that
# finalizer. The only thing the observability stack leaves behind that Terraform does not manage is the
# volumes of values-persistent.yaml, which step 5 deletes.
#
# Options:
#   --context CONTEXT     kubectl context of the cluster to prepare; required
#   --region REGION       AWS region for steps 12 to 14 (default: AWS_REGION, then AWS_DEFAULT_REGION)
#   --cluster-name NAME   only count load balancers and security groups tagged for this cluster (default: any
#                         created by the controller in the region)
#   --skip-aws            stop after step 11 (GKE, or no AWS credentials yet)
#   --timeout SECONDS     time each step may take (default 600)
#   --dry-run             print what would run, run no change, make no AWS call; read-only kubectl
#                         queries are still used to name the resources
#   -h, --help            show this help
#
# Environment: TEARDOWN_POLL_SECONDS sets the wait between checks (default 5).
# Exit status: 0 done, 1 a step failed or timed out, 2 bad arguments.
set -euo pipefail

CONTEXT=""
DRY_RUN=0
SKIP_AWS=0
TIMEOUT=600
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
CLUSTER_NAME=""
POLL="${TEARDOWN_POLL_SECONDS:-5}"

ARGO_NS="argocd"
CLUSTER_SECRET="cluster-in-cluster"
DATA_NS="data"
OBS_NS="observability"
SHOP_NS="shop"
CNPG_NS="cnpg-system"
CNPG_SELECTOR="app.kubernetes.io/name=cloudnative-pg"
CNPG_DB_FINALIZER="cnpg.io/deleteDatabase"
MQ_NS="rabbitmq-system"
MQ_SELECTOR="app.kubernetes.io/name=rabbitmq-cluster-operator"
MQ_FINALIZER="deletion.finalizers.rabbitmqclusters.rabbitmq.com"
LB_TAG="elbv2.k8s.aws/cluster"
PVC_TAG="kubernetes.io/created-for/pvc/name"

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
    --region)
      [ "$#" -ge 2 ] || usage_error "--region needs a value"
      REGION="$2"
      shift 2
      ;;
    --cluster-name)
      [ "$#" -ge 2 ] || usage_error "--cluster-name needs a value"
      CLUSTER_NAME="$2"
      shift 2
      ;;
    --timeout)
      [ "$#" -ge 2 ] || usage_error "--timeout needs a value"
      TIMEOUT="$2"
      shift 2
      ;;
    --skip-aws)
      SKIP_AWS=1
      shift
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
if [ "$SKIP_AWS" -eq 0 ] && [ -z "$REGION" ]; then
  usage_error "--region (or AWS_REGION) is required for the AWS checks; pass --skip-aws to leave them out"
fi

command -v kubectl > /dev/null 2>&1 || usage_error "kubectl is not installed"
if [ "$SKIP_AWS" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  command -v aws > /dev/null 2>&1 || usage_error "the AWS CLI is not installed; pass --skip-aws to leave the AWS checks out"
fi

k() { kubectl --context "$CONTEXT" "$@"; }

TOTAL=14
[ "$SKIP_AWS" -eq 0 ] || TOTAL=11
n=0
DETAIL=""

fail() {
  printf '\nerror: %s\n' "$*" >&2
  printf 'Stopped. Nothing after this step was run. Fix the cause and run the script again; every step is safe to repeat.\n' >&2
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

# Checks used by wait_for. Each returns 0 when the condition holds and leaves what is still there in DETAIL.
apps_gone() {
  local out
  out="$(k -n "$ARGO_NS" get applications.argoproj.io -o name 2> /dev/null)" || {
    DETAIL="could not list Applications"
    return 1
  }
  DETAIL="$(printf '%s\n' "$out" | grep -E '/(apps|data|observability)-' || true)"
  [ -z "$DETAIL" ]
}

shop_empty() {
  DETAIL="$(names_in "$SHOP_NS" deployments,statefulsets,jobs,ingresses,pods 2> /dev/null)" || {
    DETAIL="could not list the $SHOP_NS namespace"
    return 1
  }
  [ -z "$DETAIL" ]
}

data_pods_gone() {
  DETAIL="$(names_in "$DATA_NS" pods 2> /dev/null)" || {
    DETAIL="could not list pods in the $DATA_NS namespace"
    return 1
  }
  if [ -n "$DETAIL" ]; then
    DETAIL="$DETAIL
These pods have an owner this script does not delete. Find it with: kubectl --context $CONTEXT -n $DATA_NS get pod <name> -o jsonpath='{.metadata.ownerReferences}'"
    return 1
  fi
}

namespace_present() { k get namespace "$1" -o name > /dev/null 2>&1; }

obs_pods_gone() {
  DETAIL="$(names_in "$OBS_NS" pods 2> /dev/null)" || {
    DETAIL="could not list pods in the $OBS_NS namespace"
    return 1
  }
  if [ -n "$DETAIL" ]; then
    DETAIL="$DETAIL
Their Application is gone, so something still holds their owner. Look at the finalizers of the Prometheus objects: kubectl --context $CONTEXT -n $OBS_NS get prometheuses.monitoring.coreos.com -o yaml
A finalizer monitoring.coreos.com/status-cleanup is set by the Prometheus Operator only when its StatusForConfigurationResources feature gate is on, and only that operator removes it. This script does not remove it."
    return 1
  fi
}

no_obs_pvc() {
  DETAIL="$(names_in "$OBS_NS" persistentvolumeclaims 2> /dev/null)" || {
    DETAIL="could not list claims in the $OBS_NS namespace"
    return 1
  }
  [ -z "$DETAIL" ]
}

no_pvc() {
  DETAIL="$(names_in "$DATA_NS" persistentvolumeclaims 2> /dev/null)" || {
    DETAIL="could not list claims"
    return 1
  }
  [ -z "$DETAIL" ]
}

no_pv() {
  DETAIL="$(k get pv -o name 2> /dev/null)" || {
    DETAIL="could not list persistent volumes"
    return 1
  }
  [ -z "$DETAIL" ]
}

aws_empty() {
  # aws_empty OUTPUT: empty output, or the word None that older CLI versions print for an empty list.
  [ -z "$1" ] || [ "$1" = "None" ]
}

no_ebs_volumes() {
  DETAIL="$(aws --region "$REGION" ec2 describe-volumes --filters "Name=tag-key,Values=$PVC_TAG" \
    --query 'Volumes[].VolumeId' --output text 2> /dev/null)" || {
    DETAIL="the AWS call failed (credentials, region or permissions)"
    return 1
  }
  if aws_empty "$DETAIL"; then DETAIL=""; else return 1; fi
}

no_load_balancers() {
  local filter="Key=$LB_TAG"
  [ -z "$CLUSTER_NAME" ] || filter="$filter,Values=$CLUSTER_NAME"
  DETAIL="$(aws --region "$REGION" resourcegroupstaggingapi get-resources \
    --resource-type-filters elasticloadbalancing:loadbalancer --tag-filters "$filter" \
    --query 'ResourceTagMappingList[].ResourceARN' --output text 2> /dev/null)" || {
    DETAIL="the AWS call failed (credentials, region or permissions)"
    return 1
  }
  if aws_empty "$DETAIL"; then DETAIL=""; else return 1; fi
}

no_security_groups() {
  local filters
  filters=("Name=tag-key,Values=$LB_TAG")
  [ -z "$CLUSTER_NAME" ] || filters=("Name=tag:$LB_TAG,Values=$CLUSTER_NAME")
  DETAIL="$(aws --region "$REGION" ec2 describe-security-groups --filters "${filters[@]}" \
    --query 'SecurityGroups[].GroupId' --output text 2> /dev/null)" || {
    DETAIL="the AWS call failed (credentials, region or permissions)"
    return 1
  }
  if aws_empty "$DETAIL"; then DETAIL=""; else return 1; fi
}

crd_present() { k get crd "$1" -o name > /dev/null 2>&1; }

# delete_all KIND CRD: delete every object of KIND in the data namespace, by name, waiting for each.
delete_all() {
  local kind="$1" crd="$2" names name
  if ! crd_present "$crd"; then
    echo "  the $crd CRD is not installed: nothing to delete"
    return 0
  fi
  names="$(names_in "$DATA_NS" "$kind")" || fail "could not list $kind in the $DATA_NS namespace"
  if [ -z "$names" ]; then
    echo "  no $kind in the $DATA_NS namespace"
    return 0
  fi
  while IFS= read -r name; do
    run k -n "$DATA_NS" delete "$name" --wait=true --timeout="${TIMEOUT}s"
  done << EOF
$names
EOF
}

# operator_running NAMESPACE SELECTOR: succeeds when an operator pod is Running there and fails when there is
# none. If the cluster cannot be asked, the script stops: an operator that cannot be seen is not one that is gone.
operator_running() {
  local out
  out="$(k -n "$1" get pods -l "$2" --field-selector=status.phase=Running -o name 2>&1)" ||
    fail "could not check whether the operator ($2) is running in namespace $1: $out"
  [ -n "$out" ]
}

# The object delete_owned is waiting for, and the operator that owns its finalizer. owned_gone reads them.
OWNED=""
OWNED_FINALIZER=""
OWNED_OPERATOR=""
OWNED_NS=""
OWNED_SELECTOR=""
OWNED_CLEARED=0

# Check used by wait_for: the object is gone. While it is not, and its operator is not running, remove the one
# finalizer that operator would have removed (once) and say so.
owned_gone() {
  local present finalizers position running
  present="$(k -n "$DATA_NS" get "$OWNED" --ignore-not-found -o name 2>&1)" || {
    DETAIL="could not query $OWNED: $present"
    return 1
  }
  [ -n "$present" ] || return 0
  finalizers="$(k -n "$DATA_NS" get "$OWNED" -o 'jsonpath={range .metadata.finalizers[*]}{@}{"\n"}{end}' 2> /dev/null || true)"
  position="$(printf '%s\n' "$finalizers" | grep -nFx -- "$OWNED_FINALIZER" | head -n 1 | cut -d: -f1 || true)"
  running="not running"
  if operator_running "$OWNED_NS" "$OWNED_SELECTOR"; then running="running"; fi
  if [ "$OWNED_CLEARED" -eq 0 ] && [ -n "$position" ] && [ "$running" = "not running" ]; then
    echo "  the $OWNED_OPERATOR is not running, so nothing is left to run the finalizer $OWNED_FINALIZER on $OWNED."
    echo "  Removing that finalizer from $OWNED only; no other finalizer or object is changed."
    run k -n "$DATA_NS" patch "$OWNED" --type=json -p \
      "[{\"op\":\"test\",\"path\":\"/metadata/finalizers/$((position - 1))\",\"value\":\"$OWNED_FINALIZER\"},{\"op\":\"remove\",\"path\":\"/metadata/finalizers/$((position - 1))\"}]"
    OWNED_CLEARED=1
    DETAIL="$OWNED: the finalizer $OWNED_FINALIZER was just removed"
    return 1
  fi
  DETAIL="$OWNED
Finalizers: $(printf '%s' "$finalizers" | tr '\n' ' ')
The $OWNED_OPERATOR is $running.
This script removes only the finalizer $OWNED_FINALIZER, and only when that operator is not running. It changed nothing else on $OWNED."
  return 1
}

# delete_owned KIND CRD FINALIZER OPERATOR OPERATOR_NS OPERATOR_SELECTOR: delete every object of KIND in the data
# namespace by name and wait for each to go. The delete request returns at once (the finalizer holds the object);
# owned_gone does the waiting and deals with a finalizer whose operator is gone.
delete_owned() {
  local kind="$1" crd="$2" names name
  OWNED_FINALIZER="$3"
  OWNED_OPERATOR="$4"
  OWNED_NS="$5"
  OWNED_SELECTOR="$6"
  if ! crd_present "$crd"; then
    echo "  the $crd CRD is not installed: nothing to delete"
    return 0
  fi
  names="$(names_in "$DATA_NS" "$kind")" || fail "could not list $kind in the $DATA_NS namespace"
  if [ -z "$names" ]; then
    echo "  no $kind in the $DATA_NS namespace"
    return 0
  fi
  while IFS= read -r name; do
    OWNED="$name"
    OWNED_CLEARED=0
    run k -n "$DATA_NS" delete "$name" --wait=false
    if [ "$DRY_RUN" -eq 1 ]; then
      if operator_running "$OWNED_NS" "$OWNED_SELECTOR"; then
        echo "  dry run: the $OWNED_OPERATOR is running; would wait for $name to be deleted"
      else
        echo "  dry run: the $OWNED_OPERATOR is not running; if $name stays stuck on the finalizer $OWNED_FINALIZER, would remove that one finalizer"
      fi
    fi
    wait_for "$name is deleted" owned_gone
  done << EOF
$names
EOF
}

echo "Teardown preparation for the cluster in kubectl context: $CONTEXT"
[ "$DRY_RUN" -eq 0 ] || echo "DRY RUN: no change is made and no AWS call is made."

# Refuse to guess: the context must exist and must hold the Argo CD cluster Secret.
k config get-contexts -o name > /dev/null 2>&1 || usage_error "kubectl could not read its configuration"
if ! k config get-contexts -o name 2> /dev/null | grep -Fxq -- "$CONTEXT"; then
  usage_error "kubectl context '$CONTEXT' does not exist (see: kubectl config get-contexts)"
fi

step "Remove the cluster Secret labels, so the ApplicationSets stop recreating Applications"
if k -n "$ARGO_NS" get secret "$CLUSTER_SECRET" -o name > /dev/null 2>&1; then
  # A trailing '-' deletes the label key. Absent labels are reported by kubectl and are not an error.
  run k -n "$ARGO_NS" label secret "$CLUSTER_SECRET" platform.example/apps- platform.example/data- platform.example/observability-
else
  fail "Secret $ARGO_NS/$CLUSTER_SECRET not found in context '$CONTEXT'. Is this the Argo CD hub cluster?"
fi

step "Wait for the apps-*, data-* and observability-* Applications to be deleted"
wait_for "no apps-*, data-* or observability-* Application remains" apps_gone

step "Wait for the $SHOP_NS namespace to empty"
wait_for "the $SHOP_NS namespace has no workloads" shop_empty

step "Wait for the pods in the $OBS_NS namespace to be gone (if the namespace exists)"
if namespace_present "$OBS_NS"; then
  wait_for "no pod remains in the $OBS_NS namespace" obs_pods_gone
else
  echo "  no $OBS_NS namespace: the metrics foundation was not deployed here"
fi

step "Delete the PersistentVolumeClaims in the $OBS_NS namespace (only values-persistent.yaml creates any)"
if namespace_present "$OBS_NS"; then
  obs_pvcs="$(names_in "$OBS_NS" persistentvolumeclaims)" || fail "could not list claims in the $OBS_NS namespace"
  if [ -z "$obs_pvcs" ]; then
    echo "  no claims in the $OBS_NS namespace"
  else
    printf '%s\n' "$obs_pvcs" | sed 's/^/  claim: /'
    while IFS= read -r pvc; do
      run k -n "$OBS_NS" delete "$pvc" --wait=true --timeout="${TIMEOUT}s"
    done << EOF
$obs_pvcs
EOF
  fi
  wait_for "no claim remains in the $OBS_NS namespace" no_obs_pvc
else
  echo "  no $OBS_NS namespace: nothing to delete"
fi

step "Delete the CloudNativePG Database objects in the $DATA_NS namespace, before their Cluster"
delete_owned databases.postgresql.cnpg.io databases.postgresql.cnpg.io "$CNPG_DB_FINALIZER" "CloudNativePG operator" "$CNPG_NS" "$CNPG_SELECTOR"

step "Delete the CloudNativePG Clusters in the $DATA_NS namespace (this removes their pods and claims)"
delete_all cluster.postgresql.cnpg.io clusters.postgresql.cnpg.io

step "Delete the RabbitmqClusters in the $DATA_NS namespace, then their StatefulSets if they survive"
if crd_present rabbitmqclusters.rabbitmq.com; then
  mq_names="$(names_in "$DATA_NS" rabbitmqclusters.rabbitmq.com)" || fail "could not list RabbitmqClusters"
  if [ -z "$mq_names" ]; then
    echo "  no RabbitmqCluster in the $DATA_NS namespace"
  else
    delete_owned rabbitmqclusters.rabbitmq.com rabbitmqclusters.rabbitmq.com "$MQ_FINALIZER" "RabbitMQ Cluster Operator" "$MQ_NS" "$MQ_SELECTOR"
  fi
  while IFS= read -r mq; do
    [ -n "$mq" ] || continue
    # Observed on EKS: deleting the RabbitmqCluster leaves <name>-server and its pod running.
    sts="statefulset/${mq##*/}-server"
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "  dry run: would delete $sts if it still exists"
    elif k -n "$DATA_NS" get "$sts" -o name > /dev/null 2>&1; then
      echo "  $sts survived the RabbitmqCluster deletion"
      run k -n "$DATA_NS" delete "$sts" --wait=true --timeout="${TIMEOUT}s"
    else
      echo "  $sts is already gone"
    fi
  done << EOF
$mq_names
EOF
else
  echo "  the rabbitmqclusters.rabbitmq.com CRD is not installed: nothing to delete"
fi

step "Wait for the pods in the $DATA_NS namespace to be gone"
wait_for "no pod remains in the $DATA_NS namespace" data_pods_gone

step "Delete the remaining PersistentVolumeClaims in the $DATA_NS namespace (including platform-valkey)"
pvcs="$(names_in "$DATA_NS" persistentvolumeclaims)" || fail "could not list claims in the $DATA_NS namespace"
if [ -z "$pvcs" ]; then
  echo "  no claims in the $DATA_NS namespace"
else
  printf '%s\n' "$pvcs" | sed 's/^/  claim: /'
  while IFS= read -r pvc; do
    run k -n "$DATA_NS" delete "$pvc" --wait=true --timeout="${TIMEOUT}s"
  done << EOF
$pvcs
EOF
fi
wait_for "no claim remains in the $DATA_NS namespace" no_pvc

step "Confirm kubectl get pv is empty"
wait_for "kubectl get pv lists nothing" no_pv

if [ "$SKIP_AWS" -eq 1 ]; then
  echo
  echo "AWS checks skipped (--skip-aws). For GKE, list disks with the commands in docs/runbooks/data-layer.md."
else
  step "AWS: only the node root volumes may remain (no volume tagged $PVC_TAG)"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  dry run: would run: aws --region $REGION ec2 describe-volumes --filters Name=tag-key,Values=$PVC_TAG"
  else
    wait_for "no EBS volume tagged $PVC_TAG exists in $REGION" no_ebs_volumes
  fi

  step "AWS: no load balancer created by the AWS Load Balancer Controller remains"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  dry run: would run: aws --region $REGION resourcegroupstaggingapi get-resources (tag key $LB_TAG)"
  else
    wait_for "no load balancer tagged $LB_TAG exists in $REGION" no_load_balancers
  fi

  step "AWS: no security group created by the AWS Load Balancer Controller remains"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  dry run: would run: aws --region $REGION ec2 describe-security-groups --filters Name=tag-key,Values=$LB_TAG"
  else
    wait_for "no security group tagged $LB_TAG exists in $REGION" no_security_groups
  fi
fi

echo
if [ "$DRY_RUN" -eq 1 ]; then
  echo "Dry run finished. Nothing was changed."
else
  echo "Teardown preparation finished. The cluster holds no data volumes, claims or controller-created load balancers."
  echo "Next, by hand: delete the data namespaces and the storage class, remove Argo CD, then terraform destroy"
  echo "(docs/runbooks/data-layer.md, argocd.md, aws-eks.md)."
fi
