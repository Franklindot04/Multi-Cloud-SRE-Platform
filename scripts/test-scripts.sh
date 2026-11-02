#!/usr/bin/env bash
# Tests for the helper scripts: scripts/update-image-values.sh and scripts/changed-services.sh (used by CI),
# scripts/check-trivyignore.sh, scripts/teardown-prep.sh and scripts/teardown-argocd.sh (against a fake kubectl,
# a fake aws and a fake helm) and
# scripts/verify-image.sh (against a fake cosign); the fakes are in scripts/tests/fakes. It also tests the
# --enable-observability flag of scripts/bootstrap-argocd.sh (dry run only) and the observability checks of
# scripts/chart-contract-check.py.
# Plain bash (3.2 compatible), no framework, no network. Fixtures are in scripts/tests/fixtures.
#
#   scripts/test-scripts.sh
set -euo pipefail

case "${1:-}" in
  -h | --help)
    echo "Usage: $0"
    exit 0
    ;;
esac

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Start from a clean slate: a region, profile or kubeconfig exported in the caller's shell must not change what
# the scripts under test see (for example, a region from the environment makes the "no region" tests fail).
# Tests that need one pass it explicitly.
for var in $(env | sed -n 's/^\(AWS_[A-Za-z0-9_]*\)=.*/\1/p; s/^\(KUBECONFIG\)=.*/\1/p; s/^\(KUBECTL_[A-Za-z0-9_]*\)=.*/\1/p; s/^\(TEARDOWN_[A-Za-z0-9_]*\)=.*/\1/p; s/^\(TRIVYIGNORE_[A-Za-z0-9_]*\)=.*/\1/p'); do
  unset "$var"
done
fixtures="scripts/tests/fixtures"
update="./scripts/update-image-values.sh"
changed="./scripts/changed-services.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

passed=0
failed=0

ok() {
  passed=$((passed + 1))
  printf '  ok    %s\n' "$1"
}

bad() {
  failed=$((failed + 1))
  printf '  FAIL  %s\n' "$1" >&2
}

# check LABEL COMMAND...: the command must succeed.
check() {
  local label="$1"
  shift
  if "$@" > /dev/null 2>&1; then ok "$label"; else bad "$label"; fi
}

# rejects LABEL FILE ARGS...: the update script must exit 2 and leave FILE as it was.
rejects() {
  local label="$1" file="$2" rc=0 before
  shift 2
  before="$(cksum < "$file")"
  "$update" --file "$file" "$@" > "$work/out" 2>&1 || rc=$?
  if [ "$rc" -eq 2 ] && [ "$before" = "$(cksum < "$file")" ]; then ok "$label"; else bad "$label (exit $rc)"; fi
}

fresh() { cp "$fixtures/images.yaml" "$work/images.yaml"; }

d1="sha256:$(printf 'a%.0s' $(seq 64))"
d2="sha256:$(printf 'b%.0s' $(seq 64))"
d3="sha256:$(printf 'c%.0s' $(seq 64))"
tag="0123456789abcdef0123456789abcdef01234567"

echo "update-image-values.sh"

fresh
"$update" --file "$work/images.yaml" --tag "$tag" --digest "gateway=$d1" --dry-run > "$work/out"
check "a dry run leaves the file untouched" cmp -s "$work/images.yaml" "$fixtures/images.yaml"
check "a dry run prints the diff" grep -q "+  tag: \"$tag\"" "$work/out"

fresh
"$update" --file "$work/images.yaml" --tag "$tag" --digest "gateway=$d1" --digest "notifier=$d2" > "$work/out"
check "the tag is written" grep -q "^  tag: \"$tag\"$" "$work/images.yaml"
check "digests are written in the fixed service order" test "$(grep -c '^  [a-z]*: "sha256:' "$work/images.yaml")" = 2
check "gateway comes before notifier" test "$(grep -n 'gateway:' "$work/images.yaml" | cut -d: -f1)" -lt "$(grep -n 'notifier:' "$work/images.yaml" | cut -d: -f1)"
check "the registry line is unchanged" grep -q '^  registry: ghcr.io/example-owner$' "$work/images.yaml"
check "the comments are preserved" test "$(grep -c '^#' "$work/images.yaml")" = "$(grep -c '^#' "$fixtures/images.yaml")"
check "only the tag and digests differ from the original" test "$(diff "$fixtures/images.yaml" "$work/images.yaml" | grep -c '^[<>]')" = 6

cp "$work/images.yaml" "$work/once.yaml"
"$update" --file "$work/images.yaml" --tag "$tag" --digest "gateway=$d1" --digest "notifier=$d2" > "$work/out"
check "running it again changes nothing" cmp -s "$work/images.yaml" "$work/once.yaml"
check "and says so" grep -q '^no changes' "$work/out"

"$update" --file "$work/images.yaml" --tag "$tag" --digest "orders=$d3" > /dev/null
check "a digest for another service is merged, not replacing the others" test "$(grep -c '^  [a-z]*: "sha256:' "$work/images.yaml")" = 3
check "the earlier digests are kept" grep -q "gateway: \"$d1\"" "$work/images.yaml"
"$update" --file "$work/images.yaml" --tag "$tag" --digest "gateway=$d3" > /dev/null
check "a new digest replaces the old one" grep -q "gateway: \"$d3\"" "$work/images.yaml"
"$update" --file "$work/images.yaml" --tag "next-tag.1" > /dev/null
check "a new tag alone keeps the digests" test "$(grep -c '^  [a-z]*: "sha256:' "$work/images.yaml")" = 3

fresh
"$update" --file "$work/images.yaml" --tag "$tag" > /dev/null
check "a tag without digests keeps digests as an empty map" grep -q '^digests: {}$' "$work/images.yaml"

fresh
rejects "no tag is rejected" "$work/images.yaml" --digest "gateway=$d1"
rejects "a tag with a space is rejected" "$work/images.yaml" --tag "bad tag"
rejects "a tag with a colon is rejected" "$work/images.yaml" --tag "a:b"
rejects "a tag with a leading dash is rejected" "$work/images.yaml" --tag "-x"
rejects "an empty tag is rejected" "$work/images.yaml" --tag ""
rejects "a tag with shell characters is rejected" "$work/images.yaml" --tag 'x;rm -rf /'
rejects "a short digest is rejected" "$work/images.yaml" --tag "$tag" --digest "gateway=sha256:abc"
rejects "an upper-case digest is rejected" "$work/images.yaml" --tag "$tag" --digest "gateway=sha256:$(printf 'A%.0s' $(seq 64))"
rejects "a digest without the algorithm is rejected" "$work/images.yaml" --tag "$tag" --digest "gateway=$(printf 'a%.0s' $(seq 64))"
rejects "an unknown service is rejected" "$work/images.yaml" --tag "$tag" --digest "frontend=$d1"
rejects "a digest without a service is rejected" "$work/images.yaml" --tag "$tag" --digest "$d1"
rejects "a service given twice is rejected" "$work/images.yaml" --tag "$tag" --digest "gateway=$d1" --digest "gateway=$d2"
rejects "an unknown option is rejected" "$work/images.yaml" --tag "$tag" --force
rejects "a file without a tag line is rejected" "$fixtures/no-tag.yaml" --tag "$tag"
rejects "a digests block with unexpected content is rejected" "$fixtures/odd-digests.yaml" --tag "$tag"
rejc=0
"$update" --file "$work/missing.yaml" --tag "$tag" > /dev/null 2>&1 || rejc=$?
if [ "$rejc" -eq 2 ]; then ok "a missing file is rejected"; else bad "a missing file is rejected (exit $rejc)"; fi
check "the script runs no version control command" test "$(grep -Ec '(^|[;&| ])git( |$)' "$update")" = 0

echo "changed-services.sh"

run_changed() {
  # run_changed "file1 file2" ARGS...
  local files="$1"
  shift
  printf '%s\n' "$files" | tr ' ' '\n' | "$changed" "$@"
}

shared=(--all-on scripts/apps.sh --all-on .github/workflows/apps.yml --all-on apps/data/)

check "a gateway change affects only the gateway" test "$(run_changed 'apps/gateway/internal/x.go' "${shared[@]}" | head -1)" = 'services=["gateway"]'
check "two services are listed in the fixed order" test "$(run_changed 'apps/payments/pom.xml apps/gateway/main.go' "${shared[@]}" | head -1)" = 'services=["gateway","payments"]'
check "docs do not affect any service" test "$(run_changed 'docs/adr/README.md README.md' "${shared[@]}" | tail -1)" = 'any=false'
check "an empty change affects nothing" test "$(run_changed '' "${shared[@]}" | head -1)" = 'services=[]'
check "a shared script affects every service" test "$(run_changed 'scripts/apps.sh' "${shared[@]}" | head -1)" = 'services=["gateway","orders","payments","notifier"]'
check "the workflow itself affects every service" test "$(run_changed '.github/workflows/apps.yml' "${shared[@]}" | head -1)" = 'services=["gateway","orders","payments","notifier"]'
check "a directory prefix matches files below it" test "$(run_changed 'apps/data/init.sh' "${shared[@]}" | tail -1)" = 'any=true'
check "a similarly named path is not a prefix match" test "$(run_changed 'apps/database/x' "${shared[@]}" | tail -1)" = 'any=false'
check "--all forces every service" test "$(run_changed 'README.md' --all | head -1)" = 'services=["gateway","orders","payments","notifier"]'
check "paths with .. are ignored" test "$(run_changed 'apps/gateway/../orders/x' "${shared[@]}" | tail -1)" = 'any=false'
check "a leading ./ is accepted" test "$(run_changed './apps/orders/x.py' "${shared[@]}" | head -1)" = 'services=["orders"]'
check "an unknown option is rejected" test "$(run_changed 'x' --bogus > /dev/null 2>&1; echo $?)" = 2

echo "teardown-prep.sh"

teardown="./scripts/teardown-prep.sh"
fakes="$PWD/scripts/tests/fakes"

# new_cluster: a fresh fake cluster state in $state with both operators installed and an AWS account that
# still shows leftovers until the script has cleaned up (the fakes keep the leftovers listed only when a
# file says so).
new_cluster() {
  state="$work/state"
  rm -rf "$state"
  mkdir -p "$state"
  printf '%s\n' test-cluster other-cluster > "$state/contexts"
  printf '%s\n' clusters.postgresql.cnpg.io rabbitmqclusters.rabbitmq.com databases.postgresql.cnpg.io > "$state/crds"
}

# teardown ARGS...: run the script with the fakes first on PATH; output in $work/tdout, status in $rc.
run_teardown() {
  rc=0
  PATH="$fakes:$PATH" FAKE_STATE="$state" TEARDOWN_POLL_SECONDS=1 "$teardown" "$@" > "$work/tdout" 2>&1 || rc=$?
}

line_of() { grep -n -m1 -e "$1" "$state/kubectl.log" | cut -d: -f1; }

new_cluster
touch "$state/mq-survives"
run_teardown --context test-cluster --region eu-north-1 --timeout 5
check "the happy path exits 0" test "$rc" -eq 0
check "it removes the label keys, not sets them to false" grep -q 'label secret cluster-in-cluster platform.example/apps- platform.example/data- platform.example/observability- platform.example/policy-$' "$state/kubectl.log"
check "labels come before the Cluster deletion" test "$(line_of 'label secret')" -lt "$(line_of 'delete cluster.postgresql')"
check "the Cluster is deleted before the RabbitmqCluster" test "$(line_of 'delete cluster.postgresql')" -lt "$(line_of 'delete rabbitmqcluster')"
check "the surviving StatefulSet is deleted after the RabbitmqCluster" test "$(line_of 'delete rabbitmqcluster')" -lt "$(line_of 'delete statefulset')"
check "claims are deleted after the StatefulSet" test "$(line_of 'delete statefulset')" -lt "$(line_of 'delete persistentvolumeclaim/platform-valkey')"
check "platform-valkey is deleted" grep -q 'delete persistentvolumeclaim/platform-valkey' "$state/kubectl.log"
check "the claim of each of the two PostgreSQL instances is deleted, by name" test "$(grep -c -e '-n data delete persistentvolumeclaim/platform-pg-[12] ' "$state/kubectl.log")" = 2
check "three claims in all, one deletion each" test "$(grep -c -e '-n data delete persistentvolumeclaim/' "$state/kubectl.log")" = 3
check "the output lists the claims of both instances" test "$(grep -c -e '  claim: persistentvolumeclaim/platform-pg-[12]$' "$work/tdout")" = 2
check "the pods of both instances are waited for before the claims are deleted" test "$(line_of '-n data get pods')" -lt "$(line_of '-n data delete persistentvolumeclaim/platform-pg-1')"
check "kubectl get pv is checked after the claims are deleted" test "$(line_of 'get pv')" -gt "$(line_of 'delete persistentvolumeclaim/platform-valkey')"
check "the AWS checks run after kubectl get pv: volumes, load balancers, security groups" test "$(sed -n 's/^--region eu-north-1 \([a-z0-9]*\) \([a-z-]*\).*/\2/p' "$state/aws.log" | tr '\n' ' ')" = "describe-volumes get-resources describe-security-groups "
check "the volume query uses the pvc name tag" grep -q 'Name=tag-key,Values=kubernetes.io/created-for/pvc/name' "$state/aws.log"
check "the load balancer query uses the controller tag" grep -q 'Key=elbv2.k8s.aws/cluster ' "$state/aws.log"
check "every deletion names its namespace" test "$(grep ' delete ' "$state/kubectl.log" | grep -vc -e '-n data delete')" = 0
check "no call uses --force" test "$(cat "$state/kubectl.log" "$state/aws.log" | grep -c -e '--force')" = 0
check "it changes nothing outside argocd, shop, data and observability, and only lists operator pods elsewhere" test "$(grep -e '-n ' "$state/kubectl.log" | grep -v -e '-n argocd' -e '-n shop' -e '-n data' -e '-n observability' | grep -vc -e '^-n cnpg-system get pods -l ' -e '^-n rabbitmq-system get pods -l ')" = 0
check "without an observability namespace nothing is read or deleted in it" test "$(grep -c -e '-n observability' "$state/kubectl.log")" = 0
check "and the output says the metrics foundation was not deployed" grep -q 'no observability namespace: the metrics foundation was not deployed here' "$work/tdout"
check "the Database objects are deleted before the Cluster" test "$(line_of 'delete database.postgresql.cnpg.io/platform-pg-payments')" -lt "$(line_of 'delete cluster.postgresql')"
check "the output says it finished" grep -q 'Teardown preparation finished' "$work/tdout"
check "an ordinary run removes no finalizer" test "$(grep -c ' patch ' "$state/kubectl.log")" = 0

new_cluster
run_teardown --context test-cluster --region eu-north-1 --timeout 5
check "a RabbitMQ StatefulSet that did not survive is not deleted" test "$(grep -c 'delete statefulset' "$state/kubectl.log")" = 0
check "and the run still succeeds" test "$rc" -eq 0

# Operators running: the finalizers are removed by the operators, so the script only waits.
new_cluster
touch "$state/cnpg-operator-up" "$state/mq-operator-up" "$state/stuck-databases" "$state/stuck-mq" "$state/mq-survives"
run_teardown --context test-cluster --region eu-north-1 --timeout 5
check "with the operators running the run exits 0" test "$rc" -eq 0
check "with the operators running no finalizer is removed" test "$(grep -c ' patch ' "$state/kubectl.log")" = 0
check "with the operators running the output does not claim a finalizer was removed" test "$(grep -c 'Removing that finalizer' "$work/tdout")" = 0

# Operators gone, objects stuck on exactly their operator finalizer: the script removes those and goes on.
new_cluster
touch "$state/stuck-databases" "$state/stuck-mq" "$state/mq-survives"
run_teardown --context test-cluster --region eu-north-1 --timeout 5
check "with the operators gone and the finalizers stuck the run exits 0" test "$rc" -eq 0
check "three finalizers are removed: two Databases and the RabbitmqCluster" test "$(grep -c ' patch ' "$state/kubectl.log")" = 3
check "each patch names one object in the data namespace" test "$(grep ' patch ' "$state/kubectl.log" | grep -c -e '-n data patch database.postgresql.cnpg.io/platform-pg-orders --type=json' -e '-n data patch database.postgresql.cnpg.io/platform-pg-payments --type=json' -e '-n data patch rabbitmqcluster.rabbitmq.com/platform-mq --type=json')" = 3
check "the Database patch removes cnpg.io/deleteDatabase and tests it first" grep -q '"op":"test","path":"/metadata/finalizers/0","value":"cnpg.io/deleteDatabase"},{"op":"remove","path":"/metadata/finalizers/0"}' "$state/kubectl.log"
check "the RabbitmqCluster patch removes its operator finalizer" grep -q '"value":"deletion.finalizers.rabbitmqclusters.rabbitmq.com"}' "$state/kubectl.log"
check "the output says what was removed and why" grep -q 'the CloudNativePG operator is not running, so nothing is left to run the finalizer cnpg.io/deleteDatabase on database.postgresql.cnpg.io/platform-pg-orders' "$work/tdout"
check "and says the same for RabbitMQ" grep -q 'the RabbitMQ Cluster Operator is not running, so nothing is left to run the finalizer deletion.finalizers.rabbitmqclusters.rabbitmq.com' "$work/tdout"
check "the object is deleted before its finalizer is removed" test "$(line_of 'delete rabbitmqcluster')" -lt "$(line_of 'patch rabbitmqcluster')"
check "the Database finalizers go before the Cluster is deleted" test "$(line_of 'patch database.postgresql.cnpg.io/platform-pg-payments')" -lt "$(line_of 'delete cluster.postgresql')"
check "the StatefulSet is still deleted after the RabbitmqCluster" test "$(line_of 'patch rabbitmqcluster')" -lt "$(line_of 'delete statefulset')"
check "nothing is forced and no grace period is set" test "$(cat "$state/kubectl.log" | grep -c -e '--force' -e 'grace-period')" = 0
check "no object other than the three is patched" test "$(grep -c -e ' patch ' -e ' annotate ' -e ' edit ' -e ' replace ' "$state/kubectl.log")" = 3

# Run it again on the finished cluster: nothing is left to do and nothing is removed.
run_teardown --context test-cluster --region eu-north-1 --timeout 5
check "a repeat run exits 0" test "$rc" -eq 0
check "a repeat run removes no further finalizer" test "$(grep -c ' patch ' "$state/kubectl.log")" = 3
check "a repeat run finds no Database objects" grep -q 'no databases.postgresql.cnpg.io in the data namespace' "$work/tdout"

# A finalizer that is not the operator's: left alone, the script stops and names it.
new_cluster
touch "$state/odd-finalizer-mq" "$state/mq-survives"
run_teardown --context test-cluster --region eu-north-1 --timeout 2
check "a RabbitmqCluster stuck on another finalizer stops the script with exit 1" test "$rc" -eq 1
check "no finalizer is removed from it" test "$(grep -c ' patch ' "$state/kubectl.log")" = 0
check "the message names the finalizer and the object" grep -q 'Finalizers: example.com/keep' "$work/tdout"
check "the timeout message names the object that is stuck" grep -q 'timed out after 2s waiting until rabbitmqcluster.rabbitmq.com/platform-mq is deleted' "$work/tdout"
check "nothing after that step runs: no StatefulSet, claim or AWS call" test "$(grep -c -e 'delete statefulset' -e 'persistentvolumeclaim' "$state/kubectl.log")" = 0 -a ! -e "$state/aws.log"

new_cluster
touch "$state/odd-finalizer-databases"
run_teardown --context test-cluster --region eu-north-1 --timeout 2
check "a Database stuck on another finalizer stops the script with exit 1" test "$rc" -eq 1
check "no finalizer is removed from the Database" test "$(grep -c ' patch ' "$state/kubectl.log")" = 0
check "the Cluster is not deleted after that" test "$(grep -c 'delete cluster.postgresql' "$state/kubectl.log")" = 0

new_cluster
touch "$state/stuck-mq" "$state/odd-finalizer-mq" "$state/mq-survives"
run_teardown --context test-cluster --region eu-north-1 --timeout 2
check "with both finalizers only the operator's is removed" test "$(grep -c ' patch ' "$state/kubectl.log")" = 1
check "and the run then stops on the other one" test "$rc" -eq 1
check "and names it" grep -q 'Finalizers: example.com/keep' "$work/tdout"

# The operator's own finalizer, but its operator is running and has not finished: only wait, never patch.
new_cluster
touch "$state/mq-operator-up" "$state/odd-finalizer-mq"
run_teardown --context test-cluster --region eu-north-1 --timeout 2
check "a running operator with a stuck object is waited for, not patched" test "$rc" -eq 1 -a "$(grep -c ' patch ' "$state/kubectl.log")" = 0
check "and the message says the operator is running" grep -q 'The RabbitMQ Cluster Operator is running' "$work/tdout"

# If the operator cannot be looked up, nothing is assumed.
new_cluster
touch "$state/stuck-databases" "$state/operator-api-error"
run_teardown --context test-cluster --region eu-north-1 --timeout 2
check "an operator lookup that fails stops the script" test "$rc" -eq 1
check "and no finalizer is removed" test "$(grep -c ' patch ' "$state/kubectl.log")" = 0
check "and the message says the lookup failed" grep -q 'could not check whether the operator' "$work/tdout"

new_cluster
touch "$state/stuck-shop"
run_teardown --context test-cluster --region eu-north-1 --timeout 2
check "a step that times out exits 1" test "$rc" -eq 1
check "the timeout message names the step and what remains" grep -q 'timed out after 2s waiting until the shop namespace has no workloads' "$work/tdout"
check "nothing is deleted after a timeout" test "$(grep -c ' delete ' "$state/kubectl.log")" = 0
check "no AWS call is made after a timeout" test ! -e "$state/aws.log"

new_cluster
touch "$state/stuck-pods"
run_teardown --context test-cluster --region eu-north-1 --timeout 2
check "pods that never go away stop the script before claims are deleted" test "$rc" -eq 1 -a "$(grep -c 'persistentvolumeclaim' "$state/kubectl.log")" = 0

# The observability namespace, without and with the volumes of values-persistent.yaml.
new_cluster
touch "$state/stuck-apps"
run_teardown --context test-cluster --region eu-north-1 --timeout 2
check "an observability Application that does not go away stops the script" test "$rc" -eq 1
check "and is named" grep -q 'observability-stack-in-cluster' "$work/tdout"

new_cluster
touch "$state/obs-namespace" "$state/mq-survives"
run_teardown --context test-cluster --region eu-north-1 --timeout 5
check "with the observability namespace and no claims the run exits 0" test "$rc" -eq 0
check "the observability pods are checked after the shop namespace and before the Databases" test "$(line_of '-n observability get pods')" -gt "$(line_of '-n shop get')" -a "$(line_of '-n observability get pods')" -lt "$(line_of 'delete database.postgresql.cnpg.io/platform-pg-orders')"
check "the output says there are no claims in it" grep -q 'no claims in the observability namespace' "$work/tdout"
check "nothing is deleted in the observability namespace" test "$(grep -c -e '-n observability delete' "$state/kubectl.log")" = 0
check "no observability resource is patched or force-deleted" test "$(grep -e '-n observability' "$state/kubectl.log" | grep -c -e ' patch ' -e '--force' -e 'grace-period')" = 0
check "the cluster is not left holding a volume" test "$(grep -c 'get pv' "$state/kubectl.log")" -ge 1

new_cluster
touch "$state/obs-namespace" "$state/obs-persistent" "$state/mq-survives"
run_teardown --context test-cluster --region eu-north-1 --timeout 5
check "with the persistent volumes the run exits 0" test "$rc" -eq 0
check "both claims are deleted, each by name in the observability namespace" test "$(grep -c -e '-n observability delete persistentvolumeclaim/' "$state/kubectl.log")" = 2
check "the Prometheus claim is deleted" grep -q -e '-n observability delete persistentvolumeclaim/prometheus-kube-prometheus-stack-prometheus-db' "$state/kubectl.log"
check "the Grafana claim is deleted" grep -q -e '-n observability delete persistentvolumeclaim/kube-prometheus-stack-grafana ' "$state/kubectl.log"
check "the claims go after the observability pods are gone" test "$(line_of '-n observability get pods')" -lt "$(line_of '-n observability delete persistentvolumeclaim')"
check "kubectl get pv is checked after the observability claims are deleted" test "$(line_of 'get pv')" -gt "$(line_of '-n observability delete persistentvolumeclaim')"
check "no call uses --force" test "$(grep -c -e '--force' "$state/kubectl.log")" = 0

new_cluster
touch "$state/obs-namespace" "$state/obs-persistent" "$state/stuck-obs-pods"
run_teardown --context test-cluster --region eu-north-1 --timeout 2
check "observability pods that never go away stop the script" test "$rc" -eq 1
check "the message names the pods" grep -q 'pod/kube-prometheus-stack-grafana-0' "$work/tdout"
check "and the finalizer the Prometheus Operator can set, and says the script leaves it alone" grep -q 'monitoring.coreos.com/status-cleanup.*This script does not remove it' "$work/tdout"
check "no finalizer is removed and nothing is patched" test "$(grep -c -e ' patch ' "$state/kubectl.log")" = 0
check "no claim is deleted after that, in observability or data" test "$(grep -c 'delete persistentvolumeclaim' "$state/kubectl.log")" = 0
check "and nothing in the data namespace is deleted" test "$(grep -c -e '-n data delete' "$state/kubectl.log")" = 0

new_cluster
touch "$state/obs-namespace" "$state/obs-persistent" "$state/mq-survives"
run_teardown --context test-cluster --region eu-north-1 --dry-run
check "a dry run with the persistent volumes exits 0" test "$rc" -eq 0
check "it deletes no claim" test "$(grep -c 'delete persistentvolumeclaim' "$state/kubectl.log")" = 0
check "it prints the claim deletions it would run" grep -q '+ kubectl --context test-cluster -n observability delete persistentvolumeclaim/kube-prometheus-stack-grafana --wait=true' "$work/tdout"

new_cluster
printf 'vol-0123456789abcdef0\n' > "$state/aws-volumes"
run_teardown --context test-cluster --region eu-north-1 --timeout 2
check "a leftover EBS volume fails the run" test "$rc" -eq 1
check "and the volume is named" grep -q 'vol-0123456789abcdef0' "$work/tdout"
check "the security group check does not run after that" test "$(grep -c 'describe-security-groups' "$state/aws.log")" = 0

new_cluster
printf 'vol-0123456789abcdef0\nvol-0123456789abcdef1\n' > "$state/aws-volumes"
run_teardown --context test-cluster --region eu-north-1 --timeout 2
check "two leftover volumes (one for each PostgreSQL instance) fail the run" test "$rc" -eq 1
check "and both are named" test "$(grep -c -e 'vol-0123456789abcdef0' -e 'vol-0123456789abcdef1' "$work/tdout")" -ge 1 -a "$(grep -c 'vol-0123456789abcdef1' "$work/tdout")" -ge 1

new_cluster
touch "$state/stuck-pg2-claim"
run_teardown --context test-cluster --region eu-north-1 --timeout 2
check "the claim of the replica that is not removed fails the run" test "$rc" -eq 1
check "and the claim is named" grep -q 'persistentvolumeclaim/platform-pg-2' "$work/tdout"
check "the AWS checks do not run after that" test ! -e "$state/aws.log"

new_cluster
printf 'arn:aws:elasticloadbalancing:eu-north-1:000000000000:loadbalancer/app/example/abc\n' > "$state/aws-load-balancers"
run_teardown --context test-cluster --region eu-north-1 --cluster-name platform --timeout 2
check "a leftover load balancer fails the run" test "$rc" -eq 1
check "--cluster-name narrows the load balancer query" grep -q 'Key=elbv2.k8s.aws/cluster,Values=platform' "$state/aws.log"

new_cluster
printf 'sg-0123456789abcdef0\n' > "$state/aws-security-groups"
run_teardown --context test-cluster --region eu-north-1 --timeout 2
check "a leftover security group fails the run" test "$rc" -eq 1

new_cluster
run_teardown --region eu-north-1
check "a missing --context is rejected with exit 2" test "$rc" -eq 2
check "and the message says so" grep -q -e '--context is required' "$work/tdout"
check "and kubectl is never called" test ! -e "$state/kubectl.log"

new_cluster
run_teardown --context no-such-context --region eu-north-1
check "an unknown context is rejected with exit 2" test "$rc" -eq 2
check "and nothing is changed" test "$(grep -c -e ' delete ' -e ' label ' "$state/kubectl.log")" = 0

new_cluster
touch "$state/no-secret"
run_teardown --context test-cluster --region eu-north-1
check "a cluster without the Argo CD cluster Secret is refused" test "$rc" -eq 1

new_cluster
run_teardown --context test-cluster
check "AWS checks without a region are rejected with exit 2" test "$rc" -eq 2

new_cluster
run_teardown --context test-cluster --skip-aws --timeout 5
check "--skip-aws stops after kubectl get pv and exits 0" test "$rc" -eq 0 -a ! -e "$state/aws.log"

new_cluster
touch "$state/mq-survives"
run_teardown --context test-cluster --region eu-north-1 --dry-run
check "a dry run exits 0" test "$rc" -eq 0
check "a dry run runs no label, delete or other change" test "$(grep -c -e ' delete ' -e ' label ' -e ' patch ' -e ' apply ' -e ' annotate ' "$state/kubectl.log")" = 0
check "a dry run makes no AWS call" test ! -e "$state/aws.log"
check "a dry run prints the commands it would run" grep -q '+ kubectl --context test-cluster -n argocd label secret cluster-in-cluster platform.example/apps- platform.example/data-' "$work/tdout"
check "and says nothing was changed" grep -q 'Nothing was changed' "$work/tdout"
check "a dry run with the operators gone says it would remove only the operator finalizer" test "$(grep -c 'dry run: the .* is not running; if .* stays stuck on the finalizer' "$work/tdout")" = 3

new_cluster
touch "$state/cnpg-operator-up" "$state/mq-operator-up" "$state/stuck-databases" "$state/stuck-mq"
run_teardown --context test-cluster --region eu-north-1 --dry-run
check "a dry run with the operators running exits 0 and changes nothing" test "$rc" -eq 0 -a "$(grep -c -e ' delete ' -e ' label ' -e ' patch ' "$state/kubectl.log")" = 0
check "and says it would only wait" test "$(grep -c 'dry run: the .* is running; would wait for' "$work/tdout")" = 3
check "the dry run prints the Database delete it would run" grep -q '+ kubectl --context test-cluster -n data delete database.postgresql.cnpg.io/platform-pg-orders --wait=false' "$work/tdout"

new_cluster
run_teardown --context test-cluster --region eu-north-1 --bogus
check "an unknown option is rejected with exit 2" test "$rc" -eq 2
check "the script never uses --force or runs version control" test "$(grep -Ec -e '--force|(^|[;&| ])git( |$)' "$teardown")" = 0

# Kyverno: its policies and webhook configurations go before anything else is deleted, and only Kyverno's.
new_cluster
printf '%s\n' clusterpolicies.kyverno.io policies.kyverno.io validatingpolicies.policies.kyverno.io imagevalidatingpolicies.policies.kyverno.io >> "$state/crds"
touch "$state/kyverno-policies" "$state/kyverno-webhooks"
run_teardown --context test-cluster --region eu-north-1 --timeout 5
check "with Kyverno policies and webhooks the run exits 0" test "$rc" -eq 0
check "the steps are numbered 1 to 15" grep -q -e '^\[1/15\]' -e '^\[15/15\]' "$work/tdout"
check "the step for Kyverno is the third" grep -q '^\[3/15\] Delete the Kyverno policies and webhook configurations' "$work/tdout"
check "the cluster Secret label of the policy engine is removed with the others" grep -q 'platform.example/observability- platform.example/policy-$' "$state/kubectl.log"
check "every kind of Kyverno policy is deleted: ClusterPolicy, Policy, ValidatingPolicy and ImageValidatingPolicy" test "$(grep -c -e 'delete clusterpolicies.kyverno.io --all --wait=true' -e 'delete policies.kyverno.io --all -A --wait=true' -e 'delete validatingpolicies.policies.kyverno.io --all --wait=true' -e 'delete imagevalidatingpolicies.policies.kyverno.io --all --wait=true' "$state/kubectl.log")" = 4
check "the two Kyverno webhook configurations are deleted by name" test "$(grep -c -e 'delete validatingwebhookconfiguration.admissionregistration.k8s.io/kyverno-resource-validating-webhook-cfg ' -e 'delete mutatingwebhookconfiguration.admissionregistration.k8s.io/kyverno-policy-mutating-webhook-cfg ' "$state/kubectl.log")" = 2
check "no other webhook configuration is deleted" test "$(grep ' delete ' "$state/kubectl.log" | grep -c -e 'cert-manager-webhook' -e 'aws-load-balancer-webhook')" = 0
check "the policies go before the webhook configurations" test "$(line_of 'delete policies.kyverno.io')" -lt "$(line_of 'delete validatingwebhookconfiguration')"
check "Kyverno is dealt with after the labels and before the shop, data and observability namespaces are read" test "$(line_of 'label secret')" -lt "$(line_of 'delete clusterpolicies.kyverno.io')" -a "$(line_of 'delete mutatingwebhookconfiguration')" -lt "$(line_of '-n shop get')"
check "the output waits for the webhook configurations to be gone" grep -q 'ok: no webhook configuration whose name starts with kyverno remains' "$work/tdout"
check "the Applications of the policy engine are waited for" grep -q 'no apps-\*, data-\*, observability-\* or policy-\* Application remains' "$work/tdout"
run_teardown --context test-cluster --region eu-north-1 --timeout 5
check "a repeat run finds no Kyverno policy and no webhook configuration" grep -q 'no object of clusterpolicies.kyverno.io' "$work/tdout" -a "$rc" -eq 0
check "and says so for the webhook configurations" grep -q 'no webhook configuration whose name starts with kyverno' "$work/tdout"

new_cluster
run_teardown --context test-cluster --region eu-north-1 --timeout 5
check "without Kyverno the run exits 0 and says the CRDs are not installed" test "$rc" -eq 0 -a "$(grep -c 'kyverno.io CRD is not installed: nothing to delete' "$work/tdout")" = 4
check "and no webhook configuration is deleted" test "$(grep -c 'delete validatingwebhookconfiguration' "$state/kubectl.log")" = 0

new_cluster
touch "$state/kyverno-webhooks" "$state/stuck-kyverno-webhooks"
run_teardown --context test-cluster --region eu-north-1 --timeout 2
check "a Kyverno webhook configuration that does not go makes the run stop with exit 1" test "$rc" -eq 1
check "and the message names it" grep -q 'kyverno-resource-validating-webhook-cfg' "$work/tdout"
check "nothing after that step runs" test "$(grep -c -e 'delete cluster.postgresql' -e 'get pv' "$state/kubectl.log")" = 0

new_cluster
printf '%s\n' clusterpolicies.kyverno.io policies.kyverno.io validatingpolicies.policies.kyverno.io imagevalidatingpolicies.policies.kyverno.io >> "$state/crds"
touch "$state/kyverno-policies" "$state/kyverno-webhooks"
run_teardown --context test-cluster --region eu-north-1 --timeout 5 --dry-run
check "a dry run with Kyverno exits 0 and deletes nothing" test "$rc" -eq 0 -a "$(grep -c ' delete ' "$state/kubectl.log")" = 0
check "it prints the Kyverno deletions it would run" grep -q '+ kubectl --context test-cluster delete validatingwebhookconfiguration.admissionregistration.k8s.io/kyverno-resource-validating-webhook-cfg --wait=true' "$work/tdout"
check "and the policy deletions" grep -q '+ kubectl --context test-cluster delete clusterpolicies.kyverno.io --all --wait=true' "$work/tdout"
check "and that it would wait for the webhook configurations" grep -q 'dry run: would wait until no webhook configuration whose name starts with kyverno remains' "$work/tdout"

echo "teardown-argocd.sh"

teardown_argocd="./scripts/teardown-argocd.sh"

# new_argo_cluster: a cluster as teardown-prep.sh leaves it, with Argo CD still installed: no volumes or claims,
# the namespaces data, shop, observability and argocd, the storage class, and a running application controller.
# Tests add stuck-argo-apps, stuck-projects and the like to change that.
new_argo_cluster() {
  new_cluster
  printf '%s\n' applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io >> "$state/crds"
  touch "$state/argocd-script" "$state/ns-data" "$state/ns-shop" "$state/ns-argocd" "$state/obs-namespace" \
    "$state/storageclass" "$state/argo-controller-up" "$state/pvc-deleted" "$state/obs-pvc-deleted"
}

# run_argocd ARGS...: run the script with the fakes first on PATH; output in $work/tdout, status in $rc.
run_argocd() {
  rc=0
  PATH="$fakes:$PATH" FAKE_STATE="$state" TEARDOWN_POLL_SECONDS=1 "$teardown_argocd" "$@" > "$work/tdout" 2>&1 || rc=$?
}

out_line() { grep -n -m1 -e "$1" "$work/tdout" | cut -d: -f1; }

# The only patch the script may send: the finalizer tested and removed at position 0, on one of seven objects.
argo_patch_re='-n argocd patch (application|appproject)\.argoproj\.io/(platform-root|argocd|platform-addons|platform-apps|platform-data|platform-observability|platform-system) --type=json -p \[\{"op":"test","path":"/metadata/finalizers/0","value":"resources-finalizer\.argocd\.argoproj\.io"\},\{"op":"remove","path":"/metadata/finalizers/0"\}\]$'

new_argo_cluster
run_argocd --context test-cluster --timeout 5
check "the normal path exits 0" test "$rc" -eq 0
check "the steps are numbered 1 to 10" grep -q -e '^\[1/10\]' -e '^\[10/10\]' "$work/tdout"
check "the volume check comes first, before anything is deleted" test "$(line_of 'get pv')" -lt "$(line_of ' delete ')"
check "the namespaces data, shop and observability are deleted without waiting in the command" test "$(grep -c -e 'delete namespace data --wait=false' -e 'delete namespace shop --wait=false' -e 'delete namespace observability --wait=false' "$state/kubectl.log")" = 3
check "the storage class is deleted after the namespaces" test "$(line_of 'delete namespace observability')" -lt "$(line_of 'delete storageclass platform-data')"
check "platform-root is deleted after the storage class" test "$(line_of 'delete storageclass platform-data')" -lt "$(line_of 'delete application.argoproj.io/platform-root')"
check "the ApplicationSets are deleted after platform-root, each by name" test "$(line_of 'delete application.argoproj.io/platform-root')" -lt "$(line_of 'delete applicationset.argoproj.io/apps')" -a "$(grep -c 'delete applicationset.argoproj.io/' "$state/kubectl.log")" = 2
check "helm uninstalls the release argocd once, with the context" test "$(cat "$state/helm.log")" = "--kube-context test-cluster uninstall argocd -n argocd"
check "helm runs after the Applications are gone" test "$(out_line 'ok: no Application remains')" -lt "$(out_line '+ helm ')"
check "the argocd namespace is deleted after helm, last" test "$(out_line '+ helm ')" -lt "$(out_line 'delete namespace argocd')" -a "$(line_of 'delete namespace argocd')" = "$(grep -n ' delete ' "$state/kubectl.log" | tail -n 1 | cut -d: -f1)"
check "with the controller running no finalizer is patched" test "$(grep -c ' patch ' "$state/kubectl.log")" = 0
check "the CRDs are not deleted" test "$(grep -c 'delete crd' "$state/kubectl.log")" = 0
check "waiting is bounded: every wait line shows its limit" test "$(grep 'waiting (' "$work/tdout" | grep -vc 's of 5s)')" = 0
check "the commands are echoed with a plus sign" grep -q '^  + kubectl --context test-cluster delete namespace data --wait=false$' "$work/tdout"
check "the output ends with the next step" grep -q 'Next: terraform destroy' "$work/tdout"
check "no call uses --force or a grace period" test "$(cat "$state/kubectl.log" "$state/helm.log" | grep -c -e '--force' -e 'grace-period')" = 0

# Run it again on the finished cluster: everything is skipped, helm reports no release, and that is fine.
deletes_before="$(grep -c ' delete ' "$state/kubectl.log")"
run_argocd --context test-cluster --timeout 5
check "a repeat run exits 0" test "$rc" -eq 0
check "a repeat run deletes nothing more" test "$(grep -c ' delete ' "$state/kubectl.log")" = "$deletes_before"
check "a repeat run skips what is gone" grep -q 'no data namespace: nothing to delete' "$work/tdout"
check "a repeat run finds no storage class" grep -q 'no storage class platform-data: nothing to delete' "$work/tdout"
check "a repeat run tolerates the missing release" grep -q 'the release argocd is not installed: nothing to uninstall' "$work/tdout"

# Argo CD removed itself: no controller, and the Applications and AppProjects are stuck on its finalizer.
new_argo_cluster
rm "$state/argo-controller-up"
touch "$state/stuck-argo-apps" "$state/stuck-projects"
run_argocd --context test-cluster --timeout 5
check "with the controller gone and the finalizers stuck the run exits 0" test "$rc" -eq 0
check "seven finalizers are removed: two Applications and five AppProjects" test "$(grep -c ' patch ' "$state/kubectl.log")" = 7
check "every patch is the guarded one: test the finalizer at its position, then remove it" test "$(grep ' patch ' "$state/kubectl.log" | grep -cvE -e "$argo_patch_re")" = 0
check "the Applications patched are platform-root and argocd, once each" test "$(grep -c -e 'patch application.argoproj.io/platform-root ' -e 'patch application.argoproj.io/argocd ' "$state/kubectl.log")" = 2
check "all five AppProjects are patched" test "$(grep -c 'patch appproject.argoproj.io/platform-' "$state/kubectl.log")" = 5
check "nothing else is patched, annotated, edited or replaced" test "$(grep -c -e ' annotate ' -e ' edit ' -e ' replace ' -e ' apply ' -e ' label ' "$state/kubectl.log")" = 0
check "the output says why the Application finalizer is removed" grep -q 'the Argo CD application controller is not running, so nothing is left to run the finalizer resources-finalizer.argocd.argoproj.io on application.argoproj.io/argocd' "$work/tdout"
check "and says only that finalizer is removed" grep -q 'Removing that finalizer from application.argoproj.io/argocd only; no other finalizer or object is changed' "$work/tdout"
check "the Application finalizers go before helm uninstall" test "$(out_line 'Removing that finalizer from application.argoproj.io/argocd')" -lt "$(out_line '+ helm ')"
check "the AppProject finalizers go after helm uninstall and before the namespace is deleted" test "$(out_line '+ helm ')" -lt "$(out_line 'Removing that finalizer from appproject.argoproj.io/platform-addons')" -a "$(out_line 'Removing that finalizer from appproject.argoproj.io/platform-system')" -lt "$(out_line 'delete namespace argocd')"
check "the namespace is deleted last" test "$(line_of 'patch appproject.argoproj.io/platform-system')" -lt "$(line_of 'delete namespace argocd')"
check "no call uses --force or a grace period" test "$(cat "$state/kubectl.log" | grep -c -e '--force' -e 'grace-period')" = 0

# Only Applications that are being deleted are patched, and only the Argo CD finalizer is removed from them.
new_argo_cluster
rm "$state/argo-controller-up"
touch "$state/undeleted-argo-app"
run_argocd --context test-cluster --timeout 2
check "an Application that is not being deleted stops the script with exit 1" test "$rc" -eq 1
check "it is not patched" test "$(grep -c ' patch ' "$state/kubectl.log")" = 0
check "the message says it is not being deleted" grep -q 'application.argoproj.io/unmanaged' "$work/tdout"
check "helm is not run after that" test ! -e "$state/helm.log"

new_argo_cluster
rm "$state/argo-controller-up"
touch "$state/stuck-argo-apps" "$state/odd-finalizer-argo"
run_argocd --context test-cluster --timeout 2
check "an Application with another finalizer too has only the Argo CD one removed" test "$(grep -c ' patch ' "$state/kubectl.log")" = 2
check "the Argo CD finalizer is found at its position, after the other one" grep -q 'patch application.argoproj.io/argocd --type=json -p \[{"op":"test","path":"/metadata/finalizers/1","value":"resources-finalizer.argocd.argoproj.io"},{"op":"remove","path":"/metadata/finalizers/1"}\]' "$state/kubectl.log"
check "the run then stops with exit 1" test "$rc" -eq 1
check "and names the finalizer it left" grep -q 'Finalizers: example.com/keep' "$work/tdout"
check "helm is not run after that" test ! -e "$state/helm.log"

new_argo_cluster
rm "$state/argo-controller-up"
touch "$state/stuck-projects" "$state/odd-finalizer-projects"
run_argocd --context test-cluster --timeout 2
check "AppProjects with another finalizer too have only the Argo CD one removed" test "$(grep -c 'patch appproject' "$state/kubectl.log")" = 5
check "each AppProject patch is at the position of the Argo CD finalizer" test "$(grep -c 'patch appproject.*"path":"/metadata/finalizers/1","value":"resources-finalizer.argocd.argoproj.io"' "$state/kubectl.log")" = 5
check "the namespace stays and the run stops with exit 1" test "$rc" -eq 1
check "and the message names the namespace" grep -q 'namespace/argocd' "$work/tdout"

# The controller is still running: wait, never patch.
new_argo_cluster
touch "$state/stuck-argo-apps" "$state/stuck-projects"
run_argocd --context test-cluster --timeout 2
check "with the controller running and an Application stuck the script times out with exit 1" test "$rc" -eq 1
check "no finalizer is patched" test "$(grep -c ' patch ' "$state/kubectl.log")" = 0
check "the message names the Application and says the controller is running" grep -q 'The Argo CD application controller is running' "$work/tdout"
check "the timeout message says what it waited for" grep -q 'timed out after 2s waiting until no Application remains in the argocd namespace' "$work/tdout"
check "helm is not run and the argocd namespace is not deleted" test ! -e "$state/helm.log" -a "$(grep -c 'delete namespace argocd' "$state/kubectl.log")" = 0

new_argo_cluster
touch "$state/stuck-argo-apps" "$state/operator-api-error"
run_argocd --context test-cluster --timeout 2
check "a controller lookup that fails stops the script and patches nothing" test "$rc" -eq 1 -a "$(grep -c ' patch ' "$state/kubectl.log")" = 0
check "and the message says the lookup failed" grep -q 'could not check whether the Argo CD application controller is running' "$work/tdout"

# Volumes or claims that are still there: refuse before changing anything.
new_argo_cluster
touch "$state/stuck-pv"
run_argocd --context test-cluster --timeout 2
check "a persistent volume that is still there makes the script refuse with exit 1" test "$rc" -eq 1
check "the message names the volume and says to run teardown-prep.sh first" grep -q 'persistent volume: persistentvolume/pvc-0123' "$work/tdout"
check "and points at the other script" grep -q 'Run scripts/teardown-prep.sh --context test-cluster first' "$work/tdout"
check "nothing is deleted, patched or uninstalled" test "$(grep -c -e ' delete ' -e ' patch ' -e ' label ' "$state/kubectl.log")" = 0 -a ! -e "$state/helm.log"

new_argo_cluster
rm "$state/pvc-deleted"
touch "$state/no-pv"
run_argocd --context test-cluster --timeout 2
check "a claim in the data namespace makes the script refuse with exit 1" test "$rc" -eq 1
check "the message names the claim" grep -q 'claim in the data namespace: persistentvolumeclaim/platform-valkey' "$work/tdout"
check "nothing is deleted after the refusal" test "$(grep -c -e ' delete ' -e ' patch ' "$state/kubectl.log")" = 0

new_argo_cluster
rm "$state/pvc-deleted"
run_argocd --context test-cluster --timeout 2
check "a volume and a claim together are both named" test "$rc" -eq 1 -a "$(grep -c -e 'persistent volume: ' -e 'claim in the data namespace: ' "$work/tdout")" -ge 2
check "a refusal also applies to a dry run" test "$(PATH="$fakes:$PATH" FAKE_STATE="$state" "$teardown_argocd" --context test-cluster --dry-run > /dev/null 2>&1; echo $?)" = 1

# Kyverno policies or webhook configurations that are left: refuse before changing anything.
new_argo_cluster
printf '%s\n' clusterpolicies.kyverno.io policies.kyverno.io validatingpolicies.policies.kyverno.io imagevalidatingpolicies.policies.kyverno.io >> "$state/crds"
touch "$state/kyverno-policies"
run_argocd --context test-cluster --timeout 2
check "a Kyverno policy that is left makes the script refuse with exit 1" test "$rc" -eq 1
check "the message names it and says to run teardown-prep.sh first" grep -q 'left: clusterpolicy.kyverno.io/disallow-latest-tag' "$work/tdout"
check "a ValidatingPolicy and an ImageValidatingPolicy that are left are named too" test "$(grep -c -e 'left: validatingpolicy.policies.kyverno.io/require-image-digest' -e 'left: imagevalidatingpolicy.policies.kyverno.io/verify-image-signatures' "$work/tdout")" = 2
check "and points at the other script" grep -q 'Run scripts/teardown-prep.sh --context test-cluster first' "$work/tdout"
check "nothing is deleted, patched or uninstalled" test "$(grep -c -e ' delete ' -e ' patch ' -e ' label ' "$state/kubectl.log")" = 0 -a ! -e "$state/helm.log"

new_argo_cluster
touch "$state/kyverno-webhooks"
run_argocd --context test-cluster --timeout 2
check "a Kyverno webhook configuration that is left makes the script refuse with exit 1" test "$rc" -eq 1
check "both Kyverno webhook configurations are named, and no other" test "$(grep -c 'left: .*kyverno-' "$work/tdout")" = 2 -a "$(grep -c -e 'cert-manager-webhook' -e 'aws-load-balancer-webhook' "$work/tdout")" = 0
check "a refusal for Kyverno also applies to a dry run" test "$(PATH="$fakes:$PATH" FAKE_STATE="$state" "$teardown_argocd" --context test-cluster --dry-run > /dev/null 2>&1; echo $?)" = 1

new_argo_cluster
run_argocd --context test-cluster --timeout 5
check "without Kyverno the check passes and says so" grep -q 'ok: no Kyverno policy and no webhook configuration whose name starts with kyverno' "$work/tdout"
check "the Kyverno check is the second step, before anything is deleted" grep -q '^\[2/10\] Check that no Kyverno policy' "$work/tdout"

# Helm.
new_argo_cluster
touch "$state/helm-not-found"
run_argocd --context test-cluster --timeout 5
check "a release that is not found is fine" test "$rc" -eq 0
check "and the output says so" grep -q 'the release argocd is not installed: nothing to uninstall' "$work/tdout"
check "the remaining steps still run" grep -q 'delete namespace argocd' "$state/kubectl.log"

new_argo_cluster
touch "$state/helm-fails"
run_argocd --context test-cluster --timeout 5
check "any other helm failure stops the script with exit 1" test "$rc" -eq 1
check "and the argocd namespace is not deleted" test "$(grep -c 'delete namespace argocd' "$state/kubectl.log")" = 0

# Namespaces.
new_argo_cluster
touch "$state/stuck-ns-data"
run_argocd --context test-cluster --timeout 2
check "a namespace that never goes away stops the script with exit 1" test "$rc" -eq 1
check "the timeout message names the namespace" grep -q 'namespace/data' "$work/tdout"
check "nothing after that step is run" test "$(grep -c -e 'delete storageclass' -e 'delete application' "$state/kubectl.log")" = 0

new_argo_cluster
rm "$state/ns-data" "$state/ns-shop" "$state/obs-namespace" "$state/storageclass"
run_argocd --context test-cluster --timeout 5
check "namespaces and a storage class that are already gone are skipped" test "$rc" -eq 0
check "and are not deleted" test "$(grep -c -e 'delete namespace data' -e 'delete namespace shop' -e 'delete namespace observability' -e 'delete storageclass' "$state/kubectl.log")" = 0
check "and the skip is one short line each" test "$(grep -c -e 'no data namespace: nothing to delete' -e 'no shop namespace: nothing to delete' -e 'no observability namespace: nothing to delete' "$work/tdout")" = 3

# Dry run.
new_argo_cluster
rm "$state/argo-controller-up"
touch "$state/stuck-argo-apps" "$state/stuck-projects"
run_argocd --context test-cluster --dry-run
check "a dry run exits 0" test "$rc" -eq 0
check "a dry run runs no delete, patch or other change" test "$(grep -c -e ' delete ' -e ' patch ' -e ' label ' -e ' apply ' -e ' annotate ' "$state/kubectl.log")" = 0
check "a dry run does not call helm" test ! -e "$state/helm.log"
check "a dry run prints the commands it would run" grep -q '^  + kubectl --context test-cluster delete namespace data --wait=false$' "$work/tdout"
check "including the helm uninstall" grep -q '^  + helm --kube-context test-cluster uninstall argocd -n argocd$' "$work/tdout"
check "and marks them as not executed" grep -q 'dry run: not executed' "$work/tdout"
check "a dry run does not wait" test "$(grep -c 'waiting (' "$work/tdout")" = 0
check "a dry run with the controller gone says it would remove only the Argo CD finalizer" grep -q 'dry run: the Argo CD application controller is not running; if an Application stays stuck on the finalizer resources-finalizer.argocd.argoproj.io, would remove that one finalizer' "$work/tdout"
check "and says nothing was changed" grep -q 'Nothing was changed' "$work/tdout"

new_argo_cluster
run_argocd --context test-cluster --dry-run
check "a dry run with the controller running says it would only wait" grep -q 'dry run: the Argo CD application controller is running; would wait' "$work/tdout"

# Arguments.
new_argo_cluster
run_argocd --timeout 5
check "a missing --context is rejected with exit 2" test "$rc" -eq 2
check "and the message says so" grep -q -e '--context is required' "$work/tdout"
check "and kubectl is never called" test ! -e "$state/kubectl.log"

new_argo_cluster
run_argocd --context
check "--context without a value is rejected with exit 2" test "$rc" -eq 2
check "and the message says so" grep -q -e '--context needs a value' "$work/tdout"

new_argo_cluster
run_argocd --context test-cluster --bogus
check "an unknown option is rejected with exit 2" test "$rc" -eq 2
check "and the message names it" grep -q 'unknown argument: --bogus' "$work/tdout"
check "and nothing is called" test ! -e "$state/kubectl.log"

new_argo_cluster
run_argocd --context test-cluster --timeout soon
check "a timeout that is not a number is rejected with exit 2" test "$rc" -eq 2

new_argo_cluster
run_argocd --context no-such-context
check "an unknown context is rejected with exit 2" test "$rc" -eq 2
check "and nothing is changed" test "$(grep -c -e ' delete ' -e ' patch ' "$state/kubectl.log")" = 0

new_argo_cluster
run_argocd --help
check "--help prints the usage and exits 0" test "$rc" -eq 0 -a "$(grep -c 'teardown-argocd.sh --context CONTEXT' "$work/tdout")" = 1
check "the script never uses --force or runs version control" test "$(grep -Ec -e '--force|(^|[;&| ])git( |$)' "$teardown_argocd")" = 0
check "teardown-prep.sh ends by pointing at teardown-argocd.sh" grep -q 'scripts/teardown-argocd.sh --context' "$teardown"

echo "check-trivyignore.sh"

ignore="./scripts/check-trivyignore.sh"
# trivyignore TODAY FILE: run the check with a fixed date; output in $work/igout, status in $rc.
trivyignore() {
  rc=0
  TRIVYIGNORE_TODAY="$1" "$ignore" "$2" > "$work/igout" 2>&1 || rc=$?
}

printf '# nothing accepted\n' > "$work/ignore-empty"
trivyignore 2026-10-30 "$work/ignore-empty"
check "an ignore file without entries passes" test "$rc" -eq 0

printf '# reason: the library is only used by a build tool, never at runtime\nCVE-2026-1111 exp:2026-12-31\n' > "$work/ignore-ok"
trivyignore 2026-10-30 "$work/ignore-ok"
check "an entry with a reason and a future expiry passes" test "$rc" -eq 0
check "and the output counts the entry" grep -q 'ok (1 entry)' "$work/igout"

printf 'CVE-2026-1111 exp:2026-12-31\n' > "$work/ignore-noreason"
trivyignore 2026-10-30 "$work/ignore-noreason"
check "an entry without a reason fails" test "$rc" -eq 1
check "and the message names the entry and the missing reason" grep -q 'CVE-2026-1111 has no reason' "$work/igout"

printf '# reason: see the issue tracker\n\nCVE-2026-1111 exp:2026-12-31\n' > "$work/ignore-gap"
trivyignore 2026-10-30 "$work/ignore-gap"
check "a reason separated from its entry by a blank line does not count" test "$rc" -eq 1

printf '# reason: ok\nCVE-2026-1111 exp:2026-12-31\n' > "$work/ignore-short"
trivyignore 2026-10-30 "$work/ignore-short"
check "a reason shorter than ten characters fails" test "$rc" -eq 1

printf '# reason:\nCVE-2026-1111 exp:2026-12-31\n' > "$work/ignore-blank-reason"
trivyignore 2026-10-30 "$work/ignore-blank-reason"
check "an empty reason fails" test "$rc" -eq 1

printf '# an ordinary comment about the entry below\nCVE-2026-1111 exp:2026-12-31\n' > "$work/ignore-comment"
trivyignore 2026-10-30 "$work/ignore-comment"
check "an ordinary comment is not a reason" test "$rc" -eq 1

printf '# reason: the fix needs a major version upgrade, planned\nCVE-2026-1111\n' > "$work/ignore-noexp"
trivyignore 2026-10-30 "$work/ignore-noexp"
check "an entry without an expiry date fails" test "$rc" -eq 1
check "and the message asks for exp:YYYY-MM-DD" grep -q 'exactly one expiry, exp:YYYY-MM-DD' "$work/igout"

printf '# reason: the fix needs a major version upgrade, planned\nCVE-2026-1111 exp:2026-13-45\n' > "$work/ignore-baddate"
trivyignore 2026-10-30 "$work/ignore-baddate"
check "an expiry that is not a calendar date fails" test "$rc" -eq 1

trivyignore 2027-01-01 "$work/ignore-ok"
check "an entry whose expiry has passed fails" test "$rc" -eq 1
check "and the message says when it expired" grep -q 'expired on 2026-12-31' "$work/igout"
trivyignore 2026-12-31 "$work/ignore-ok"
check "an entry is still accepted on its expiry date" test "$rc" -eq 0

printf '# reason: the fix needs a major version upgrade, planned\nCVE-2026-1111 exp:2026-12-31 extra\n' > "$work/ignore-extra"
trivyignore 2026-10-30 "$work/ignore-extra"
check "extra text on an entry line fails" test "$rc" -eq 1

printf 'CVE-2026-1111 exp:2020-01-01\nCVE-2026-2222\n# reason: fine for now, reviewed monthly\nCVE-2026-3333 exp:2026-12-31\n' > "$work/ignore-many"
trivyignore 2026-10-30 "$work/ignore-many"
check "every problem is reported, not just the first" test "$(grep -c '^FAIL' "$work/igout")" = 4

check "the repository's .trivyignore passes the check" "$ignore" .trivyignore
rc=0
"$ignore" "$work/does-not-exist" > /dev/null 2>&1 || rc=$?
check "a missing file is rejected with exit 2" test "$rc" -eq 2
rc=0
"$ignore" --bogus > /dev/null 2>&1 || rc=$?
check "an unknown option is rejected with exit 2" test "$rc" -eq 2

echo "verify-image.sh"

verify="./scripts/verify-image.sh"
signer="https://github.com/Franklindot04/Multi-Cloud-SRE-Platform/.github/workflows/images.yml@refs/heads/main"
vd_gateway="sha256:$(printf '1%.0s' $(seq 64))"
vd_orders="sha256:$(printf '2%.0s' $(seq 64))"
vd_payments="sha256:$(printf '3%.0s' $(seq 64))"
vd_notifier="sha256:$(printf '4%.0s' $(seq 64))"
vd_other="sha256:$(printf '9%.0s' $(seq 64))"

cat > "$work/values.yaml" << VALUES
image:
  registry: ghcr.io/franklindot04
  tag: "0123456789abcdef0123456789abcdef01234567"
digests:
  gateway: "$vd_gateway"
  orders: "$vd_orders"
  payments: "$vd_payments"
  notifier: "$vd_notifier"
VALUES

# run_verify ARGS...: run with the fake cosign first on PATH and the test values file; output in $work/vout.
run_verify() {
  rc=0
  PATH="$fakes:$PATH" FAKE_STATE="$state" VALUES_FILE="$work/values.yaml" "$verify" "$@" > "$work/vout" 2>&1 || rc=$?
}

new_cluster
run_verify gateway
check "a verified image exits 0" test "$rc" -eq 0
check "and prints PASS for the signature" grep -q 'PASS  signature' "$work/vout"
check "and for the SBOM attestation" grep -q 'PASS  SBOM attestation (spdxjson)' "$work/vout"
check "and for the build provenance" grep -q 'PASS  build provenance (slsaprovenance1)' "$work/vout"
check "and for the image" grep -q '^PASS  gateway$' "$work/vout"
check "and says how many verified" grep -q '^PASS: 1 of 1 image(s) verified' "$work/vout"
check "the default digest comes from the values file" grep -q "ghcr.io/franklindot04/gateway@$vd_gateway" "$state/cosign.log"
check "three cosign calls are made: verify, then the two attestations" test "$(awk '{print $1}' "$state/cosign.log" | tr '\n' ' ')" = "verify verify-attestation verify-attestation "
check "the attestation types are spdxjson and slsaprovenance1" test "$(grep -c -e '--type spdxjson' -e '--type slsaprovenance1' "$state/cosign.log")" = 2
check "every call pins the exact signer identity" test "$(grep -c -e "--certificate-identity $signer " "$state/cosign.log")" = 3
check "every call pins the GitHub Actions issuer" test "$(grep -c -e '--certificate-oidc-issuer https://token.actions.githubusercontent.com ' "$state/cosign.log")" = 3
check "no call uses an identity pattern or skips a check" test "$(grep -c -e 'identity-regexp' -e 'issuer-regexp' -e 'insecure' -e 'private-infrastructure' "$state/cosign.log")" = 0
check "the script text does not weaken verification either" test "$(grep -c -e 'identity-regexp' -e 'issuer-regexp' -e 'insecure' -e 'private-infrastructure' -e 'skip' "$verify")" = 0
check "the image is always referenced by digest" test "$(grep -c '@sha256:' "$state/cosign.log")" = 3

new_cluster
run_verify orders "$vd_other"
check "a digest argument replaces the one in the values file" grep -q "ghcr.io/franklindot04/orders@$vd_other" "$state/cosign.log"
check "and the values file digest is not used" test "$(grep -c "$vd_orders" "$state/cosign.log")" = 0

new_cluster
run_verify all
check "all verifies the four images" test "$rc" -eq 0 -a "$(grep -c '^PASS  [a-z]*$' "$work/vout")" = 4
check "all makes twelve cosign calls" test "$(wc -l < "$state/cosign.log" | tr -d ' ')" = 12
check "all uses each image's digest from the values file" test "$(grep -c -e "orders@$vd_orders" -e "payments@$vd_payments" -e "notifier@$vd_notifier" -e "gateway@$vd_gateway" "$state/cosign.log")" = 12
check "all says 4 of 4" grep -q '^PASS: 4 of 4 image(s) verified' "$work/vout"

new_cluster
touch "$state/no-signature"
run_verify gateway
check "a missing signature exits 1" test "$rc" -eq 1
check "and prints FAIL for the signature" grep -q 'FAIL  signature' "$work/vout"
check "and the other checks still run and pass or fail on their own" test "$(grep -c -e 'PASS  SBOM' -e 'PASS  build provenance' "$work/vout")" = 2
check "and the image is reported as failed" grep -q '^FAIL  gateway$' "$work/vout"
check "and the cosign error is shown" grep -q 'no signatures found' "$work/vout"
check "and the summary says FAIL" grep -q '^FAIL: 1 of 1 image(s) did not verify' "$work/vout"

new_cluster
touch "$state/no-sbom"
run_verify gateway
check "a missing SBOM attestation exits 1" test "$rc" -eq 1 -a "$(grep -c 'FAIL  SBOM attestation' "$work/vout")" = 1

new_cluster
touch "$state/no-provenance"
run_verify gateway
check "missing provenance exits 1" test "$rc" -eq 1 -a "$(grep -c 'FAIL  build provenance' "$work/vout")" = 1

new_cluster
printf 'https://github.com/Franklindot04/Multi-Cloud-SRE-Platform/.github/workflows/images.yml@refs/heads/feature\n' > "$state/signer"
run_verify gateway
check "an image signed from another branch fails all three checks" test "$rc" -eq 1 -a "$(grep -c '^  FAIL' "$work/vout")" = 3

new_cluster
printf 'https://github.com/someone-else/Multi-Cloud-SRE-Platform/.github/workflows/images.yml@refs/heads/main\n' > "$state/signer"
run_verify gateway
check "an image signed by another repository fails" test "$rc" -eq 1

new_cluster
printf 'https://example.com/issuer\n' > "$state/issuer"
run_verify gateway
check "an image from another OIDC issuer fails" test "$rc" -eq 1

new_cluster
printf '%s\n' "$vd_payments" > "$state/unsigned"
run_verify all
check "one unsigned image among four makes the run exit 1" test "$rc" -eq 1
check "and only that image is reported as failed" test "$(grep -c '^FAIL  [a-z]*$' "$work/vout")" = 1 -a "$(grep -c '^PASS  [a-z]*$' "$work/vout")" = 3
check "and the summary counts it" grep -q '^FAIL: 1 of 4 image(s) did not verify' "$work/vout"

new_cluster
rc=0
SIGNER_REPOSITORY=Other/fork PATH="$fakes:$PATH" FAKE_STATE="$state" VALUES_FILE="$work/values.yaml" "$verify" gateway > "$work/vout" 2>&1 || rc=$?
check "SIGNER_REPOSITORY changes the pinned identity" grep -q -e '--certificate-identity https://github.com/Other/fork/.github/workflows/images.yml@refs/heads/main ' "$state/cosign.log"
check "and an image signed by the default repository then fails" test "$rc" -eq 1

new_cluster
run_verify
check "no service is rejected with exit 2" test "$rc" -eq 2
check "and the message asks for a service" grep -q 'a service name is required' "$work/vout"
check "and cosign is never called" test ! -e "$state/cosign.log"
run_verify frontend
check "an unknown service is rejected with exit 2" test "$rc" -eq 2
run_verify gateway latest
check "a tag instead of a digest is rejected with exit 2" test "$rc" -eq 2
run_verify gateway "sha256:abc"
check "a short digest is rejected with exit 2" test "$rc" -eq 2
run_verify gateway "sha256:$(printf 'A%.0s' $(seq 64))"
check "an upper-case digest is rejected with exit 2" test "$rc" -eq 2
run_verify all "$vd_gateway"
check "a digest together with all is rejected with exit 2" test "$rc" -eq 2
run_verify gateway "$vd_gateway" extra
check "too many arguments are rejected with exit 2" test "$rc" -eq 2
run_verify --bogus gateway
check "an unknown option is rejected with exit 2" test "$rc" -eq 2
check "none of the rejected calls reached cosign" test ! -e "$state/cosign.log"

rc=0
printf 'digests: {}\n' > "$work/values-empty.yaml"
PATH="$fakes:$PATH" FAKE_STATE="$state" VALUES_FILE="$work/values-empty.yaml" "$verify" gateway > "$work/vout" 2>&1 || rc=$?
check "a service without a digest in the values file is rejected with exit 2" test "$rc" -eq 2
check "and the message says to pass one" grep -q 'pass one as the second argument' "$work/vout"

rc=0
PATH="/usr/bin:/bin" FAKE_STATE="$state" VALUES_FILE="$work/values.yaml" "$verify" gateway > "$work/vout" 2>&1 || rc=$?
check "a missing cosign is rejected with exit 2" test "$rc" -eq 2
check "and the message names cosign" grep -q 'cosign is not installed' "$work/vout"
check "neither script runs a version control command" test "$(cat "$verify" "$ignore" | grep -Ec '(^|[;&| ])git( |$)')" = 0

echo "bootstrap-argocd.sh (--enable-observability)"

bootstrap="./scripts/bootstrap-argocd.sh"
# The dry run must not touch a cluster, a cloud account or Terraform: these stand-ins record any call and fail it.
stubs="$work/stubs"
mkdir -p "$stubs"
for tool in kubectl helm aws terraform; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\nexit 99\n' "$tool" "$stubs" > "$stubs/$tool"
  chmod +x "$stubs/$tool"
done

# run_bootstrap ARGS...: a dry run with the stand-ins first on PATH; output in $work/bout, status in $rc.
run_bootstrap() {
  rc=0
  PATH="$stubs:$PATH" "$bootstrap" --context test-context --dry-run "$@" > "$work/bout" 2>&1 || rc=$?
}

run_bootstrap
check "a plain dry run exits 0" test "$rc" -eq 0
check "observability is off by default" grep -q '"platform.example/observability": "false"' "$work/bout"
check "and nothing says it is enabled" test "$(grep -c 'observability enabled' "$work/bout")" = 0
check "the dry run called no cluster, cloud or Terraform tool" test ! -e "$stubs/calls.log"
check "the cluster secret carries the VPC range for the network policies" grep -q '"platform.example/vpc-cidr": "<vpc_cidr_block>"' "$work/bout"
check "and the Service range, from the Terraform output service_cidr_block" grep -q '"platform.example/service-cidr": "<service_cidr_block>"' "$work/bout"
check "the script reads both outputs and checks the Service range's format" test "$(grep -c -e 'tf_value service_cidr_block' -e 'require_match service_cidr_block' -e 'Terraform output service_cidr_block is empty' scripts/bootstrap-argocd.sh)" = 3

run_bootstrap --enable-observability
check "the flag exits 0 on its own" test "$rc" -eq 0
check "the flag sets the label to true" grep -q '"platform.example/observability": "true"' "$work/bout"
check "the label is written once" test "$(grep -c 'platform.example/observability' "$work/bout")" = 1
check "the output says what the flag does and costs" grep -q 'observability enabled: Prometheus, Alertmanager, Grafana, Loki and Tempo keep their data in emptyDir' "$work/bout"
check "the output gives the current size of the stack, as rendered" grep -q 'about 0.5 vCPU and 1.5 GiB of memory (515m and 1560Mi)' "$work/bout"
check "and says that alerts are sent nowhere" grep -q 'alerts are recorded in Alertmanager and sent nowhere' "$work/bout"
check "and that there is no ingress" grep -q 'there is no ingress' "$work/bout"
check "the other feature labels stay false" test "$(grep -c -e '"platform.example/data": "false"' -e '"platform.example/apps": "false"' -e '"platform.example/external-dns": "false"' -e '"platform.example/dns01": "false"' "$work/bout")" = 4
check "the cluster is still registered as managed on AWS" grep -q '"platform.example/cloud": "aws"' "$work/bout"
check "the dry run still called no tool" test ! -e "$stubs/calls.log"

run_bootstrap --enable-data --enable-apps --apps-profile data --enable-observability
check "together with the data layer and the services it exits 0" test "$rc" -eq 0
check "every label is set on the same run" test "$(grep -c -e '"platform.example/observability": "true"' -e '"platform.example/data": "true"' -e '"platform.example/apps": "true"' -e '"platform.example/apps-profile": "data"' "$work/bout")" = 4

run_bootstrap --enable-observability extra
check "the flag takes no value" test "$rc" -eq 1
check "and the message names the argument" grep -q 'unknown argument: extra' "$work/bout"

"$bootstrap" --help > "$work/bout" 2>&1
check "the help lists the flag" grep -q -e '--enable-observability' "$work/bout"
check "and says it is off by default" test "$(sed -n '/--enable-observability/,/--enable-apps/p' "$work/bout" | grep -c 'off by')" -ge 1
check "and says how to reach Grafana" test "$(sed -n '/--enable-observability/,/--enable-apps/p' "$work/bout" | grep -c 'port-forward')" -ge 1

# The label the script writes must be the one the ApplicationSets select on, or the flag deploys nothing.
check "every observability ApplicationSet selects the label the flag sets" test "$(grep -l 'platform.example/observability: "true"' platform/argocd/apps/9*-observability-*.yaml | wc -l | tr -d ' ')" = 9
check "no other ApplicationSet selects it" test "$(grep -l 'platform.example/observability' platform/argocd/apps/*.yaml | grep -vc '/9[0-9]-observability-')" = 0

run_bootstrap
check "the policy engine is off by default" grep -q '"platform.example/policy": "false"' "$work/bout"
check "and nothing says it is enabled" test "$(grep -c 'policy engine enabled' "$work/bout")" = 0

run_bootstrap --enable-policy
check "the policy flag exits 0 on its own" test "$rc" -eq 0
check "the policy flag sets the label to true" grep -q '"platform.example/policy": "true"' "$work/bout"
check "the policy label is written once" test "$(grep -c 'platform.example/policy' "$work/bout")" = 1
check "the output says what the flag deploys and what it asks for" grep -q 'policy engine enabled: Kyverno (admission, background, cleanup and reports controllers, no policies) in the kyverno namespace, requests 225m CPU and 320Mi of memory' "$work/bout"
check "and that the webhooks fail open and skip the system namespaces" grep -q 'its webhooks fail open and skip kube-system, kube-node-lease, argocd and kyverno' "$work/bout"
check "and that the network policies need the ranges from the cluster Secret" grep -q 'the network policies need the VPC and Service ranges from the cluster Secret' "$work/bout"
check "the observability and data labels stay false" test "$(grep -c -e '"platform.example/observability": "false"' -e '"platform.example/data": "false"' "$work/bout")" = 2
check "the dry run with the policy flag called no tool" test ! -e "$stubs/calls.log"

run_bootstrap --enable-policy --enable-observability --enable-data
check "with the other layers every label is set on the same run" test "$(grep -c -e '"platform.example/observability": "true"' -e '"platform.example/data": "true"' -e '"platform.example/policy": "true"' "$work/bout")" = 3

run_bootstrap --enable-policy extra
check "the policy flag takes no value" test "$rc" -eq 1
check "and the message names the argument" grep -q 'unknown argument: extra' "$work/bout"

"$bootstrap" --help > "$work/bout" 2>&1
check "the help lists the policy flag" grep -q -e '--enable-policy' "$work/bout"
check "and says it is off by default" test "$(sed -n '/--enable-policy/,/--enable-apps/p' "$work/bout" | grep -c 'Off by default')" -ge 1
check "and what it requests" test "$(sed -n '/--enable-policy/,/--enable-apps/p' "$work/bout" | grep -c '225m CPU and 320Mi of memory')" -ge 1

echo "chart-contract-check.py (observability checks)"

contract_py="$(./scripts/python-with-yaml.sh)" || contract_py=""
obs="$fixtures/observability"
project="platform/argocd/bootstrap/appproject-platform-observability.yaml"

# contract FILE ARGS...: run one check on a manifest file; output in $work/cout, status in $rc.
contract() {
  local file="$1"
  shift
  rc=0
  "$contract_py" scripts/chart-contract-check.py "$@" < "$file" > "$work/cout" 2>&1 || rc=$?
}

if [ -z "$contract_py" ]; then
  echo "  skip  no Python with PyYAML found (installing yamllint provides it)"
else
  contract "$obs/compliant.yaml" restricted t
  check "a locked-down workload meets the restricted level" test "$rc" -eq 0
  contract "$obs/privileged.yaml" restricted t
  check "a host-network, hostPath, privileged workload does not" test "$rc" -eq 1
  check "the failure names hostNetwork" grep -q 'sets hostNetwork' "$work/cout"
  check "and the hostPath volume" grep -q 'volume type hostPath (root)' "$work/cout"
  check "and the host port" grep -q 'uses hostPort 9100' "$work/cout"
  check "and the missing capability drop" grep -q 'must drop ALL capabilities' "$work/cout"
  check "and the user 0" grep -q 'runs as user 0' "$work/cout"
  contract "$obs/prometheus-unsafe.yaml" restricted t
  check "a Prometheus resource that would run as root is refused" test "$rc" -eq 1
  check "and so is one without a seccomp profile" grep -q 'needs a seccomp profile' "$work/cout"

  contract "$obs/loki-ok.yaml" loki t
  check "a single-tenant TSDB v13 filesystem Loki with retention passes (the older schema entry is ignored)" test "$rc" -eq 0
  contract "$obs/loki-bad.yaml" loki t
  check "a Loki with tenants, an old schema, object storage, no retention and no limits fails" test "$rc" -eq 1
  check "the tenant setting is named" grep -q 'auth_enabled must be false' "$work/cout"
  check "the schema is named" grep -q 'must be store tsdb, schema v13 (it is tsdb, v12)' "$work/cout"
  check "the storage is named" grep -q 'common.storage must be the filesystem' "$work/cout"
  check "the compactor is named" grep -q 'compactor.retention_enabled must be true' "$work/cout"
  check "a retention longer than a week is named" grep -q "retention_period must be set in hours and be at most 168h (it is '720h')" "$work/cout"
  check "a missing limit is named" grep -q 'limits_config.max_line_size must be set' "$work/cout"
  contract "$obs/tempo-ok.yaml" tempo t
  check "a single-tenant Tempo with local storage, a day of retention and only the OTLP receiver passes" test "$rc" -eq 0
  contract "$obs/tempo-bad.yaml" tempo t
  check "a Tempo with tenants, object storage, a month of retention, a Jaeger receiver and a metrics generator fails" test "$rc" -eq 1
  check "the tenant setting is named" grep -q 'multitenancy_enabled must be false' "$work/cout"
  check "the storage is named" grep -q 'storage.trace.backend must be local' "$work/cout"
  check "the retention is named" grep -q "block_retention must be set in hours and be at most 72h (it is '720h')" "$work/cout"
  check "the receivers are named" grep -q 'must receive only otlp (it has jaeger, otlp)' "$work/cout"
  check "the metrics generator is named" grep -q 'the metrics generator needs a remote-write endpoint' "$work/cout"
  check "the usage report is named" grep -q 'usage_report.reporting_enabled must be false' "$work/cout"
  contract "$obs/datasources-ok.yaml" grafana-datasources t
  check "data sources with unique uids, a Loki derived field that finds the trace id and the links both ways pass" test "$rc" -eq 0
  contract "$obs/datasources-bad.yaml" grafana-datasources t
  check "a derived field with a loose expression and a wrong uid, and a Tempo link to the wrong data source fail" test "$rc" -eq 1
  check "the wrong derived field uid is named" grep -q 'must link to the Tempo data source by its uid (it links to tempo-typo)' "$work/cout"
  check "the loose expression is rejected on a log line it should find" grep -q 'does not find the trace id in a gateway log line' "$work/cout"
  check "and on a line it should not match" grep -q 'matches a line that has no trace id in the format of the services' "$work/cout"
  check "the derived field url is named" grep -q 'the derived field url must be' "$work/cout"
  check "the trace to logs target is named" grep -q 'must point at the Loki data source by its uid (it points at prometheus)' "$work/cout"
  check "the missing time shift is named" grep -q 'needs a time shift before (negative) and after (positive) the span' "$work/cout"
  check "the service map is named" grep -q 'serviceMap needs metrics from Tempo' "$work/cout"
  check "the node graph is named" grep -q 'the node graph needs the metrics generator of Tempo' "$work/cout"
  check "the wrong Alertmanager port is named" grep -q 'must point at port 9093 of the Alertmanager Service' "$work/cout"
  check "and an Alertmanager that handles Grafana-managed alerts" grep -q 'must not handle Grafana-managed alerts' "$work/cout"
  sed '/- name: Alertmanager/,/implementation: prometheus/d' "$obs/datasources-ok.yaml" > "$work/datasources-no-am.yaml"
  contract "$work/datasources-no-am.yaml" grafana-datasources t
  check "data sources without Alertmanager fail" test "$rc" -eq 1
  check "and the missing uid is named" grep -q 'no data source with the uid alertmanager' "$work/cout"
  contract "$obs/alloy-ok.yaml" alloy t
  check "an Alloy that reads the API for two namespaces and stores the level as metadata passes" test "$rc" -eq 0
  contract "$obs/alloy-bad.yaml" alloy t
  check "an Alloy that reads files from the node, makes labels and reads Secrets fails" test "$rc" -eq 1
  check "the file source is named" grep -q 'loki.source.file reads files or CRDs from the node' "$work/cout"
  check "the missing API source is named" grep -q 'must be read with loki.source.kubernetes' "$work/cout"
  check "the label stage is named" grep -q 'stage.labels would turn parts of a log line into labels' "$work/cout"
  check "the extra namespace is named" grep -q 'exactly data, shop (found data, kube-system, shop)' "$work/cout"
  check "the Secret access is named" grep -q 'can read pods, secrets' "$work/cout"

  contract "$obs/compliant.yaml" ephemeral t
  check "a workload with only an emptyDir is ephemeral" test "$rc" -eq 0
  contract "$obs/stateful.yaml" ephemeral t
  check "claims, Prometheus and Alertmanager storage, an Ingress and a load balancer are refused" test "$rc" -eq 1
  check "the claim is named" grep -q 'PersistentVolumeClaim/data is rendered' "$work/cout"
  check "the claim template is named" grep -q 'StatefulSet/db has volume claim templates' "$work/cout"
  check "the Prometheus storage is named" grep -q 'Prometheus/demo has persistent storage' "$work/cout"
  check "the Alertmanager storage is named" grep -q 'Alertmanager/demo has persistent storage' "$work/cout"
  check "the Ingress is named" grep -q 'Ingress/demo is rendered' "$work/cout"
  check "the load balancer is named" grep -q 'is a LoadBalancer Service' "$work/cout"

  contract "$obs/grafana-secret-ref.yaml" grafana-admin t
  check "Grafana reading the generated Secret passes" test "$rc" -eq 0
  contract "$obs/grafana-literal.yaml" grafana-admin t
  check "Grafana with a literal password fails" test "$rc" -eq 1
  check "and the literal variable is named" grep -q 'sets GF_SECURITY_ADMIN_PASSWORD to a literal value' "$work/cout"
  check "and a Secret carrying a password fails" grep -q 'Secret/demo-grafana carries a password' "$work/cout"
  contract "$obs/compliant.yaml" grafana-admin t
  check "a stream without Grafana fails the Grafana check" test "$rc" -eq 1

  contract "$obs/compliant.yaml" digest-pinned t
  check "an image pinned by digest passes" test "$rc" -eq 0
  contract "$obs/unpinned.yaml" digest-pinned t
  check "an image pinned by tag only fails" test "$rc" -eq 1

  contract "$obs/inside-project.yaml" project-fit t "$project" observability
  check "resources the AppProject allows pass, with the default namespace applied" test "$rc" -eq 0
  contract "$obs/outside-project.yaml" project-fit t "$project" observability
  check "resources it does not allow fail" test "$rc" -eq 1
  check "the cluster-scoped kind is named" grep -q 'ValidatingWebhookConfiguration/demo (admissionregistration.k8s.io) is cluster-scoped and not in clusterResourceWhitelist' "$work/cout"
  check "the namespaced kind is named" grep -q 'DaemonSet/demo (apps) is not in namespaceResourceWhitelist' "$work/cout"
  check "the namespace is named" grep -q 'Deployment/demo is in the namespace shop' "$work/cout"

  # CRDs are built here because a realistic one is far larger than a fixture should be.
  "$contract_py" - "$work" << 'PYEOF'
import sys
import yaml

out = sys.argv[1]
PLURALS = ["alertmanagers", "podmonitors", "probes", "prometheuses", "prometheusrules", "servicemonitors"]


def crd(plural, storage=(True,), pad=0):
    versions = [
        {
            "name": "v1" if i == 0 else "v1beta{}".format(i),
            "served": True,
            "storage": flag,
            "schema": {"openAPIV3Schema": {"type": "object", "description": "x" * pad}},
        }
        for i, flag in enumerate(storage)
    ]
    return {
        "apiVersion": "apiextensions.k8s.io/v1",
        "kind": "CustomResourceDefinition",
        "metadata": {"name": plural + ".monitoring.coreos.com"},
        "spec": {
            "group": "monitoring.coreos.com",
            "scope": "Namespaced",
            "names": {"plural": plural, "kind": plural[:-1].capitalize()},
            "versions": versions,
        },
    }


def write(name, docs):
    with open("{}/{}".format(out, name), "w") as f:
        yaml.safe_dump_all(docs, f)


write("crds-ok.yaml", [crd(p) for p in PLURALS])
write("crds-missing.yaml", [crd(p) for p in PLURALS if p != "podmonitors"])
write("crds-two-storage.yaml", [crd(p, storage=(True, True)) if p == "probes" else crd(p) for p in PLURALS])
write("crds-large.yaml", [crd(p, pad=300000) if p == "prometheuses" else crd(p) for p in PLURALS])
write("crds-none.yaml", [])
PYEOF
  stack_app="platform/argocd/apps/91-observability-stack.yaml"
  grep -v 'ServerSideApply=true' "$stack_app" > "$work/stack-no-ssa.yaml"
  contract "$work/crds-ok.yaml" crds t "$stack_app"
  check "well-formed CRDs pass" test "$rc" -eq 0
  contract "$work/crds-none.yaml" crds t "$stack_app"
  check "a render with no CRDs fails" test "$rc" -eq 1
  contract "$work/crds-missing.yaml" crds t "$stack_app"
  check "a missing CRD is named" grep -q 'podmonitors.monitoring.coreos.com is not rendered' "$work/cout"
  contract "$work/crds-two-storage.yaml" crds t "$stack_app"
  check "two storage versions fail" grep -q 'probes.monitoring.coreos.com must have exactly one storage version' "$work/cout"
  contract "$work/crds-large.yaml" crds t "$stack_app"
  check "a CRD over the annotation limit passes when the Application uses server-side apply" test "$rc" -eq 0
  contract "$work/crds-large.yaml" crds t "$work/stack-no-ssa.yaml"
  check "and fails when it does not" test "$rc" -eq 1
  check "and the message names the CRD and the sync option" grep -q 'prometheuses.monitoring.coreos.com.*ServerSideApply=true' "$work/cout"
  contract "$work/crds-ok.yaml" crds t "$work/stack-no-ssa.yaml"
  check "small CRDs do not need server-side apply" test "$rc" -eq 0

  # Sync waves: the real files agree with the README, and a misplaced wave is caught.
  rc=0
  "$contract_py" scripts/chart-contract-check.py waves platform/argocd/apps platform/argocd/README.md > "$work/cout" 2>&1 || rc=$?
  check "the real sync waves are in the documented order and match the README" test "$rc" -eq 0
  rm -rf "$work/apps"
  cp -R platform/argocd/apps "$work/apps"
  sed 's/sync-wave: "13"/sync-wave: "9"/' platform/argocd/apps/93-observability-monitors.yaml > "$work/apps/93-observability-monitors.yaml"
  rc=0
  "$contract_py" scripts/chart-contract-check.py waves "$work/apps" platform/argocd/README.md > "$work/cout" 2>&1 || rc=$?
  check "monitors before the stack's CRDs fail the wave check" test "$rc" -eq 1
  check "the failure names both" grep -q 'observability-stack (wave 11) must come before observability-monitors (wave 9)' "$work/cout"
  check "and the README mismatch" grep -q 'observability-monitors: wave 9' "$work/cout"
  cp platform/argocd/apps/93-observability-monitors.yaml "$work/apps/93-observability-monitors.yaml"
  grep -v 'sync-wave: "10"' platform/argocd/apps/90-observability-secrets.yaml > "$work/apps/90-observability-secrets.yaml"
  rc=0
  "$contract_py" scripts/chart-contract-check.py waves "$work/apps" platform/argocd/README.md > "$work/cout" 2>&1 || rc=$?
  check "an observability ApplicationSet without a wave fails" test "$rc" -eq 1
fi

echo "chart-contract-check.py (Alertmanager)"

if [ -z "$contract_py" ]; then
  echo "  skip  no Python with PyYAML found (installing yamllint provides it)"
else
  am="$work/am-cases"
  rm -rf "$am"
  mkdir -p "$am"
  # The good case is a reduced render of the stack; each bad case changes one thing in it.
  "$contract_py" - "$obs/alertmanager-ok.yaml" "$am" << 'AMPY'
import copy
import sys

import yaml

src, out = sys.argv[1], sys.argv[2]
base = list(yaml.safe_load_all(open(src, encoding="utf-8")))


def of(docs, kind):
    return next(d for d in docs if d["kind"] == kind)


def config_of(docs):
    return yaml.safe_load(of(docs, "Secret")["stringData"]["alertmanager.yaml"])


def save_config(docs, config):
    of(docs, "Secret")["stringData"]["alertmanager.yaml"] = yaml.safe_dump(config, sort_keys=False)


cases = {}


def case(name, change):
    docs = copy.deepcopy(base)
    change(docs)
    cases[name] = docs


def edit_config(change):
    def apply(docs):
        config = config_of(docs)
        change(config)
        save_config(docs, config)
    return apply


case("good", lambda d: None)
case("replicas", lambda d: of(d, "Alertmanager")["spec"].update(replicas=2))
case("limits", lambda d: of(d, "Alertmanager")["spec"]["resources"].pop("limits"))
case("local", lambda d: of(d, "Alertmanager")["spec"].update(listenLocal=True))
case("unwired", lambda d: of(d, "Prometheus")["spec"].update(alerting={}))
case("ingress", lambda d: d.append({"apiVersion": "networking.k8s.io/v1", "kind": "Ingress", "metadata": {"name": "am", "namespace": "observability"}, "spec": {}}))
case("nosecret", lambda d: d.remove(of(d, "Secret")))
case("receiver", edit_config(lambda c: c["receivers"][2].update(webhook_configs=[{"url_file": "/etc/alertmanager/secrets/hook"}])))
case("global", edit_config(lambda c: c["global"].update(slack_api_url="x")))
case("pageroute", edit_config(lambda c: c["route"]["routes"][0].update(receiver="ticket")))
case("ticketroute", edit_config(lambda c: c["route"]["routes"].pop(1)))
case("extraroute", edit_config(lambda c: c["route"]["routes"].append({"matchers": ['severity = "critical"'], "receiver": "page"})))
case("defaultroute", edit_config(lambda c: c["route"].update(receiver="page")))
case("groupby", edit_config(lambda c: c["route"].update(group_by=["alertname"])))
case("timing", edit_config(lambda c: c["route"].pop("repeat_interval")))
case("noreceiver", edit_config(lambda c: c["receivers"].pop(0)))
case("inhibit-page", edit_config(lambda c: c["inhibit_rules"].pop(0)))
case("inhibit-down", edit_config(lambda c: c["inhibit_rules"].pop(1)))
case("inhibit-equal", edit_config(lambda c: c["inhibit_rules"][0].update(equal=["slo"])))
for name, docs in cases.items():
    yaml.safe_dump_all(docs, open("{}/{}.yaml".format(out, name), "w", encoding="utf-8"), sort_keys=False)
AMPY

  am_fails() {
    # am_fails CASE MESSAGE LABEL: the case fails and the output names the problem.
    contract "$am/$1.yaml" alertmanager t
    if [ "$rc" -eq 1 ] && grep -qF -- "$2" "$work/cout"; then ok "$3"; else bad "$3 (exit $rc)"; fi
  }
  contract "$am/good.yaml" alertmanager t
  check "an Alertmanager with one replica, limits, a wired Prometheus, page and ticket routes, empty receivers and both inhibitions passes" test "$rc" -eq 0
  am_fails replicas "the Alertmanager must have one replica (it has 2)" "two replicas are refused"
  am_fails limits "the Alertmanager needs resources.limits.cpu" "missing limits are named"
  am_fails local "listens on localhost only" "an Alertmanager Prometheus cannot reach is named"
  am_fails unwired "Prometheus does not send alerts to the Alertmanager demo-alertmanager" "a Prometheus that does not send alerts to it is named"
  am_fails ingress "an Ingress is rendered; access is by port-forward only" "an Ingress is refused"
  am_fails nosecret "no Secret alertmanager-demo-alertmanager with the configuration" "a missing configuration Secret is named"
  am_fails receiver "the receiver ticket is not empty (it has webhook_configs)" "a receiver that sends somewhere is refused"
  am_fails global "the global section holds something that looks like a URL, token or password" "a credential in the global section is refused"
  am_fails pageroute "severity page must be routed to the receiver page (it goes to ticket)" "a page alert routed to the ticket receiver is named"
  am_fails ticketroute "severity ticket must be routed to the receiver ticket (it goes to None)" "a missing ticket route is named"
  am_fails extraroute "only the severities page and ticket have routes (found critical, page, ticket)" "a route for another severity is named"
  am_fails defaultroute "the root route must send to the receiver default (it sends to page)" "a default route to the page receiver is named"
  am_fails groupby "the root route must group by alertname, slo and service" "the wrong grouping is named"
  am_fails timing "the root route needs repeat_interval" "a missing repeat interval is named"
  am_fails noreceiver "the configuration has no receiver default" "a missing receiver is named"
  am_fails inhibit-page "the inhibition from ['severity = \"page\"'] to ['severity = \"ticket\"'] on ['slo', 'service'] is missing" "a missing page-hides-ticket inhibition is named"
  am_fails inhibit-down "the inhibition from ['alertname = \"ServiceTargetDown\"'] to ['alertname =~ \"SLOBurnRate.*\"'] on ['service'] is missing" "a missing target-down inhibition is named"
  am_fails inhibit-equal "the inhibition from ['severity = \"page\"'] to ['severity = \"ticket\"'] on ['slo', 'service'] is missing" "an inhibition on too few labels is named"
fi

echo "chart-contract-check.py (SLO rules)"

if [ -z "$contract_py" ]; then
  echo "  skip  no Python with PyYAML found (installing yamllint provides it)"
else
  slo="$work/slo-cases"
  rm -rf "$slo"
  mkdir -p "$slo"
  # The rendered PrometheusRule of the monitors chart is the good case; each bad case changes one thing in it.
  "$contract_py" - "$obs/slo-rules-ok.yaml" "$slo" << 'SLOPY'
import copy
import re
import sys

import yaml

src, out = sys.argv[1], sys.argv[2]
base = yaml.safe_load(open(src, encoding="utf-8"))


def rules(doc):
    return [r for g in doc["spec"]["groups"] for r in g["rules"]]


def find(doc, name, slo):
    for r in rules(doc):
        if (r.get("record") == name or r.get("alert") == name) and (r.get("labels") or {}).get("slo") == slo:
            return r
    raise KeyError(name + " " + slo)


def drop(doc, name, slo):
    for g in doc["spec"]["groups"]:
        g["rules"] = [r for r in g["rules"] if not ((r.get("record") == name or r.get("alert") == name) and r["labels"].get("slo") == slo)]


GA, GL = "gateway-availability", "gateway-latency"
cases = {}


def case(name, change):
    doc = copy.deepcopy(base)
    change(doc)
    cases[name] = doc


case("good", lambda d: None)
case("burn", lambda d: find(d, "SLOBurnRatePageFast", GA).update(expr=find(d, "SLOBurnRatePageFast", GA)["expr"].replace("14.4", "10")))
case("window", lambda d: find(d, "SLOBurnRatePageSlow", GA).update(expr=find(d, "SLOBurnRatePageSlow", GA)["expr"].replace("ratio_rate30m", "ratio_rate1h")))
case("noguard", lambda d: find(d, "SLOBurnRateTicketFast", GA).update(expr=find(d, "SLOBurnRateTicketFast", GA)["expr"].rsplit("\nand\n", 1)[0]))
case("lowguard", lambda d: find(d, "SLOBurnRatePageFast", GA).update(expr=re.sub(r">= [0-9.]+$", ">= 1", find(d, "SLOBurnRatePageFast", GA)["expr"])))
case("bucket", lambda d: find(d, "slo:sli_error:ratio_rate5m", GL).update(expr=find(d, "slo:sli_error:ratio_rate5m", GL)["expr"].replace('le="0.5"', 'le="0.3"')))
case("budget", lambda d: find(d, "slo:error_budget:ratio", GA).update(expr="vector(0.01)"))
case("norunbook", lambda d: find(d, "SLOBurnRatePageFast", GA)["annotations"].pop("runbook_url"))
case("noanchor", lambda d: find(d, "SLOBurnRatePageFast", GA)["annotations"].update(runbook_url="https://example.com/docs/runbooks/alerts.md"))
case("route", lambda d: find(d, "slo:sli_error:ratio_rate1h", GA).update(expr=find(d, "slo:sli_error:ratio_rate1h", GA)["expr"].replace("/readyz|", "")))
case("client", lambda d: find(d, "slo:sli_error:ratio_rate5m", GA).update(expr=find(d, "slo:sli_error:ratio_rate5m", GA)["expr"].replace('status!~"4.."', 'status!~"9.."')))
case("metric", lambda d: find(d, "slo:sli_error:ratio_rate1h", "notifier-delivery").update(expr=find(d, "slo:sli_error:ratio_rate1h", "notifier-delivery")["expr"].replace("messages_consumed_total", "messages_handled_total")))
case("nowindow", lambda d: drop(d, "slo:sli_error:ratio_rate2h", GA))
case("noevents", lambda d: drop(d, "slo:sli_events:increase1d", GL))
case("severity", lambda d: find(d, "SLOBurnRateTicketFast", GA)["labels"].update(severity="page"))
case("name", lambda d: find(d, "slo:sli_error:ratio_rate6h", GA).update(record="slo_sli_error_6h"))
case("range", lambda d: find(d, "slo:sli_error:ratio_rate1h", GA).update(expr=find(d, "slo:sli_error:ratio_rate1h", GA)["expr"].replace("[1h]", "[5m]")))
case("nofor", lambda d: find(d, "SLOBurnRateTicketSlow", GA).pop("for"))
case("noservice", lambda d: [r["labels"].pop("service") for r in rules(d) if r.get("alert") == "OutboxBacklog"])
case("noalert", lambda d: drop(d, "SLOBurnRatePageSlow", "notifier-delivery"))
for name, doc in cases.items():
    yaml.safe_dump(doc, open("{}/{}.yaml".format(out, name), "w", encoding="utf-8"), sort_keys=False, width=250)
SLOPY

  slo_check() {
    # slo_check CASE: run the check on one case; output in $work/cout, status in $rc.
    contract "$slo/$1.yaml" slo-rules t "$obs/slo-sources"
  }
  slo_check good
  check "the SLO rules of the monitors chart pass: every window, the four alerts per SLO with their thresholds and guard" test "$rc" -eq 0
  slo_fails() {
    # slo_fails CASE MESSAGE LABEL: the case fails and the output names the problem.
    slo_check "$1"
    if [ "$rc" -eq 1 ] && grep -qF -- "$2" "$work/cout"; then ok "$3"; else bad "$3 (exit $rc)"; fi
  }
  slo_fails burn "SLOBurnRatePageFast must compare slo:sli_error:ratio_rate1h to 14.4 x the error budget" "a fast page alert with the wrong burn rate is named"
  slo_fails window "must compare slo:sli_error:ratio_rate30m to 6 x the error budget" "an alert whose short window is not the documented one is named"
  slo_fails noguard "needs the low-traffic guard" "an alert without the minimum-traffic guard is named"
  slo_fails lowguard "has a low-traffic guard of 1, below the minimum of 3" "a guard that lets one failed request alert is named"
  slo_fails bucket 'uses le="0.3", which is not a bucket boundary' "a latency threshold that is not a bucket is named"
  slo_fails budget "do not add up to 1" "an objective and error budget that do not add up to 1 are named"
  slo_fails norunbook "needs the annotation runbook_url" "an alert without a runbook link is named"
  slo_fails noanchor "runbook_url must end in docs/runbooks/alerts.md#<anchor>" "a runbook link without an anchor is named"
  slo_fails route "without leaving out the routes /healthz, /readyz, /metrics" "a gateway selector that counts the readiness route is named"
  slo_fails client 'must leave out client errors (status!~"4..")' "an availability SLI that counts client errors is named"
  slo_fails metric "uses the metric messages_handled_total, which is not confirmed" "a metric no service defines is named"
  slo_fails nowindow "gateway-availability has no recording rule slo:sli_error:ratio_rate2h" "a missing window is named"
  slo_fails noevents "gateway-latency has no recording rule slo:sli_events:increase1d" "a missing event count is named"
  slo_fails severity "SLOBurnRateTicketFast must have severity ticket" "a ticket alert that pages is named"
  slo_fails name "does not follow slo:<what>:<unit>[_<window>]" "a recording rule outside the naming convention is named"
  slo_fails range "slo:sli_error:ratio_rate1h for gateway-availability does not use a [1h] range" "a recording rule whose name and range disagree is named"
  slo_fails nofor "needs a 'for' duration" "an alert without a for duration is named"
  slo_fails noalert "notifier-delivery has no alert SLOBurnRatePageSlow" "a missing alert is named"
  slo_fails noservice "alert OutboxBacklog (no slo) needs the label service" "an alert without the service label is named"
fi

echo "chart-contract-check.py (dashboards)"

if [ -z "$contract_py" ]; then
  echo "  skip  no Python with PyYAML found (installing yamllint provides it)"
else
  dash="$work/dash"
  rm -rf "$dash"
  mkdir -p "$dash"
  # Each case is a directory of dashboard files plus CASE.yaml, the ConfigMaps Helm would render for it.
  "$contract_py" - "$obs/dashboards" "$dash" << 'DASHPY'
import copy
import json
import os
import sys

import yaml

src, out = sys.argv[1], sys.argv[2]
good = json.load(open(src + "/ok-board.json"))


def make(name, boards, label=True, configmaps=True, stale=False):
    d = os.path.join(out, name)
    os.makedirs(d)
    docs = []
    for fname, board in boards.items():
        text = board if isinstance(board, str) else json.dumps(board, indent=2)
        with open(os.path.join(d, fname), "w") as f:
            f.write(text)
        if isinstance(board, str) or not configmaps:
            continue
        shown = copy.deepcopy(board)
        if stale:
            shown["title"] = "An older title"
        docs.append(
            {
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "metadata": {
                    "name": "dashboard-" + fname[:-5],
                    "namespace": "observability",
                    "labels": {"grafana_dashboard": "1"} if label else {},
                },
                "data": {fname: json.dumps(shown)},
            }
        )
    with open(d + ".yaml", "w") as f:
        yaml.safe_dump_all(docs, f)


def changed(fn):
    board = copy.deepcopy(good)
    fn(board)
    return board


def other(uid, title):
    board = copy.deepcopy(good)
    board["uid"], board["title"] = uid, title
    return board


make("good", {"ok-board.json": good})
make("not-json", {"ok-board.json": "{not json"})
make("same-title", {"ok-board.json": good, "other.json": other("other", good["title"])})
make("wrong-uid", {"ok-board.json": changed(lambda b: b.update(uid="something-else"))})
make("fixed-uid", {"ok-board.json": changed(lambda b: b["panels"][1]["datasource"].update(uid="abc123"))})
make("string-ds", {"ok-board.json": changed(lambda b: b["panels"][1]["targets"][0].update(datasource="Prometheus"))})
make("no-variable", {"ok-board.json": changed(lambda b: b["templating"]["list"].pop(0))})
make("invented", {"ok-board.json": changed(lambda b: b["panels"][1]["targets"][0].update(expr="sum(rate(demo_invented_total[5m]))"))})
make("bad-variable", {"ok-board.json": changed(lambda b: b["templating"]["list"][1].update(query={"query": "metrics(.*)", "refId": "x"}))})
make("no-query", {"ok-board.json": changed(lambda b: b["panels"][1].update(targets=[]))})
make("no-label", {"ok-board.json": good}, label=False)
make("no-configmap", {"ok-board.json": good}, configmaps=False)
make("stale-configmap", {"ok-board.json": good}, stale=True)
logs = json.load(open(src + "/ok-logs.json"))


def logs_changed(fn):
    board = copy.deepcopy(logs)
    fn(board)
    return board


def logs_expr(board, expr):
    board["panels"][2]["targets"][0]["expr"] = expr


make("logs-good", {"ok-logs.json": logs})
make("logs-fixed-uid", {"ok-logs.json": logs_changed(lambda b: b["panels"][2]["datasource"].update(uid="loki"))})
make("logs-no-variable", {"ok-logs.json": logs_changed(lambda b: b["templating"]["list"].pop(0))})
make("logs-bad-label", {"ok-logs.json": logs_changed(lambda b: logs_expr(b, "sum(rate({namespace=~\"$namespace\", job=\"x\"} [$__auto]))"))})
make("logs-empty-selector", {"ok-logs.json": logs_changed(lambda b: logs_expr(b, "sum(rate({service_name=~\"$service\"} [$__auto]))"))})
make("logs-bad-filter-label", {"ok-logs.json": logs_changed(lambda b: logs_expr(b, "sum(rate({namespace=~\"$namespace\"} | status=\"500\" [$__auto]))"))})
make("logs-bad-group", {"ok-logs.json": logs_changed(lambda b: logs_expr(b, "sum by (host) (rate({namespace=~\"$namespace\"} [$__auto]))"))})
make("logs-unknown-variable", {"ok-logs.json": logs_changed(lambda b: logs_expr(b, "sum(rate({namespace=~\"$nope\"} [$__auto]))"))})
make("logs-search-in-quotes", {"ok-logs.json": logs_changed(lambda b: logs_expr(b, "sum(rate({namespace=~\"$namespace\"} |~ \"(?i)$search\" [$__auto]))"))})
make("logs-unclosed-backtick", {"ok-logs.json": logs_changed(lambda b: logs_expr(b, "sum(rate({namespace=~\"$namespace\"} |~ `(?i)$search [$__auto]))"))})
make("logs-unbalanced", {"ok-logs.json": logs_changed(lambda b: logs_expr(b, "sum(rate({namespace=~\"$namespace\"} [$__auto])"))})
make("logs-all-matches-empty", {"ok-logs.json": logs_changed(lambda b: b["templating"]["list"][1].update(allValue=".*"))})
make("logs-bad-variable-label", {"ok-logs.json": logs_changed(lambda b: b["templating"]["list"][2].update(query={"query": "label_values({namespace=~\"$namespace\"}, host)", "refId": "x"}))})
make("slo-recorded", {"ok-board.json": changed(lambda b: b["panels"][1]["targets"][0].update(expr="1 - slo:sli_error:ratio_rate1h{slo=\"gateway-availability\"} / slo:error_budget:ratio{slo=\"gateway-availability\"}"))})
make("slo-unknown", {"ok-board.json": changed(lambda b: b["panels"][1]["targets"][0].update(expr="slo:sli_error:ratio_rate9m{slo=\"gateway-availability\"}"))})
make("alerts-series", {"ok-board.json": changed(lambda b: b["panels"][1]["targets"][0].update(expr="count(ALERTS{alertstate=\"firing\"}) or vector(0)"))})
DASHPY

  # dash_check CASE: run the dashboard check on a case; output in $work/cout, status in $rc.
  dash_check() {
    rc=0
    "$contract_py" scripts/chart-contract-check.py dashboards t "$dash/$1" "$obs/dashboards/stack-values.yaml" "$obs/dashboards/sources.txt" < "$dash/$1.yaml" > "$work/cout" 2>&1 || rc=$?
  }

  # dash_check_rules CASE: the same, with the rendered recording rules of the monitors chart as one more source.
  dash_check_rules() {
    rc=0
    "$contract_py" scripts/chart-contract-check.py dashboards t "$dash/$1" "$obs/dashboards/stack-values.yaml" "$obs/dashboards/sources.txt" "$obs/slo-rules-ok.yaml" < "$dash/$1.yaml" > "$work/cout" 2>&1 || rc=$?
  }

  dash_check good
  check "a dashboard that follows the rules passes" test "$rc" -eq 0
  dash_check_rules slo-recorded
  check "a dashboard that uses recording rules the monitors chart renders passes" test "$rc" -eq 0
  dash_check slo-recorded
  check "the same dashboard fails when the rules are not a source" test "$rc" -eq 1
  check "and the recording rule is named" grep -q 'uses the metric slo:sli_error:ratio_rate1h, which is not confirmed' "$work/cout"
  dash_check_rules slo-unknown
  check "a dashboard that uses a recording rule nobody defines fails" test "$rc" -eq 1
  check "and the name is given" grep -q 'uses the metric slo:sli_error:ratio_rate9m, which is not confirmed' "$work/cout"
  dash_check_rules alerts-series
  check "the ALERTS series passes once it is in the confirmed list" test "$rc" -eq 0
  dash_check not-json
  check "a file that is not JSON fails" test "$rc" -eq 1
  check "and the file is named" grep -q 'ok-board.json is not valid JSON' "$work/cout"
  dash_check same-title
  check "two dashboards with the same title fail" grep -q "the title 'Example board' is also used by ok-board.json" "$work/cout"
  dash_check wrong-uid
  check "a uid that is not the file name fails" grep -q "the uid 'something-else' must equal the file name 'ok-board'" "$work/cout"
  dash_check fixed-uid
  check "a fixed data source uid fails" test "$rc" -eq 1
  check "and the message names the variable to use" grep -qF "uid: \${datasource}" "$work/cout"
  dash_check string-ds
  check "a data source given by name fails" grep -q "has the data source 'Prometheus'" "$work/cout"
  dash_check no-variable
  check "a dashboard without the data source variable fails" grep -q 'has no data source variable' "$work/cout"
  dash_check invented
  check "a metric that no source confirms fails" grep -q 'uses the metric demo_invented_total, which is not confirmed in any source' "$work/cout"
  dash_check bad-variable
  check "a variable that is not label_values fails" grep -q "the variable 'service' must be label_values" "$work/cout"
  dash_check no-query
  check "a panel without a query fails" grep -q "panel 'Requests per second' has no query" "$work/cout"
  dash_check no-label
  check "a ConfigMap without the sidecar label fails" grep -q 'does not carry the sidecar label grafana_dashboard: "1"' "$work/cout"
  dash_check no-configmap
  check "a dashboard file that no ConfigMap holds fails" grep -q 'ok-board.json is not in any rendered ConfigMap' "$work/cout"
  dash_check stale-configmap
  check "a ConfigMap whose content differs from the file fails" grep -q 'with different content than the file' "$work/cout"

  # Loki panels.
  dash_check logs-good
  check "a dashboard that queries only Loki, through the loki variable, with allowed labels, passes" test "$rc" -eq 0
  dash_check logs-fixed-uid
  check "a fixed Loki data source uid fails" grep -q "has the data source {'type': 'loki', 'uid': 'loki'}" "$work/cout"
  dash_check logs-no-variable
  check "a Loki dashboard without the loki variable fails" grep -q 'has no data source variable (name loki, type datasource, query loki)' "$work/cout"
  dash_check logs-bad-label
  check "a selector on a label that is not a log stream label fails" grep -q 'uses the label job, which is not a log stream label' "$work/cout"
  dash_check logs-empty-selector
  check "a selector whose only matcher can match the empty value fails" grep -q 'has no matcher that excludes the empty value' "$work/cout"
  dash_check logs-all-matches-empty
  check "the same when the variable's All value is .*" grep -q 'has no matcher that excludes the empty value' "$work/cout"
  dash_check logs-bad-filter-label
  check "a label filter on something that is neither a stream label nor the level fails" grep -q 'the label filter uses status' "$work/cout"
  dash_check logs-bad-group
  check "grouping by an unknown label fails" grep -q 'groups by host' "$work/cout"
  dash_check logs-unknown-variable
  check "a variable the dashboard does not define fails" grep -qF "uses \$nope, which is not a variable of the dashboard" "$work/cout"
  dash_check logs-unbalanced
  check "unbalanced brackets fail" grep -q 'unbalanced ()' "$work/cout"
  dash_check logs-search-in-quotes
  check "the search text inside a double-quoted string fails" grep -q 'search text is inside a double-quoted string' "$work/cout"
  dash_check logs-unclosed-backtick
  check "an unclosed backtick fails" grep -q 'unclosed backtick' "$work/cout"
  dash_check logs-bad-variable-label
  check "a variable that lists values of an unknown label fails" grep -q "lists values of host, which is not a log stream label" "$work/cout"
  # shellcheck disable=SC2016 # the backticks are LogQL, not command substitution
  check "the query listing fills in the variables, with All and with concrete values, and the intervals" test "$("$contract_py" scripts/chart-contract-check.py loki-queries "$dash/logs-good" | awk -F'\t' '$2 ~ /^Log volume/ {print $2 ": " $4}' | tr '\n' '|')" = 'Log volume by service (all): sum by (service_name) (rate({namespace=~".+", service_name=~".*"} |~ `(?i)` [1m]))|Log volume by service (concrete): sum by (service_name) (rate({namespace=~"shop", service_name=~"gateway|payments"} |~ `(?i)request` [1m]))|'

  # The real dashboards: valid, labelled like the sidecar expects, and built only from confirmed metrics.
  check "the metric extractor keeps metric names and drops functions, label names, variables and keywords" test "$("$contract_py" - << 'MPY'
import importlib.util
spec = importlib.util.spec_from_file_location("c", "scripts/chart-contract-check.py")
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
print(" ".join(c.metrics_in('histogram_quantile(0.95, sum by (le, route) (rate(http_request_duration_seconds_bucket{route=~"$route", status="5.."}[$__rate_interval]))) / on (a) group_left (b) up or vector(0)')))
MPY
)" = "http_request_duration_seconds_bucket up"
fi

echo "chart-contract-check.py (network policies)"

if [ -z "$contract_py" ]; then
  echo "  skip  no Python with PyYAML found (installing yamllint provides it)"
else
  np="$work/netpol-cases"
  rm -rf "$np"
  mkdir -p "$np"
  # The good case is a reduced render of the policy charts; each bad case changes one thing in it.
  "$contract_py" - "$obs/netpol-ok.yaml" "$np" << 'NPPY'
import copy
import sys

import yaml

src, out = sys.argv[1], sys.argv[2]
base = list(yaml.safe_load_all(open(src, encoding="utf-8")))
WAVE = "argocd.argoproj.io/sync-wave"


def policy(docs, name):
    return next(d for d in docs if d["kind"] == "NetworkPolicy" and d["metadata"]["name"] == name)


cases = {}


def case(name, change):
    docs = copy.deepcopy(base)
    change(docs)
    cases[name] = docs


case("good", lambda d: None)
case("nodeny", lambda d: d.remove(policy(d, "default-deny")))
case("egress-only", lambda d: policy(d, "default-deny")["spec"].update(policyTypes=["Ingress"]))
case("order", lambda d: policy(d, "default-deny")["metadata"]["annotations"].update({WAVE: "-2"}))
case("world", lambda d: policy(d, "allow-dns")["spec"]["egress"][0].update(to=[{"ipBlock": {"cidr": "0.0.0.0/0"}}]))
case("wide", lambda d: policy(d, "allow-dns")["spec"]["egress"][0].update(to=[{"ipBlock": {"cidr": "10.0.0.0/0"}}]))
case("noports", lambda d: policy(d, "allow-dns")["spec"]["egress"][0].pop("ports"))
case("nopeer", lambda d: policy(d, "allow-dns")["spec"]["egress"][0].pop("to"))
case("empty", lambda d: policy(d, "allow-dns")["spec"].update(egress=[{}]))
case("uncovered", lambda d: policy(d, "default-deny")["spec"].update(podSelector={"matchLabels": {"app": "other"}}))
case("badlabel", lambda d: policy(d, "web-allow-prometheus-scrape")["spec"]["ingress"][0]["from"][0]["podSelector"]["matchLabels"].update({"app.kubernetes.io/name": "promethues"}))
case("badpod", lambda d: policy(d, "web-allow-prometheus-scrape")["spec"]["podSelector"]["matchLabels"].update({"app": "web2"}))
def internet_policy(docs, **change):
    policy = copy.deepcopy(next(d for d in docs if d["kind"] == "NetworkPolicy" and d["metadata"]["name"] == "allow-dns"))
    policy["metadata"]["name"] = "web-allow-internet-https"
    policy["metadata"]["annotations"] = {WAVE: "-2", "platform.example/internet-egress": change.get("reason", "image signature checks")}
    policy["spec"]["egress"] = [{"to": [{"ipBlock": {"cidr": "0.0.0.0/0", "except": ["192.0.2.0/24"]}}], "ports": change.get("ports", [{"protocol": "TCP", "port": 443}])}]
    if change.get("ingress"):
        policy["spec"]["policyTypes"] = ["Ingress"]
        policy["spec"]["ingress"] = [{"from": [{"ipBlock": {"cidr": "0.0.0.0/0"}}], "ports": [{"protocol": "TCP", "port": 443}]}]
        del policy["spec"]["egress"]
    docs.append(policy)


case("internet-ok", lambda d: internet_policy(d))
case("internet-noreason", lambda d: internet_policy(d, reason=""))
case("internet-ports", lambda d: internet_policy(d, ports=[{"protocol": "TCP", "port": 443}, {"protocol": "TCP", "port": 80}]))
case("internet-ingress", lambda d: internet_policy(d, ingress=True))
case("badnamespace", lambda d: policy(d, "allow-dns")["spec"]["egress"][0]["to"][0]["namespaceSelector"]["matchLabels"].update({"kubernetes.io/metadata.name": "kube-systm"}))
for name, docs in cases.items():
    yaml.safe_dump_all(docs, open("{}/{}.yaml".format(out, name), "w", encoding="utf-8"), sort_keys=False)
NPPY

  np_fails() {
    # np_fails CASE CHECK MESSAGE LABEL: the case fails and the output names the problem.
    if [ "$2" = policy-labels ]; then
      contract "$np/$1.yaml" "$2" t kube-system observability demo
    else
      contract "$np/$1.yaml" "$2" t
    fi
    if [ "$rc" -eq 1 ] && grep -qF -- "$3" "$work/cout"; then ok "$4"; else bad "$4 (exit $rc)"; fi
  }
  contract "$np/good.yaml" network-policies t
  check "policies with a default deny, allows that come first and no open range pass" test "$rc" -eq 0
  contract "$np/good.yaml" policy-labels t kube-system observability demo
  check "and every label and namespace they use is carried by a pod, a Service or a real namespace" test "$rc" -eq 0
  np_fails nodeny network-policies "there is no default deny" "a missing default deny is named"
  np_fails egress-only network-policies "there is no default deny" "a deny for ingress only is not a default deny"
  np_fails order network-policies "must have a lower sync wave than NetworkPolicy/default-deny" "an allow applied with or after the deny is named"
  np_fails world network-policies "allows the whole range 0.0.0.0/0" "an allow to every address is refused"
  np_fails wide network-policies "allows the whole range 10.0.0.0/0" "an allow to a /0 range is refused"
  np_fails internet-noreason network-policies "allows the whole range 0.0.0.0/0" "an internet egress without its reason is refused"
  np_fails internet-ports network-policies "allows the whole range 0.0.0.0/0" "an internet egress on more than TCP 443 is refused"
  np_fails internet-ingress network-policies "allows the whole range 0.0.0.0/0" "an ingress from every address is refused even with the reason"
  contract "$np/internet-ok.yaml" network-policies t
  check "an egress policy with the reason that allows TCP 443 to every address passes" test "$rc" -eq 0
  np_fails noports network-policies "has an egress rule without ports" "a rule without ports is named"
  np_fails nopeer network-policies "has an egress rule without a to" "a rule without a peer is named"
  np_fails empty network-policies "has an empty egress rule, which allows everything" "an empty rule is named"
  np_fails uncovered network-policies "the pods of Deployment/web are not covered by a default deny" "a workload the deny does not select is named"
  np_fails badlabel policy-labels "names pods with labels {'app.kubernetes.io/name': 'promethues'} that no pod in the manifests has" "a peer label that matches no pod is named"
  np_fails badpod policy-labels "selects pods with labels {'app': 'web2'} that no pod in the manifests has" "a policy for pods that do not exist is named"
  np_fails badnamespace policy-labels "names the namespace kube-systm" "a misspelt namespace is named"
fi

echo "network-policy-flows.py (evaluator semantics)"

if [ -z "$contract_py" ]; then
  echo "  skip  no Python with PyYAML found (installing yamllint provides it)"
else
  # Small hand-made policies against the evaluator; each case prints "ok NAME" or "bad NAME".
  "$contract_py" - << 'NPUNITPY' > "$work/npunit.out" 2>&1 || true
import importlib.util

spec = importlib.util.spec_from_file_location("flows", "scripts/network-policy-flows.py")
flows = importlib.util.module_from_spec(spec)
spec.loader.exec_module(flows)
E = flows.Endpoint
results = []


def pod(ns, name, ip, **labels):
    return E(ns + "/" + name, ns, labels, ip, True, "")


def addr(name, ip):
    return E(name, None, {}, ip, False, "")


def model(policies, namespaces=None):
    m = flows.Model()
    m.namespaces = {"a": {flows.METADATA_NAME: "a"}, "b": {flows.METADATA_NAME: "b", "team": "x"}}
    m.namespaces.update(namespaces or {})
    for i, spec in enumerate(policies):
        namespace = spec.pop("ns", "a")
        m.policies.append({"kind": "NetworkPolicy", "metadata": {"name": spec.pop("name", "p%d" % i), "namespace": namespace}, "spec": spec})
    return m


def case(name, expected, m, src, dst, port=80, protocol="TCP"):
    allowed, _ = m.evaluate(src, dst, port, protocol)
    results.append(("ok" if allowed == expected else "bad") + " " + name)


web = pod("a", "web", "10.0.0.1", app="web")
db = pod("a", "db", "10.0.0.2", app="db")
other = pod("b", "other", "10.0.1.1", app="other", tier="front")
lb = addr("lb", "192.0.2.50")

case("with no policy everything is allowed", True, model([]), web, db)
m = model([{"podSelector": {"matchLabels": {"app": "db"}}, "policyTypes": ["Ingress"]}])
case("a policy with Ingress and no rule isolates the pod for ingress", False, m, web, db)
case("and leaves its egress open", True, m, db, web)
m = model([{"podSelector": {"matchLabels": {"app": "db"}}, "policyTypes": ["Egress"]}])
case("a policy with Egress isolates egress only", False, m, db, web)
case("and leaves ingress open", True, m, web, db)
m = model([{"podSelector": {}, "egress": []}])
case("a policy without policyTypes but with an egress section isolates both directions (egress)", False, m, web, db)
case("and (ingress)", False, m, other, db)
m = model([{"podSelector": {}, "ingress": [{"from": [{"podSelector": {"matchLabels": {"app": "web"}}}]}]}])
case("a policy without policyTypes and without an egress section leaves egress open", True, m, db, other)
case("an empty podSelector selects every pod of the namespace", True, m, web, db)
case("and a pod that matches no rule is blocked", False, m, other, db)
m = model([{"podSelector": {}, "policyTypes": ["Ingress"], "ingress": [{"from": [{"podSelector": {"matchLabels": {"app": "db"}}}]}]}, {"ns": "b", "podSelector": {}, "policyTypes": ["Ingress"]}])
case("traffic inside the namespace gets no special treatment", False, m, web, db)
case("a policy of another namespace does not select the pod", True, m, db, web) if False else None

# union of policies and the AND of the two sides
db_in = lambda *peers: {"podSelector": {"matchLabels": {"app": "db"}}, "policyTypes": ["Ingress"], "ingress": [{"from": list(peers)}]}
m = model([db_in({"podSelector": {"matchLabels": {"app": "web"}}}), db_in({"podSelector": {"matchLabels": {"app": "cache"}}})])
cache = pod("a", "cache", "10.0.0.3", app="cache")
case("the rules of two policies are added up (first)", True, m, web, db)
case("the rules of two policies are added up (second)", True, m, cache, db)
case("a pod named by neither is blocked", False, m, other, db)
m = model([db_in({"podSelector": {"matchLabels": {"app": "web"}}}), {"podSelector": {"matchLabels": {"app": "web"}}, "policyTypes": ["Egress"]}])
case("the source egress can block what the destination ingress allows", False, m, web, db)
m = model([{"podSelector": {"matchLabels": {"app": "web"}}, "policyTypes": ["Egress"], "egress": [{"to": [{"podSelector": {"matchLabels": {"app": "db"}}}]}]}, {"podSelector": {"matchLabels": {"app": "db"}}, "policyTypes": ["Ingress"]}])
case("the destination ingress can block what the source egress allows", False, m, web, db)
m = model([{"podSelector": {"matchLabels": {"app": "web"}}, "policyTypes": ["Egress"], "egress": [{"to": [{"podSelector": {"matchLabels": {"app": "db"}}}]}]}, db_in({"podSelector": {"matchLabels": {"app": "web"}}})])
case("both sides allowing is an allow", True, m, web, db)

# selectors
sel = lambda s: model([db_in({"podSelector": s})])
case("matchExpressions In selects a value in the list", True, sel({"matchExpressions": [{"key": "app", "operator": "In", "values": ["web", "x"]}]}), web, db)
case("matchExpressions In does not select another value", False, sel({"matchExpressions": [{"key": "app", "operator": "In", "values": ["x"]}]}), web, db)
case("matchExpressions NotIn selects a value outside the list", True, sel({"matchExpressions": [{"key": "app", "operator": "NotIn", "values": ["x"]}]}), web, db)
case("matchExpressions NotIn does not select a value in the list", False, sel({"matchExpressions": [{"key": "app", "operator": "NotIn", "values": ["web"]}]}), web, db)
case("matchExpressions Exists needs the key", True, sel({"matchExpressions": [{"key": "app", "operator": "Exists"}]}), web, db)
case("matchExpressions DoesNotExist refuses the key", False, sel({"matchExpressions": [{"key": "app", "operator": "DoesNotExist"}]}), web, db)
case("matchLabels and matchExpressions must both hold", False, sel({"matchLabels": {"app": "web"}, "matchExpressions": [{"key": "tier", "operator": "Exists"}]}), web, db)

# namespaces
case("a podSelector alone does not reach into another namespace", False, sel({"matchLabels": {"app": "other"}}), other, db)
nsel = lambda peer, **kw: model([db_in(peer)], **kw)
case("a namespaceSelector alone selects every pod of the namespace (by name label)", True, nsel({"namespaceSelector": {"matchLabels": {flows.METADATA_NAME: "b"}}}), other, db)
case("and not the pods of another namespace", False, nsel({"namespaceSelector": {"matchLabels": {flows.METADATA_NAME: "b"}}}), web, db)
case("a namespaceSelector uses the other labels of the namespace", True, nsel({"namespaceSelector": {"matchLabels": {"team": "x"}}}), other, db)
case("an empty namespaceSelector selects every namespace", True, nsel({"namespaceSelector": {}}), other, db)
both = {"namespaceSelector": {"matchLabels": {flows.METADATA_NAME: "b"}}, "podSelector": {"matchLabels": {"app": "other"}}}
case("a namespaceSelector and a podSelector in one peer must both match", True, nsel(both), other, db)
case("in one peer a pod of the right namespace with the wrong label is blocked", False, nsel(both), pod("b", "x", "10.0.1.2", app="x"), db)
case("in one peer a pod with the right label in the wrong namespace is blocked", False, nsel(both), pod("a", "y", "10.0.0.9", app="other"), db)
two = [{"namespaceSelector": {"matchLabels": {flows.METADATA_NAME: "b"}}}, {"podSelector": {"matchLabels": {"app": "other"}}}]
m2 = model([db_in(*two)])
case("as two peers they add up (any pod of b)", True, m2, pod("b", "x", "10.0.1.2", app="x"), db)
case("as two peers they add up (the labelled pod of a)", True, m2, pod("a", "y", "10.0.0.9", app="other"), db)

# addresses
ipb = lambda block: model([db_in({"ipBlock": block})])
case("an ipBlock matches an address in the range", True, ipb({"cidr": "192.0.2.0/24"}), lb, db)
case("an ipBlock does not match an address outside the range", False, ipb({"cidr": "198.51.100.0/24"}), lb, db)
case("an ipBlock keeps out an excepted address", False, ipb({"cidr": "192.0.2.0/24", "except": ["192.0.2.48/28"]}), lb, db)
case("an ipBlock keeps in an address next to the exception", True, ipb({"cidr": "192.0.2.0/24", "except": ["192.0.2.0/28"]}), lb, db)
case("an ipBlock also matches the address of a pod", True, ipb({"cidr": "10.0.1.0/24"}), other, db)
case("a podSelector never matches an address that is not a pod", False, sel({"matchLabels": {"app": "web"}}), lb, db)
eg = lambda block: model([{"podSelector": {"matchLabels": {"app": "web"}}, "policyTypes": ["Egress"], "egress": [{"to": [{"ipBlock": block}], "ports": [{"protocol": "TCP", "port": 443}]}]}])
case("an egress ipBlock lets the source reach an address outside the cluster", True, eg({"cidr": "192.0.2.0/24"}), web, lb, 443)
case("and only on the listed port", False, eg({"cidr": "192.0.2.0/24"}), web, lb, 80)
case("and not another address", False, eg({"cidr": "192.0.2.0/24"}), web, addr("net", "198.51.100.7"), 443)

# ports
pp = lambda ports: model([{"podSelector": {"matchLabels": {"app": "db"}}, "policyTypes": ["Ingress"], "ingress": [{"from": [{"podSelector": {}}], "ports": ports}]}])
case("a rule without ports allows every port", True, pp(None), web, db, 5432)
case("a rule with an empty ports list allows every port", True, pp([]), web, db, 5432)
case("a port allows that port", True, pp([{"protocol": "TCP", "port": 5432}]), web, db, 5432)
case("and not another port", False, pp([{"protocol": "TCP", "port": 5432}]), web, db, 5433)
case("the protocol is TCP when not given", True, pp([{"port": 5432}]), web, db, 5432, "TCP")
case("and a UDP flow is not allowed by it", False, pp([{"port": 5432}]), web, db, 5432, "UDP")
case("UDP is allowed when listed", True, pp([{"protocol": "UDP", "port": 53}]), web, db, 53, "UDP")
case("endPort includes both ends of the range (start)", True, pp([{"protocol": "TCP", "port": 35672, "endPort": 35682}]), web, db, 35672)
case("endPort includes both ends of the range (end)", True, pp([{"protocol": "TCP", "port": 35672, "endPort": 35682}]), web, db, 35682)
case("endPort excludes the port after the range", False, pp([{"protocol": "TCP", "port": 35672, "endPort": 35682}]), web, db, 35683)
case("a port entry without a number allows every port of the protocol", True, pp([{"protocol": "TCP"}]), web, db, 9999)

# from and to lists
fl = lambda rule: model([{"podSelector": {"matchLabels": {"app": "db"}}, "policyTypes": ["Ingress"], "ingress": [rule]}])
case("a rule without from allows every peer", True, fl({"ports": [{"port": 80}]}), other, db)
case("a rule with an empty from list allows every peer", True, fl({"from": [], "ports": [{"port": 80}]}), other, db)
case("an empty rule allows everything", True, fl({}), lb, db, 1234)
case("an empty rule list allows nothing", False, model([{"podSelector": {}, "policyTypes": ["Ingress"], "ingress": []}]), web, db)

# connections through a Service: the egress side sees the ClusterIP, the ingress side the pod
def case_via(name, expected, m, src, dst, via, port=80):
    m.cluster_ips[dst.key] = flows.ipaddress.ip_address("203.0.113.9")
    allowed, _ = m.evaluate(src, dst, port, "TCP", via)
    results.append(("ok" if allowed == expected else "bad") + " " + name)


def egress_to(peers, port=80):
    return {"podSelector": {"matchLabels": {"app": "web"}}, "policyTypes": ["Egress"], "egress": [{"to": peers, "ports": [{"protocol": "TCP", "port": port}]}]}


db_peer = {"podSelector": {"matchLabels": {"app": "db"}}}
svc_peer = {"ipBlock": {"cidr": "203.0.113.0/24"}}
case_via("an egress rule that names the pods does not let a connection through their Service", False, model([egress_to([db_peer])]), web, db, "service")
case_via("and lets a connection to the pod address through", True, model([egress_to([db_peer])]), web, db, "pod")
case_via("an egress rule for the Service range lets a connection through the Service", True, model([egress_to([svc_peer])]), web, db, "service")
case_via("and not a connection to the pod address, which is outside that range", False, model([egress_to([svc_peer])]), web, db, "pod")
case_via("the Service range on another port is no use", False, model([egress_to([svc_peer], 443)]), web, db, "service")
case_via("both peers cover both ways", True, model([egress_to([db_peer, svc_peer])]), web, db, "service")
case_via("both peers cover both ways (pod address)", True, model([egress_to([db_peer, svc_peer])]), web, db, "pod")
only_web = {"podSelector": {"matchLabels": {"app": "db"}}, "policyTypes": ["Ingress"], "ingress": [{"from": [{"podSelector": {"matchLabels": {"app": "web"}}}]}]}
case_via("through a Service the ingress of the destination is matched against the source pod (allowed)", True, model([egress_to([svc_peer]), only_web]), web, db, "service")
case_via("through a Service the ingress of the destination is matched against the source pod (refused)", False, model([egress_to([svc_peer]), only_web]), pod("a", "cache", "10.0.0.3", app="cache"), db, "service")
open_egress = model([only_web, {"podSelector": {"matchLabels": {"app": "cache"}}, "policyTypes": ["Egress"], "egress": [{"to": [svc_peer]}]}])
case_via("an open egress to the Service range does not open a destination that refuses the source", False, open_egress, pod("a", "cache", "10.0.0.3", app="cache"), db, "service")
case_via("an address that is not a pod is refused by the ingress of the destination", False, model([only_web]), lb, db, "service")
case_via("an ipBlock for the Service range also reaches a destination that is not a pod", True, model([egress_to([svc_peer])]), web, addr("api", "203.0.113.1"), "pod")

# unsupported input stops the check
try:
    pp([{"protocol": "TCP", "port": "http"}]).evaluate(web, db, 80, "TCP")
    results.append("bad a named port is refused")
except flows.ModelError:
    results.append("ok a named port is refused")
for line in results:
    print(line)
NPUNITPY
  while IFS= read -r line; do
    case "$line" in
      "ok "*) ok "${line#ok }" ;;
      "bad "*) bad "${line#bad }" ;;
      *) bad "evaluator unit cases: $line" ;;
    esac
  done < "$work/npunit.out"
fi

echo "network-policy-flows.py (the real policies, mutated)"

if [ -z "$contract_py" ] || ! command -v helm > /dev/null 2>&1; then
  echo "  skip  needs helm and a Python with PyYAML"
else
  # The local charts only (no downloaded dependencies): the services, and the two policy charts. The other pods are the
  # ones the matrix declares.
  npm="$work/npmut"
  rm -rf "$npm"
  mkdir -p "$npm"
  for svc in gateway orders payments notifier; do
    helm template "$svc" deploy/helm/service --namespace shop -f deploy/helm/values/images.yaml -f "deploy/helm/values/$svc.yaml" -f "deploy/helm/values/$svc-data.yaml" --set networkPolicy.serviceCidr=203.0.113.0/24 > "$npm/shop-$svc.yaml" 2> /dev/null || true
  done
  helm template data-network-policies platform/data/network-policies --namespace data -f platform/data/network-policies/ci/aws-params.yaml > "$npm/data.yaml" 2> /dev/null || true
  helm template observability-network-policies platform/observability/network-policies --namespace observability -f platform/observability/network-policies/ci/aws-params.yaml > "$npm/observability.yaml" 2> /dev/null || true
  helm template policy-network-policies platform/security/network-policies --namespace kyverno -f platform/security/network-policies/ci/aws-params.yaml > "$npm/kyverno.yaml" 2> /dev/null || true
  "$contract_py" - "$npm" << 'NPMUTPY' > "$npm/results.out" 2>&1 || true
import copy
import importlib.util
import sys

import yaml

d = sys.argv[1]
spec = importlib.util.spec_from_file_location("flows", "scripts/network-policy-flows.py")
flows = importlib.util.module_from_spec(spec)
spec.loader.exec_module(flows)
matrix = yaml.safe_load(open("scripts/tests/fixtures/network-policies/flows.yaml", encoding="utf-8"))
entries = [("shop", d + "/shop-" + s + ".yaml") for s in ("gateway", "orders", "payments", "notifier")]
entries += [("data", d + "/data.yaml"), ("observability", d + "/observability.yaml"), ("kyverno", d + "/kyverno.yaml")]
base = flows.load_manifests(entries)
results = []


def policy(docs, name, namespace=None):
    for doc in docs:
        if doc["kind"] == "NetworkPolicy" and doc["metadata"]["name"] == name and namespace in (None, doc["metadata"]["namespace"]):
            return doc
    raise KeyError(name)


def run(change):
    docs = copy.deepcopy(base)
    change(docs)
    return flows.run(matrix, docs, "data")[0]


def drop(name, namespace=None):
    return lambda docs: docs.remove(policy(docs, name, namespace))


def expect(label, change, *fragments):
    problems = run(change)
    text = "\n".join(problems)
    good = bool(problems) and all(f in text for f in fragments)
    results.append(("ok " if good else "bad ") + label + ("" if good else " (got: %s)" % (text.replace("\n", " | ")[:600] or "no problem")))


problems = run(lambda docs: None)
results.append(("ok " if not problems else "bad ") + "the rendered policies satisfy every flow of the matrix" + ("" if not problems else ": " + problems[0]))
expect("removing the allow from orders to payments breaks an allowed flow", drop("orders-allow-to-payments"), "flow orders -> payments:8082/TCP through the Service should be allowed but is blocked", "egress of shop/orders")
expect("removing the ingress allow of PostgreSQL breaks an allowed flow", drop("postgres-allow-from-services"), "flow orders -> postgres:5432/TCP through the Service should be allowed but is blocked", "ingress of data/platform-pg-1")
expect("removing the DNS allow of the namespace breaks every DNS flow", drop("allow-dns", "observability"), "should be allowed but is blocked", "egress of observability/")
expect("removing the Prometheus scrape allow of a service breaks the scrape", drop("gateway-allow-prometheus-scrape"), "flow prometheus -> gateway:8080/TCP should be allowed but is blocked", "ingress of shop/gateway")


def open_valkey(docs):
    del policy(docs, "valkey-allow-from-services")["spec"]["ingress"][0]["from"]


expect("an allow rule without from breaks a denied flow (the source has no egress policy; the AND of both sides holds the others)", open_valkey, "flow internet -> valkey:6379/TCP should be denied but is allowed", "ingress of data/platform-valkey allowed by valkey-allow-from-services")


def open_rabbitmq(docs):
    policy(docs, "rabbitmq-allow-from-services")["spec"]["ingress"].append({})


expect("an empty ingress rule breaks a denied flow", open_rabbitmq, "flow internet -> rabbitmq:5672/TCP should be denied but is allowed")
expect("removing the default deny of the data namespace lets a new pod through", drop("default-deny", "data"), "flow internet -> data-stray:8080/TCP should be denied but is allowed", "ingress of data/stray open: no policy isolates it")
expect("removing the default deny of the observability namespace lets a new pod through", drop("default-deny", "observability"), "flow vpc-client -> obs-stray:3000/TCP should be denied but is allowed", "ingress of observability/stray open: no policy isolates it")


def change_port(docs):
    policy(docs, "orders-allow-to-payments")["spec"]["egress"][0]["ports"][0]["port"] = 8083


expect("changing the port of an allow breaks the allowed flow", change_port, "flow orders -> payments:8082/TCP through the Service should be allowed but is blocked")


def wrong_namespace(docs):
    policy(docs, "orders-allow-prometheus-scrape")["spec"]["ingress"][0]["from"][0]["namespaceSelector"]["matchLabels"]["kubernetes.io/metadata.name"] = "monitoring"


expect("a namespace that does not exist breaks the allowed flow", wrong_namespace, "flow prometheus -> orders:8081/TCP should be allowed but is blocked")


def everyone_to_internet(docs):
    policy(docs, "allow-dns", "data")["spec"]["egress"].append({"to": [{"ipBlock": {"cidr": "0.0.0.0/0"}}]})


expect("a rule open to every address breaks the denied flows to the internet", everyone_to_internet, "flow postgres -> internet:443/TCP should be denied but is allowed")

def without_service_peer(name, namespace=None):
    def change(docs):
        for rule in policy(docs, name, namespace)["spec"]["egress"]:
            rule["to"] = [peer for peer in rule["to"] if "ipBlock" not in peer]
    return change


expect(
    "egress to a Service by pod selector only breaks the flow through the Service (shop)",
    without_service_peer("orders-allow-to-payments"),
    "flow orders -> payments:8082/TCP through the Service should be allowed but is blocked",
    "egress of shop/orders blocked",
)
expect(
    "egress to a Service by pod selector only breaks the flow through the Service (observability)",
    without_service_peer("grafana-allow-to-loki", "observability"),
    "flow grafana -> loki:3100/TCP through the Service should be allowed but is blocked",
)
expect("DNS by pod selector only breaks name resolution through the DNS Service", without_service_peer("allow-dns", "data"), "flow postgres -> coredns:53/UDP through the Service should be allowed but is blocked")
expect("DNS by pod selector only breaks name resolution in the shop", without_service_peer("orders-allow-dns"), "flow orders -> coredns:53/UDP through the Service should be allowed but is blocked")


def old_api_rule(docs):
    policy(docs, "allow-kube-api-postgres", "data")["spec"]["egress"][0]["to"][0]["ipBlock"]["cidr"] = matrix["vpcCidr"]


expect("the old API rule (443 to the VPC range) no longer reaches the API server", old_api_rule, "flow postgres -> api-server:443/TCP should be allowed but is blocked")


def old_api_rule_observability(docs):
    policy(docs, "allow-kube-api-grafana", "observability")["spec"]["egress"][0]["to"][0]["ipBlock"]["cidr"] = matrix["vpcCidr"]


expect("and the same in the observability namespace", old_api_rule_observability, "flow grafana -> api-server:443/TCP should be allowed but is blocked")


def open_valkey_ports(docs):
    del policy(docs, "valkey-allow-from-services")["spec"]["ingress"][0]["ports"]


expect(
    "an ingress rule without ports lets a flow through the Service range that the destination should refuse",
    open_valkey_ports,
    "flow orders -> valkey:5432/TCP through the Service should be denied but is allowed",
    "ingress of data/platform-valkey allowed by valkey-allow-from-services",
)


def whole_service_range(docs):
    policy(docs, "orders-allow-dns")["spec"]["egress"][0].pop("ports")


expect("an egress rule to the Service range on every port opens what the destinations must refuse", whole_service_range, "should be denied but is allowed")

def kyverno_without_ipblock_rule(docs):
    policy(docs, "allow-kube-api-admission", "kyverno")["spec"]["egress"][0]["to"][0]["ipBlock"]["cidr"] = matrix["vpcCidr"]


expect("the old API rule (443 to the VPC range) no longer reaches the API server from the kyverno namespace", kyverno_without_ipblock_rule, "flow kyverno-admission -> api-server:443/TCP should be allowed but is blocked")
expect("removing the webhook rule breaks the call of the API server", drop("admission-allow-webhook-from-api-server", "kyverno"), "flow api-server-eni -> kyverno-admission:9443/TCP should be allowed but is blocked", "ingress of kyverno/kyverno-admission-controller")
expect("removing the scrape rule of a controller breaks the metrics flow", drop("reports-allow-prometheus-scrape", "kyverno"), "flow prometheus -> kyverno-reports:8000/TCP should be allowed but is blocked")
expect("removing the egress to Kyverno from the observability policies breaks the scrape", drop("prometheus-allow-to-kyverno", "observability"), "flow prometheus -> kyverno-background:8000/TCP should be allowed but is blocked", "egress of observability/")
expect("removing the default deny of the kyverno namespace lets a new pod through", drop("default-deny", "kyverno"), "flow internet -> kyverno-stray:8000/TCP should be denied but is allowed", "ingress of kyverno/stray open: no policy isolates it")


def webhook_open_to_all(docs):
    policy(docs, "admission-allow-webhook-from-api-server", "kyverno")["spec"]["ingress"][0]["from"][0]["ipBlock"]["cidr"] = "0.0.0.0/0"


expect("a webhook port open to every address lets the internet in", webhook_open_to_all, "flow internet -> kyverno-admission:9443/TCP should be denied but is allowed")


def internet_without_except(docs):
    policy(docs, "admission-allow-internet-https", "kyverno")["spec"]["egress"][0]["to"][0]["ipBlock"].pop("except")


expect("an internet rule that does not leave out the VPC range reaches the API server addresses", internet_without_except, "flow kyverno-admission -> api-server-eni:443/TCP should be denied but is allowed")


def internet_for_background(docs):
    policy(docs, "admission-allow-internet-https", "kyverno")["spec"]["podSelector"]["matchLabels"]["app.kubernetes.io/component"] = "background-controller"


expect("an internet rule given to another controller is found", internet_for_background, "flow kyverno-background -> internet:443/TCP should be denied but is allowed")


def internet_on_all_ports(docs):
    policy(docs, "admission-allow-internet-https", "kyverno")["spec"]["egress"][0].pop("ports")


expect("an internet rule without ports opens more than 443", internet_on_all_ports, "flow kyverno-admission -> internet:80/TCP should be denied but is allowed")
for line in results:
    print(line)
NPMUTPY
  while IFS= read -r line; do
    case "$line" in
      "ok "*) ok "${line#ok }" ;;
      "bad "*) bad "${line#bad }" ;;
      *) bad "mutation cases: $line" ;;
    esac
  done < "$npm/results.out"

  # The charts render the Service range into every egress rule, and refuse to render without it.
  svc_render() {
    helm template orders deploy/helm/service --namespace shop -f deploy/helm/values/images.yaml -f deploy/helm/values/orders.yaml \
      -f deploy/helm/values/orders-data.yaml "$@"
  }
  if svc_render > "$npm/nocidr.out" 2>&1; then bad "the service chart rendered without the Service range"; else ok "the service chart refuses to render without the Service range"; fi
  check "and says which value is missing" grep -q 'networkPolicy.serviceCidr must be set' "$npm/nocidr.out"
  svc_render --set networkPolicy.serviceCidr=203.0.113.0/24 > "$npm/withcidr.out" 2> /dev/null || true
  check "with the Service range every egress rule of orders has it (DNS, Collector, payments, PostgreSQL, Valkey, RabbitMQ)" test "$(grep -c 'cidr: 203.0.113.0/24' "$npm/withcidr.out")" = 6
  svc_render --set networkPolicy.matchServiceAddresses=false > "$npm/nomatch.out" 2> /dev/null || true
  check "and without matching Service addresses the chart needs no range and renders none" test "$(grep -c 'kind: NetworkPolicy' "$npm/nomatch.out")" -gt 0 -a "$(grep -c 'ipBlock' "$npm/nomatch.out")" = 0
  if helm template check platform/data/network-policies > "$npm/data-nocidr.out" 2>&1; then bad "the data policies rendered without the Service range"; else ok "the data policy chart refuses to render without the Service range"; fi
  check "and says which value is missing (data)" grep -q 'serviceCidr must be set' "$npm/data-nocidr.out"
  if helm template check platform/observability/network-policies --set vpcCidr=192.0.2.0/24 > "$npm/obs-nocidr.out" 2>&1; then bad "the observability policies rendered without the Service range"; else ok "the observability policy chart refuses to render without the Service range"; fi
  check "and says which value is missing (observability)" grep -q 'serviceCidr must be set' "$npm/obs-nocidr.out"
  if helm template check platform/observability/network-policies --set serviceCidr=203.0.113.0/24 > "$npm/obs-novpc.out" 2>&1; then bad "the observability policies rendered without the VPC range"; else ok "and without the VPC range, which Prometheus needs for the kubelets and the API server addresses"; fi
  check "the data policies keep the API rule on the Service range, not the VPC range" grep -q 'cidr: 203.0.113.0/24' "$npm/data.yaml"
  if helm template check platform/security/network-policies --set vpcCidr=192.0.2.0/24 > "$npm/kv-nocidr.out" 2>&1; then bad "the Kyverno policies rendered without the Service range"; else ok "the Kyverno policy chart refuses to render without the Service range"; fi
  check "and says which value is missing (Service range)" grep -q 'serviceCidr must be set' "$npm/kv-nocidr.out"
  if helm template check platform/security/network-policies --set serviceCidr=203.0.113.0/24 > "$npm/kv-novpc.out" 2>&1; then bad "the Kyverno policies rendered without the VPC range"; else ok "and without the VPC range, which the webhook rule needs (the API server calls it from the VPC)"; fi
  check "and says which value is missing (VPC range)" grep -q 'vpcCidr must be set' "$npm/kv-novpc.out"
  check "the Kyverno API rule is on the Service range and the webhook rule on the VPC range" test "$(grep -c 'cidr: 203.0.113.0/24' "$npm/kyverno.yaml")" -ge 5 -a "$(grep -c 'cidr: 192.0.2.0/24' "$npm/kyverno.yaml")" = 2
  check "the one internet rule is for the admission controller, says why and leaves out both ranges" test "$(grep -c 'platform.example/internet-egress' "$npm/kyverno.yaml")" = 1 -a "$(grep -c 'cidr: 0.0.0.0/0' "$npm/kyverno.yaml")" = 1
  check "with the policies switched off nothing is rendered" test "$(helm template check platform/security/network-policies --set enabled=false 2> /dev/null | grep -c '^kind:')" = 0
fi

echo "Kyverno (the policy engine)"

# The Applications: label, waves, project, ServerSideApply.
kv_apps="platform/argocd/apps"
check "both policy ApplicationSets select the label the flag sets" test "$(grep -l 'platform.example/policy: "true"' "$kv_apps"/84-policy-kyverno.yaml "$kv_apps"/85-policy-network-policies.yaml | wc -l | tr -d ' ')" = 2
check "Kyverno is wave 18, after the observability stack and before the services" grep -q 'argocd.argoproj.io/sync-wave: "18"' "$kv_apps/84-policy-kyverno.yaml"
check "its network policies are wave 19, after Kyverno" grep -q 'argocd.argoproj.io/sync-wave: "19"' "$kv_apps/85-policy-network-policies.yaml"
check "Kyverno syncs with ServerSideApply, because its CRDs are larger than client-side apply can store" grep -q 'ServerSideApply=true' "$kv_apps/84-policy-kyverno.yaml"
check "Kyverno is deployed from platform/security/kyverno to the kyverno namespace by platform-addons" test "$(grep -c -e 'path: platform/security/kyverno$' -e 'namespace: kyverno$' -e 'project: platform-addons$' "$kv_apps/84-policy-kyverno.yaml")" = 3
check "the namespace is created at the restricted Pod Security level" grep -q 'pod-security.kubernetes.io/enforce: restricted' "$kv_apps/84-policy-kyverno.yaml"
check "the network policies are only for EKS clusters" grep -q 'platform.example/cloud: aws' "$kv_apps/85-policy-network-policies.yaml"
check "they get the VPC range and the Service range from the cluster Secret annotations" test "$(grep -c -e "value: '.*platform.example/vpc-cidr" -e "value: '.*platform.example/service-cidr" "$kv_apps/85-policy-network-policies.yaml")" = 2
check "the four service ApplicationSets get the Service range too" test "$(grep -l 'platform.example/service-cidr' "$kv_apps"/8[0-3]-apps-*.yaml | wc -l | tr -d ' ')" = 4
check "the AppProject has the kyverno namespace as a destination" grep -q 'namespace: kyverno$' platform/argocd/bootstrap/appproject-platform-addons.yaml

if [ -z "$contract_py" ]; then
  echo "  skip  no Python with PyYAML found (installing yamllint provides it)"
else
  kv="$work/kyverno-cases"
  rm -rf "$kv"
  mkdir -p "$kv"
  # The good case is a reduced render of the chart; each bad case changes one thing in it or in the ApplicationSet.
  "$contract_py" - "$fixtures/policy/kyverno-ok.yaml" platform/argocd/apps/84-policy-kyverno.yaml "$kv" << 'KVPY'
import copy
import json
import sys

import yaml

src, appset_src, out = sys.argv[1], sys.argv[2], sys.argv[3]
base = list(yaml.safe_load_all(open(src, encoding="utf-8")))
appset_text = open(appset_src, encoding="utf-8").read()
yaml.SafeLoader.add_constructor("tag:yaml.org,2002:value", lambda loader, node: loader.construct_scalar(node))


def deployment(docs, name):
    return next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == name)


def config(docs):
    return next(d for d in docs if d["kind"] == "ConfigMap")


def big_crd(docs):
    crd = next(d for d in docs if d["kind"] == "CustomResourceDefinition")
    crd["spec"]["description"] = "x" * 300000


cases = {}


def case(name, change, appset=None):
    docs = copy.deepcopy(base)
    change(docs)
    cases[name] = docs
    open("{}/{}.appset.yaml".format(out, name), "w", encoding="utf-8").write(appset if appset is not None else appset_text)


def webhooks(docs, change):
    data = json.loads(config(docs)["data"]["webhooks"])
    change(data)
    config(docs)["data"]["webhooks"] = json.dumps(data)


case("good", lambda d: big_crd(d))
case("nolimits", lambda d: deployment(d, "kyverno-background-controller")["spec"]["template"]["spec"]["containers"][0]["resources"].pop("limits"))
case("noinit", lambda d: deployment(d, "kyverno-admission-controller")["spec"]["template"]["spec"]["initContainers"][0]["resources"].pop("requests"))
case("cpu", lambda d: deployment(d, "kyverno-admission-controller")["spec"]["template"]["spec"]["containers"][0]["resources"]["requests"].update(cpu="500m"))
case("replicas", lambda d: deployment(d, "kyverno-admission-controller")["spec"].update(replicas=6))
case("memory", lambda d: deployment(d, "kyverno-reports-controller")["spec"]["template"]["spec"]["containers"][0]["resources"]["requests"].update(memory="900Mi"))
case("noignore", lambda d: deployment(d, "kyverno-admission-controller")["spec"]["template"]["spec"]["containers"][0].update(args=[]))
case("argocd", lambda d: webhooks(d, lambda w: w["namespaceSelector"]["matchExpressions"][0]["values"].remove("argocd")))
case("kyvernons", lambda d: webhooks(d, lambda w: w["namespaceSelector"]["matchExpressions"].pop()))
case("noconfig", lambda d: d.remove(config(d)))
case("metrics", lambda d: deployment(d, "kyverno-cleanup-controller")["spec"]["template"]["spec"]["containers"][0].update(ports=[]))
case("missing", lambda d: d.remove(deployment(d, "kyverno-reports-controller")))
case("webhook", lambda d: d.append({"apiVersion": "admissionregistration.k8s.io/v1", "kind": "ValidatingWebhookConfiguration", "metadata": {"name": "kyverno-x"}}))
case("predelete", lambda d: d.append({"apiVersion": "batch/v1", "kind": "Job", "metadata": {"name": "kyverno-rm-webhooks", "annotations": {"helm.sh/hook": "pre-delete"}}}))
case("nocrd", lambda d: d.remove(next(x for x in d if x["kind"] == "CustomResourceDefinition")))
case("noserverside", lambda d: big_crd(d), appset_text.replace("          - ServerSideApply=true\n", ""))
case("smallcrd", lambda d: None, appset_text.replace("          - ServerSideApply=true\n", ""))
case("baseline", lambda d: big_crd(d), appset_text.replace("pod-security.kubernetes.io/enforce: restricted", "pod-security.kubernetes.io/enforce: baseline"))
case("label", lambda d: big_crd(d), appset_text.replace('platform.example/policy: "true"', 'platform.example/policy: "yes"'))
case("namespace", lambda d: big_crd(d), appset_text.replace("        namespace: kyverno\n", "        namespace: default\n"))
for name, docs in cases.items():
    yaml.safe_dump_all(docs, open("{}/{}.yaml".format(out, name), "w", encoding="utf-8"), sort_keys=False)
KVPY

  kv_fails() {
    # kv_fails CASE MESSAGE LABEL: the case fails and the output names the problem.
    contract "$kv/$1.yaml" kyverno t "$kv/$1.appset.yaml"
    if [ "$rc" -eq 1 ] && grep -qF -- "$2" "$work/cout"; then ok "$3"; else bad "$3 (exit $rc)"; fi
  }
  contract "$kv/good.yaml" kyverno t "$kv/good.appset.yaml"
  check "controllers with requests and limits under 600m and 1Gi, failing open, excluding the system namespaces, with a ServerSideApply Application, pass" test "$rc" -eq 0
  kv_fails nolimits "kyverno-background-controller container controller has no limits cpu" "a controller without limits is named"
  kv_fails noinit "kyverno-admission-controller container kyverno-pre has no requests cpu" "an init container without requests is named"
  kv_fails cpu "the controllers request 625m CPU, which is not under 600m" "requests of 600m CPU or more are refused"
  kv_fails replicas "the controllers request 725m CPU, which is not under 600m" "replicas count in the total"
  kv_fails memory "which is not under 1Gi" "requests of 1Gi of memory or more are refused"
  kv_fails noignore "does not force the webhook failure policy to Ignore (a dead Kyverno could block the cluster)" "webhooks that can fail closed are refused"
  kv_fails argocd "the webhooks do not exclude the namespaces argocd" "a webhook that covers argocd is named"
  kv_fails kyvernons "the webhooks do not exclude the namespaces kyverno" "a webhook that covers Kyverno's own namespace is named"
  kv_fails noconfig "no ConfigMap kyverno with the webhook settings" "missing webhook settings are named"
  kv_fails metrics "kyverno-cleanup-controller does not serve metrics on port 8000" "a controller without the metrics port is named"
  kv_fails missing "the Deployment kyverno-reports-controller is not rendered" "a missing controller is named"
  kv_fails webhook "is rendered; Kyverno creates its own webhook configurations" "a rendered webhook configuration is refused"
  kv_fails predelete "is a Helm pre-delete hook, which Argo CD does not run" "a pre-delete hook is refused"
  kv_fails nocrd "no CRD is rendered; render with --include-crds" "a render without CRDs is named"
  kv_fails noserverside "clusterpolicies.kyverno.io is larger than client-side apply can store (256 KiB), so the ApplicationSet needs ServerSideApply=true" "a large CRD without ServerSideApply is named"
  contract "$kv/smallcrd.yaml" kyverno t "$kv/smallcrd.appset.yaml"
  check "a CRD that client-side apply can store does not require ServerSideApply" test "$rc" -eq 0
  kv_fails baseline "the kyverno namespace is not created at the restricted Pod Security level" "a namespace below the restricted level is named"
  kv_fails label "does not select clusters by platform.example/policy=true" "the wrong cluster label is named"
  kv_fails namespace "does not deploy to the kyverno namespace" "the wrong namespace is named"

  # The AppProject: what Kyverno renders is allowed, and the whitelist is no wider than that.
  addons_project="platform/argocd/bootstrap/appproject-platform-addons.yaml"
  contract "$fixtures/policy/kyverno-project-ok.yaml" project-fit kyverno "$addons_project" kyverno
  check "everything the Kyverno chart renders is allowed by the platform-addons project (a Helm test hook needs no place)" test "$rc" -eq 0
  contract "$fixtures/policy/kyverno-project-bad.yaml" project-fit kyverno "$addons_project" kyverno
  check "a workload in another namespace and cluster-scoped kinds outside the list are refused" test "$rc" -eq 1
  check "the namespace is named" grep -q 'is in the namespace shop, which is not a destination of platform-addons' "$work/cout"
  check "a storage class is named" grep -q 'StorageClass/demo (storage.k8s.io) is cluster-scoped and not in clusterResourceWhitelist of platform-addons' "$work/cout"
  check "a persistent volume is named" grep -q 'PersistentVolume/demo (core) is cluster-scoped and not in clusterResourceWhitelist of platform-addons' "$work/cout"
fi


echo "Kyverno admission policies"

check "the policy ApplicationSet selects the label the flag sets" grep -q 'platform.example/policy: "true"' "$kv_apps/86-policy-policies.yaml"
check "it is wave 20, after Kyverno and its network policies, with the services" grep -q 'argocd.argoproj.io/sync-wave: "20"' "$kv_apps/86-policy-policies.yaml"
check "it deploys platform/security/policies by platform-addons, with the default values only" test "$(grep -c -e 'path: platform/security/policies$' -e 'project: platform-addons$' -e '            - values.yaml$' "$kv_apps/86-policy-policies.yaml")" = 3
check "values-enforce.yaml is not among the value files" test "$(grep -c 'values-enforce' "$kv_apps/86-policy-policies.yaml")" -le 1 -a "$(grep -c -e '- values-enforce' "$kv_apps/86-policy-policies.yaml")" = 0
check "every policy tolerates missing CRDs at sync time" test "$(grep -l 'SkipDryRunOnMissingResource=true' platform/security/policies/templates/*.yaml | wc -l | tr -d ' ')" = 6
check "the AppProject allows the two policy kinds it uses and no other" test "$(grep -c -e 'kind: ValidatingPolicy$' -e 'kind: ImageValidatingPolicy$' platform/argocd/bootstrap/appproject-platform-addons.yaml)" = 2 -a "$(grep -c 'kind: ClusterPolicy$' platform/argocd/bootstrap/appproject-platform-addons.yaml)" = 0
check "the credential copy Job carries the exempt label on the Job and on its pod" test "$(grep -c 'platform.example/policy-exempt: "true"' platform/data/rabbitmq-credentials/templates/copy.yaml)" = 2
check "the chart README says which policy types are used and why" grep -q 'ClusterPolicy' platform/security/policies/README.md
check "and that the Pod Security levels already enforce what the policies leave out" grep -q 'Pod Security' platform/security/policies/README.md

if [ -n "$contract_py" ]; then
  addons_project="platform/argocd/bootstrap/appproject-platform-addons.yaml"
  contract "$fixtures/policy/kyverno-project-ok.yaml" project-fit kyverno "$addons_project" kyverno
  check "a ValidatingPolicy and an ImageValidatingPolicy are allowed by the platform-addons project" test "$rc" -eq 0
  contract "$fixtures/policy/kyverno-project-bad.yaml" project-fit kyverno "$addons_project" kyverno
  check "the deprecated ClusterPolicy is refused" grep -q 'ClusterPolicy/demo (kyverno.io) is cluster-scoped and not in clusterResourceWhitelist of platform-addons' "$work/cout"
  check "and so is a MutatingPolicy, which no policy here uses" grep -q 'MutatingPolicy/demo (policies.kyverno.io) is cluster-scoped and not in clusterResourceWhitelist of platform-addons' "$work/cout"
fi

if [ -z "$contract_py" ] || ! command -v helm > /dev/null 2>&1; then
  echo "  skip  needs helm and a Python with PyYAML"
else
  ap="$work/policy-cases"
  rm -rf "$ap"
  mkdir -p "$ap"
  helm template policies platform/security/policies --namespace kyverno -f platform/security/policies/values.yaml > "$ap/audit.yaml" 2> /dev/null || true
  helm template policies platform/security/policies --namespace kyverno -f platform/security/policies/values.yaml -f platform/security/policies/values-enforce.yaml > "$ap/enforce.yaml" 2> /dev/null || true
  # A copy of the verify script with another issuer, and of the images file with another registry.
  sed 's#^ISSUER="https://token.actions.githubusercontent.com"#ISSUER="https://accounts.example.test"#' scripts/verify-image.sh > "$ap/verify-other-issuer.sh"
  sed 's#registry: ghcr.io/franklindot04#registry: ghcr.io/other#' deploy/helm/values/images.yaml > "$ap/images-other.yaml"
  "$contract_py" - "$ap" << 'APPY'
import copy
import sys

import yaml

d = sys.argv[1]
audit = list(yaml.safe_load_all(open(d + "/audit.yaml", encoding="utf-8")))
enforce = list(yaml.safe_load_all(open(d + "/enforce.yaml", encoding="utf-8")))
cases = {}


def policy(docs, name):
    return next(x for x in docs if x and x["metadata"]["name"] == name)


def case(name, change, base=audit):
    docs = [copy.deepcopy(x) for x in base if x]
    change(docs)
    cases[name] = docs


def spec(docs, name):
    return policy(docs, name)["spec"]


def keyless(docs):
    return spec(docs, "verify-image-signatures")["attestors"][0]["cosign"]


case("good-audit", lambda x: None)
case("good-enforce", lambda x: None, enforce)
case("deny-in-audit", lambda x: spec(x, "require-resources").update(validationActions=["Deny"]))
case("audit-in-enforce", lambda x: spec(x, "require-probes").update(validationActions=["Audit"]), enforce)
case("signature-deny", lambda x: spec(x, "verify-image-signatures").update(validationActions=["Deny"]), enforce)
case("clusterpolicy", lambda x: x.append({"apiVersion": "kyverno.io/v1", "kind": "ClusterPolicy", "metadata": {"name": "old"}, "spec": {}}))
case("everywhere", lambda x: spec(x, "require-resources")["matchConstraints"].pop("namespaceSelector"))
case("system", lambda x: spec(x, "require-resources")["matchConstraints"]["namespaceSelector"]["matchExpressions"][0]["values"].append("kube-system"))
case("objectselector", lambda x: spec(x, "require-resources")["matchConstraints"].update(objectSelector={"matchLabels": {"a": "b"}}))
case("noexempt", lambda x: spec(x, "require-resources").update(matchConditions=[]))
case("fail", lambda x: spec(x, "require-resources").update(failurePolicy="Fail"))
case("subresource", lambda x: spec(x, "restrict-image-registries")["matchConstraints"]["resourceRules"][0].update(resources=["pods", "pods/ephemeralcontainers"]))
case("ephemeral", lambda x: spec(x, "require-image-digest")["validations"].append({"expression": "object.spec.ephemeralContainers.all(c, c.image.matches('@sha256:'))", "message": "x"}))
case("nocronjobs", lambda x: spec(x, "require-resources")["autogen"]["podControllers"].update(controllers=["deployments", "jobs"]))
case("probes-jobs", lambda x: spec(x, "require-probes")["matchConstraints"]["resourceRules"][0].update(resources=["deployments", "jobs"]))
case("registry", lambda x: spec(x, "restrict-image-registries")["validations"][0].update(expression="variables.containers.all(c, c.image.startsWith('docker.io/'))"))
case("missing", lambda x: x.remove(policy(x, "require-probes")))
case("wrong-issuer", lambda x: keyless(x)["keyless"]["identities"][0].update(issuer="https://accounts.example.test"))
case("wrong-subject", lambda x: keyless(x)["keyless"]["identities"][0].update(subject="https://github.com/Franklindot04/Multi-Cloud-SRE-Platform/.github/workflows/images.yml@refs/heads/dev"))
case("two-identities", lambda x: keyless(x)["keyless"]["identities"].append({"issuer": "https://accounts.example.test", "subject": "someone"}))
case("no-tlog", lambda x: keyless(x)["ctlog"].update(insecureIgnoreTlog=True))
case("no-ctlog", lambda x: keyless(x).pop("ctlog"))
case("key", lambda x: keyless(x).update(key={"data": "x"}))
case("no-provenance", lambda x: spec(x, "verify-image-signatures").update(attestations=[a for a in spec(x, "verify-image-signatures")["attestations"] if a["name"] != "provenance"]))
case("no-sbom-validation", lambda x: spec(x, "verify-image-signatures").update(validations=[v for v in spec(x, "verify-image-signatures")["validations"] if "attestations.sbom" not in v["expression"]]))
case("loose-result", lambda x: spec(x, "verify-image-signatures")["validations"][0].update(expression="(images.containers + images.initContainers).map(image, verifyImageSignatures(image, [attestors.cosign])).all(e, e >= 0)"))
case("wrong-glob", lambda x: spec(x, "verify-image-signatures").update(matchImageReferences=[{"glob": "*"}]))
for name, docs in cases.items():
    yaml.safe_dump_all(docs, open("{}/{}.yaml".format(d, name), "w", encoding="utf-8"), sort_keys=False)
APPY

  pol() {
    # pol CASE MODE: run the policies contract on the case with the real images file and verify script.
    contract "$ap/$1.yaml" policies t "$2" deploy/helm/values/images.yaml scripts/verify-image.sh
  }
  pol_fails() {
    # pol_fails CASE MODE MESSAGE LABEL
    pol "$1" "$2"
    if [ "$rc" -eq 1 ] && grep -qF -- "$3" "$work/cout"; then ok "$4"; else bad "$4 (exit $rc)"; fi
  }
  pol good-audit audit
  check "the policies with the default values pass: every action Audit, shop only, failing open, matching pods, signature as verify-image.sh" test "$rc" -eq 0
  pol good-enforce enforce
  check "and with values-enforce.yaml: Deny everywhere but the signature policy" test "$rc" -eq 0
  pol_fails deny-in-audit audit "has the action ['Deny'] (expected ['Audit'] in audit mode)" "a policy that denies by default is named"
  pol_fails audit-in-enforce enforce "require-probes has the action ['Audit'] (expected ['Deny'] in enforce mode)" "a policy that is not enforced by values-enforce.yaml is named"
  pol_fails signature-deny enforce "verify-image-signatures has the action ['Deny'] (expected ['Audit'] in enforce mode)" "the signature policy that is enforced by values-enforce.yaml is named"
  pol_fails clusterpolicy audit "ClusterPolicy/old (kyverno.io/v1) is not a ValidatingPolicy or ImageValidatingPolicy of policies.kyverno.io/v1" "the deprecated ClusterPolicy is refused"
  pol_fails everywhere audit "require-resources must apply to the namespace shop only (it selects every namespace)" "a policy for every namespace is named"
  pol_fails system audit "selects the system or platform namespaces ['kube-system']" "a policy that selects a system namespace is named"
  pol_fails objectselector audit "has an objectSelector, which turns off the rules for pod controllers (autogen)" "an objectSelector is refused because it turns autogen off"
  pol_fails noexempt audit "does not skip the workloads that carry platform.example/policy-exempt" "a policy that ignores the exempt label is named"
  pol_fails fail audit "must fail open (failurePolicy Ignore)" "a policy that fails closed is named"
  pol_fails subresource audit "restrict-image-registries must match pods and no subresource, so the ephemeral debug container is not stopped" "a policy that matches pods/ephemeralcontainers is refused"
  pol_fails ephemeral audit "looks at ephemeral containers" "a policy that looks at ephemeral containers is refused"
  pol_fails nocronjobs audit "require-resources has no autogen for cronjobs" "missing autogen for CronJobs is named"
  pol_fails probes-jobs audit "require-probes must match deployments, statefulsets and daemonsets only (Jobs are exempt)" "a probe policy that matches Jobs is refused"
  pol_fails registry audit "restrict-image-registries does not use the registry ghcr.io/franklindot04 of deploy/helm/values/images.yaml" "a registry that is not the one of images.yaml is named"
  pol_fails missing audit "the policy require-probes is not rendered" "a missing policy is named"
  pol_fails wrong-issuer audit "must accept one identity: issuer https://token.actions.githubusercontent.com" "a different OIDC issuer is refused"
  pol_fails wrong-subject audit "must accept one identity" "a different workflow identity is refused"
  pol_fails two-identities audit "must accept one identity" "a second accepted identity is refused"
  pol_fails no-tlog audit "must require the transparency log entry" "a signature policy that ignores the transparency log is refused"
  pol_fails no-ctlog audit "must require the transparency log entry" "a signature policy without a log url is refused"
  pol_fails key audit "must have one cosign attestor with keyless verification and the transparency log, nothing else" "a key attestor next to the keyless one is refused"
  pol_fails no-provenance audit "must require the provenance attestation of type https://slsa.dev/provenance/v1" "a missing provenance attestation is named"
  pol_fails no-sbom-validation audit "has no validation that calls verifyAttestationSignatures(image, attestations.sbom" "a missing SBOM validation is named"
  pol_fails loose-result audit "must require a verified result (e > 0)" "a validation that accepts an unverified image is refused"
  pol_fails wrong-glob audit "must match the images of ghcr.io/franklindot04/*" "a glob that is not the registry is refused"
  contract "$ap/good-audit.yaml" policies t audit "$ap/images-other.yaml" scripts/verify-image.sh
  check "a registry in images.yaml that is not the one of the policies is named" grep -q 'does not use the registry ghcr.io/other of' "$work/cout"
  contract "$ap/good-audit.yaml" policies t audit deploy/helm/values/images.yaml "$ap/verify-other-issuer.sh"
  check "an issuer in verify-image.sh that is not the one of the policy is named" grep -q 'must accept one identity: issuer https://accounts.example.test' "$work/cout"
fi

echo "chart-contract-check.py (replicas, budgets, spread and autoscaler)"

if [ -z "$contract_py" ] || ! command -v helm > /dev/null 2>&1; then
  echo "  skip  needs helm and a Python with PyYAML"
else
  sc="$work/scaling"
  rm -rf "$sc"
  mkdir -p "$sc"
  # sc_render SERVICE PROFILE [HELM ARGS]: the real chart with the real values files.
  sc_render() {
    local svc="$1" profile="$2"
    shift 2
    helm template "$svc" deploy/helm/service --namespace shop -f deploy/helm/values/images.yaml -f "deploy/helm/values/$svc.yaml" \
      -f "deploy/helm/values/$svc-$profile.yaml" --set networkPolicy.serviceCidr=203.0.113.0/24 "$@"
  }
  for pair in gateway:memory gateway:data orders:memory orders:data payments:memory payments:data notifier:memory notifier:data; do
    sc_render "${pair%%:*}" "${pair##*:}" > "$sc/${pair%%:*}-${pair##*:}.yaml" 2> /dev/null || true
  done
  contract "$sc/orders-data.yaml" scaling t hpa
  check "orders in the data profile: an autoscaler, no replicas in the Deployment, a budget, the spread, the grace period" test "$rc" -eq 0
  contract "$sc/gateway-data.yaml" scaling t hpa
  check "and the gateway in the data profile" test "$rc" -eq 0
  contract "$sc/gateway-memory.yaml" scaling t replicas=2
  check "the gateway in the memory profile: two fixed replicas and a budget, no autoscaler" test "$rc" -eq 0
  contract "$sc/payments-data.yaml" scaling t replicas=2
  check "payments in the data profile: two fixed replicas and a budget" test "$rc" -eq 0
  for pair in orders:memory payments:memory notifier:memory notifier:data; do
    contract "$sc/${pair%%:*}-${pair##*:}.yaml" scaling t replicas=1
    check "${pair%%:*} in the $(printf '%s' "${pair##*:}") profile: one replica, no budget, no autoscaler" test "$rc" -eq 0
  done
  check "a service on one replica renders no PodDisruptionBudget" test "$(cat "$sc/notifier-data.yaml" "$sc/orders-memory.yaml" "$sc/payments-memory.yaml" | grep -c 'kind: PodDisruptionBudget')" = 0
  check "and the memory profile renders no autoscaler" test "$(cat "$sc"/*-memory.yaml | grep -c 'kind: HorizontalPodAutoscaler')" = 0
  check "with an autoscaler the Deployment has no replicas field" test "$(grep -c '^  replicas:' "$sc/orders-data.yaml" "$sc/gateway-data.yaml" | grep -vc ':0$')" = 0

  # What a service renders is compared with what it is allowed to do: the notifier keeps its state in memory.
  contract "$sc/notifier-data.yaml" scaling t hpa
  check "the notifier is not expected to scale (an autoscaler is expected and missing)" test "$rc" -eq 1
  if sc_render notifier data --set autoscaling.enabled=true > /dev/null 2>&1; then bad "the notifier rendered an autoscaler next to its fixed replicas"; else ok "an autoscaler switched on for the notifier does not render while its values file fixes the replicas"; fi
  sc_render notifier data --set autoscaling.enabled=true --set replicas=null > "$sc/notifier-hpa.yaml" 2> /dev/null || true
  contract "$sc/notifier-hpa.yaml" scaling t replicas=1
  check "and if both are changed, the check refuses an autoscaler for the notifier" test "$rc" -eq 1
  check "and named" grep -q 'an autoscaler on a service that is fixed at 1 replica(s)' "$work/cout"
  sc_render notifier data --set replicas=2 > "$sc/notifier-2.yaml" 2> /dev/null || true
  contract "$sc/notifier-2.yaml" scaling t replicas=1
  check "so is a second replica of the notifier" grep -q 'replicas is 2, expected 1' "$work/cout"
  sc_render orders memory --set replicas=2 > "$sc/orders-memory-2.yaml" 2> /dev/null || true
  contract "$sc/orders-memory-2.yaml" scaling t replicas=1
  check "and a second replica of orders in the memory profile, which would see only half of the orders" grep -q 'replicas is 2, expected 1' "$work/cout"
  contract "$sc/orders-memory-2.yaml" scaling t replicas=2
  check "a second replica comes with its budget, so only the expectation of the service stops it" test "$rc" -eq 0

  cat > "$sc/mutate.py" << 'SCPY'
import copy
import sys

import yaml

src, dst, how = sys.argv[1:4]
docs = [d for d in yaml.safe_load_all(open(src, encoding="utf-8")) if d]


def one(kind):
    return next(d for d in docs if d["kind"] == kind)


dep = one("Deployment")
pod = dep["spec"]["template"]["spec"]
if how == "replicas-with-hpa":
    dep["spec"]["replicas"] = 2
elif how == "no-hpa":
    docs = [d for d in docs if d["kind"] != "HorizontalPodAutoscaler"]
elif how == "cpu-80":
    one("HorizontalPodAutoscaler")["spec"]["metrics"][0]["resource"]["target"]["averageUtilization"] = 80
elif how == "memory-metric":
    one("HorizontalPodAutoscaler")["spec"]["metrics"][0]["resource"]["name"] = "memory"
elif how == "window-60":
    one("HorizontalPodAutoscaler")["spec"]["behavior"]["scaleDown"]["stabilizationWindowSeconds"] = 60
elif how == "min-1":
    one("HorizontalPodAutoscaler")["spec"]["minReplicas"] = 1
elif how == "max-equals-min":
    h = one("HorizontalPodAutoscaler")["spec"]
    h["maxReplicas"] = h["minReplicas"]
elif how == "other-target":
    one("HorizontalPodAutoscaler")["spec"]["scaleTargetRef"]["name"] = "other"
elif how == "no-pdb":
    docs = [d for d in docs if d["kind"] != "PodDisruptionBudget"]
elif how == "pdb-two":
    one("PodDisruptionBudget")["spec"]["maxUnavailable"] = 2
elif how == "pdb-min-available":
    s = one("PodDisruptionBudget")["spec"]
    del s["maxUnavailable"]
    s["minAvailable"] = 1
elif how == "pdb-selector":
    one("PodDisruptionBudget")["spec"]["selector"]["matchLabels"] = {"app.kubernetes.io/name": "other"}
elif how == "add-pdb":
    pdb = {"apiVersion": "policy/v1", "kind": "PodDisruptionBudget", "metadata": {"name": "x"},
           "spec": {"maxUnavailable": 1, "selector": {"matchLabels": dep["spec"]["selector"]["matchLabels"]}}}
    docs.append(pdb)
elif how == "no-zone":
    pod["topologySpreadConstraints"] = [c for c in pod["topologySpreadConstraints"] if c["topologyKey"] != "topology.kubernetes.io/zone"]
elif how == "no-node":
    pod["topologySpreadConstraints"] = [c for c in pod["topologySpreadConstraints"] if c["topologyKey"] != "kubernetes.io/hostname"]
elif how == "no-spread":
    del pod["topologySpreadConstraints"]
elif how == "spread-selector":
    pod["topologySpreadConstraints"][0]["labelSelector"]["matchLabels"] = {"app.kubernetes.io/name": "other"}
elif how == "spread-mode":
    pod["topologySpreadConstraints"][0]["whenUnsatisfiable"] = "Never"
elif how == "spread-mixed":
    pod["topologySpreadConstraints"][0]["whenUnsatisfiable"] = "DoNotSchedule"
    pod["topologySpreadConstraints"][1]["whenUnsatisfiable"] = "ScheduleAnyway"
elif how == "unavailable-1":
    dep["spec"]["strategy"]["rollingUpdate"]["maxUnavailable"] = 1
elif how == "recreate":
    dep["spec"]["strategy"] = {"type": "Recreate"}
elif how == "grace-20":
    pod["terminationGracePeriodSeconds"] = 20
elif how == "no-prestop":
    del pod["containers"][0]["lifecycle"]
else:
    sys.exit("unknown mutation " + how)
yaml.safe_dump_all(docs, open(dst, "w", encoding="utf-8"), sort_keys=False)
SCPY
  # sc_fails FILE EXPECT MUTATION MESSAGE DESCRIPTION
  sc_fails() {
    "$contract_py" "$sc/mutate.py" "$1" "$sc/mutated.yaml" "$3" || { bad "$5 (mutation $3 failed)"; return; }
    contract "$sc/mutated.yaml" scaling t "$2"
    if [ "$rc" -eq 1 ] && grep -qF -- "$4" "$work/cout"; then ok "$5"; else bad "$5 (exit $rc)"; fi
  }
  sc_fails "$sc/orders-data.yaml" hpa replicas-with-hpa "next to an autoscaler; they would fight over the count" "replicas in the Deployment next to an autoscaler is named"
  sc_fails "$sc/orders-data.yaml" hpa no-hpa "expected an autoscaler" "a missing autoscaler is named"
  sc_fails "$sc/orders-data.yaml" hpa cpu-80 "a target of 70 percent" "a CPU target other than 70 percent is refused"
  sc_fails "$sc/orders-data.yaml" hpa memory-metric "a target of 70 percent" "an autoscaler on memory is refused"
  sc_fails "$sc/orders-data.yaml" hpa window-60 "the scale-down stabilisation window is 60" "a short scale-down window is named"
  sc_fails "$sc/orders-data.yaml" hpa min-1 "the autoscaler minimum is 1" "an autoscaler that can go down to one pod is named"
  sc_fails "$sc/orders-data.yaml" hpa max-equals-min "the autoscaler maximum must be above its minimum" "an autoscaler that cannot scale is named"
  sc_fails "$sc/orders-data.yaml" hpa other-target "does not target the Deployment orders" "an autoscaler for another Deployment is named"
  sc_fails "$sc/orders-data.yaml" hpa no-pdb "2 replicas at the start and 0 PodDisruptionBudgets" "a service with two replicas and no budget is named"
  sc_fails "$sc/gateway-memory.yaml" replicas=2 no-pdb "2 replicas at the start and 0 PodDisruptionBudgets" "and for fixed replicas"
  sc_fails "$sc/orders-data.yaml" hpa pdb-two "the budget must be maxUnavailable: 1" "a budget that allows two pods down is refused"
  sc_fails "$sc/orders-data.yaml" hpa pdb-min-available "the budget must be maxUnavailable: 1" "a minAvailable budget is refused"
  sc_fails "$sc/orders-data.yaml" hpa pdb-selector "the budget does not select the pods of the Deployment" "a budget that selects other pods is named"
  sc_fails "$sc/notifier-data.yaml" replicas=1 add-pdb "a PodDisruptionBudget on a single replica would block every node drain" "a budget on a single replica is named"
  sc_fails "$sc/orders-data.yaml" hpa no-zone "no topology spread constraint over topology.kubernetes.io/zone" "a missing spread over zones is named"
  sc_fails "$sc/orders-data.yaml" hpa no-node "no topology spread constraint over kubernetes.io/hostname" "a missing spread over nodes is named"
  sc_fails "$sc/orders-data.yaml" hpa no-spread "no topology spread constraint over kubernetes.io/hostname" "no spread at all is named"
  sc_fails "$sc/orders-data.yaml" hpa spread-selector "does not select the pods of the Deployment" "a spread that selects other pods is named"
  sc_fails "$sc/orders-data.yaml" hpa spread-mode "has no valid whenUnsatisfiable" "a spread mode Kubernetes does not know is named"
  sc_fails "$sc/orders-data.yaml" hpa spread-mixed "disagree on whenUnsatisfiable" "a hard rule for nodes and a soft one for zones is named"
  sc_fails "$sc/orders-data.yaml" hpa unavailable-1 "maxUnavailable 0" "a rollout that lowers capacity is refused"
  sc_fails "$sc/orders-data.yaml" hpa recreate "maxUnavailable 0" "a Recreate rollout is refused"
  sc_fails "$sc/orders-data.yaml" hpa grace-20 "the grace period 20 is shorter than the preStop sleep, the drain and the shutdown time (30s)" "a grace period shorter than the drain is named"
  sc_fails "$sc/orders-data.yaml" hpa no-prestop "no preStop sleep" "a missing preStop sleep is named"

  # The chart itself refuses what would fight or mean nothing.
  if sc_render orders data --set replicas=2 > "$sc/refused.out" 2>&1; then bad "the chart rendered replicas next to the autoscaler"; else ok "the chart refuses replicas next to the autoscaler"; fi
  check "and says what to do" grep -q 'replicas must not be set when autoscaling.enabled is true' "$sc/refused.out"
  if sc_render orders data --set autoscaling.maxReplicas=1 > /dev/null 2>&1; then bad "the chart rendered a maximum below the minimum"; else ok "the chart refuses a maximum below the minimum"; fi
  if sc_render orders data --set topologySpread.whenUnsatisfiable=Sometimes > "$sc/refused.out" 2>&1; then bad "the chart rendered an unknown spread mode"; else ok "the chart refuses an unknown spread mode"; fi
  check "and says which values are allowed" grep -q 'ScheduleAnyway or DoNotSchedule' "$sc/refused.out"
  sc_render orders data --set topologySpread.whenUnsatisfiable=DoNotSchedule > "$sc/hard.yaml" 2> /dev/null || true
  check "a production profile can make the spread a hard rule, for nodes and for zones" test "$(grep -c 'whenUnsatisfiable: DoNotSchedule' "$sc/hard.yaml")" = 2
  contract "$sc/hard.yaml" scaling t hpa
  check "and the render still passes" test "$rc" -eq 0
  sc_render orders data --set podDisruptionBudget.enabled=false > "$sc/nopdb.yaml" 2> /dev/null || true
  check "the budget can be switched off" test "$(grep -c 'kind: PodDisruptionBudget' "$sc/nopdb.yaml")" = 0
  sc_render orders data --set autoscaling.enabled=false --set replicas=3 > "$sc/fixed3.yaml" 2> /dev/null || true
  check "without the autoscaler the Deployment sets the count and the budget stays" test "$(grep -c '^  replicas: 3' "$sc/fixed3.yaml")" = 1 -a "$(grep -c 'kind: PodDisruptionBudget' "$sc/fixed3.yaml")" = 1
  check "the platform-apps project allows the autoscaler" grep -q 'kind: HorizontalPodAutoscaler' platform/argocd/bootstrap/appproject-platform-apps.yaml
fi

echo "chart-contract-check.py (PostgreSQL instances, priority classes, scaling alerts)"

if [ -z "$contract_py" ] || ! command -v helm > /dev/null 2>&1; then
  echo "  skip  needs helm and a Python with PyYAML"
else
  pm="$work/pm"
  rm -rf "$pm"
  mkdir -p "$pm"
  pgc=platform/data/postgres
  helm template postgres "$pgc" --namespace data -f "$pgc/values.yaml" -f "$pgc/values-standard.yaml" > "$pm/pg2.yaml" 2> /dev/null || true
  helm template postgres "$pgc" --namespace data -f "$pgc/values.yaml" -f "$pgc/values-standard.yaml" --set cluster.instances=1 > "$pm/pg1.yaml" 2> /dev/null || true
  helm template postgres "$pgc" --namespace data -f "$pgc/values.yaml" -f "$pgc/values-standard.yaml" -f "$pgc/values-ha.yaml" > "$pm/pg3.yaml" 2> /dev/null || true
  helm template pc platform/addons/priority-classes > "$pm/classes.yaml" 2> /dev/null || true
  helm template m platform/observability/monitors --namespace observability > "$pm/monitors.yaml" 2> /dev/null || true

  contract "$pm/pg2.yaml" postgres-ha t 2
  check "the standard profile renders two instances, off one node, asynchronous, updated by switchover, with the operator's budgets" test "$rc" -eq 0
  contract "$pm/pg1.yaml" postgres-ha t 1
  check "cluster.instances=1 goes back to one instance with no budget" test "$rc" -eq 0
  contract "$pm/pg3.yaml" postgres-ha t 3
  check "the high availability profile renders three" test "$rc" -eq 0
  check "and requires the instances to be on different nodes" test "$(grep -c 'podAntiAffinityType: required' "$pm/pg3.yaml")" = 1
  check "the standard profile only prefers it, so two nodes lost do not leave a pod Pending" test "$(grep -c 'podAntiAffinityType: preferred' "$pm/pg2.yaml")" = 1
  check "the standard profile does not order the zones as a rule" grep -q 'whenUnsatisfiable: ScheduleAnyway' "$pm/pg2.yaml"
  check "the chart renders no PodDisruptionBudget of its own" test "$(cat "$pm"/pg*.yaml | grep -c 'kind: PodDisruptionBudget')" = 0
  contract "$pm/pg1.yaml" postgres-ha t 2
  check "a render with one instance is not accepted as two" grep -q 'instances is 1, expected 2' "$work/cout"

  cat > "$pm/mutate.py" << 'PMPY'
import sys

import yaml

src, dst, how = sys.argv[1:4]
docs = [d for d in yaml.safe_load_all(open(src, encoding="utf-8")) if d]


def one(kind):
    return next(d for d in docs if d["kind"] == kind)


def rules(documents):
    return [r for d in documents if d["kind"] == "PrometheusRule" and d["metadata"]["name"] == "scaling"
            for g in d["spec"]["groups"] for r in g["rules"]]


if how == "add-pdb":
    docs.append({"apiVersion": "policy/v1", "kind": "PodDisruptionBudget", "metadata": {"name": "x"}, "spec": {"maxUnavailable": 1}})
elif how == "pdb-off":
    one("Cluster")["spec"]["enablePDB"] = False
elif how == "pdb-on":
    one("Cluster")["spec"]["enablePDB"] = True
elif how == "no-affinity":
    del one("Cluster")["spec"]["affinity"]
elif how == "no-zone":
    del one("Cluster")["spec"]["topologySpreadConstraints"]
elif how == "sync":
    one("Cluster")["spec"]["minSyncReplicas"] = 1
    one("Cluster")["spec"]["maxSyncReplicas"] = 1
elif how == "restart":
    one("Cluster")["spec"]["primaryUpdateMethod"] = "restart"
elif how == "supervised":
    one("Cluster")["spec"]["primaryUpdateStrategy"] = "supervised"
elif how == "delay-3600":
    one("Cluster")["spec"]["switchoverDelay"] = 3600
elif how == "no-class":
    del one("Cluster")["spec"]["priorityClassName"]
elif how == "wrong-class":
    one("Cluster")["spec"]["priorityClassName"] = "platform-apps"
elif how == "swap-classes":
    a = next(d for d in docs if d["metadata"]["name"] == "platform-apps")
    b = next(d for d in docs if d["metadata"]["name"] == "platform-observability")
    a["value"], b["value"] = b["value"], a["value"]
elif how == "default-class":
    next(d for d in docs if d["metadata"]["name"] == "platform-observability")["globalDefault"] = True
elif how == "drop-class":
    docs = [d for d in docs if d["metadata"]["name"] != "platform-observability"]
elif how == "page":
    next(r for r in rules(docs) if r["alert"] == "PodsPending")["labels"]["severity"] = "page"
elif how == "short-for":
    next(r for r in rules(docs) if r["alert"] == "HpaAtMaxReplicas")["for"] = "5m"
elif how == "bad-anchor":
    next(r for r in rules(docs) if r["alert"] == "PodsPending")["annotations"]["runbook_url"] = "https://example.test/docs/runbooks/alerts.md#nowhere"
elif how == "other-metric":
    next(r for r in rules(docs) if r["alert"] == "PodsPending")["expr"] = 'kube_pod_info{namespace="shop"} == 1'
elif how == "drop-alert":
    for d in docs:
        if d["kind"] == "PrometheusRule" and d["metadata"]["name"] == "scaling":
            for g in d["spec"]["groups"]:
                g["rules"] = [r for r in g["rules"] if r["alert"] != "PodDisruptionBudgetBlocked"]
else:
    sys.exit("unknown mutation " + how)
yaml.safe_dump_all(docs, open(dst, "w", encoding="utf-8"), sort_keys=False)
PMPY
  # pm_fails FILE MUTATION MESSAGE DESCRIPTION CHECK ARGS...: the mutated file must fail the check with the message
  pm_fails() {
    local file="$1" how="$2" message="$3" description="$4"
    shift 4
    "$contract_py" "$pm/mutate.py" "$file" "$pm/mutated.yaml" "$how" || { bad "$description (mutation $how failed)"; return; }
    contract "$pm/mutated.yaml" "$@"
    if [ "$rc" -eq 1 ] && grep -qF -- "$message" "$work/cout"; then ok "$description"; else bad "$description (exit $rc)"; fi
  }
  pm_fails "$pm/pg2.yaml" add-pdb "the chart renders a PodDisruptionBudget" "a budget of our own next to the operator's is named" postgres-ha t 2
  pm_fails "$pm/pg2.yaml" pdb-off "with 2 instances enablePDB must be true" "two instances without the operator's budgets are named" postgres-ha t 2
  pm_fails "$pm/pg1.yaml" pdb-on "a single instance must have enablePDB: false" "a budget on a single instance is named" postgres-ha t 1
  pm_fails "$pm/pg2.yaml" no-affinity "the instances must avoid sharing a node" "instances that may share a node are named" postgres-ha t 2
  pm_fails "$pm/pg2.yaml" no-zone "the instances need one spread over topology.kubernetes.io/zone" "no zone spread is named" postgres-ha t 2
  pm_fails "$pm/pg2.yaml" sync "synchronous replication is on" "synchronous replicas are named (the profile is asynchronous)" postgres-ha t 2
  pm_fails "$pm/pg2.yaml" restart "primaryUpdateMethod must be switchover" "an in-place restart of the primary is named" postgres-ha t 2
  pm_fails "$pm/pg2.yaml" supervised "primaryUpdateStrategy must be unsupervised" "a manual primary update is named" postgres-ha t 2
  pm_fails "$pm/pg2.yaml" delay-3600 "switchoverDelay 3600 must be set, and at most 900 seconds" "the operator's default hour for a switchover is named" postgres-ha t 2
  pm_fails "$pm/pg2.yaml" no-class "the Cluster must use platform-addons-critical" "a database without its priority class is named" postgres-ha t 2

  contract "$pm/pg2.yaml" priority t platform-addons-critical
  check "the PostgreSQL Cluster and its gate Job have the class of the data layer" test "$rc" -eq 0
  pm_fails "$pm/pg2.yaml" no-class "Cluster/platform-pg has priorityClassName None, expected platform-addons-critical" "a Cluster with no class is named" priority t platform-addons-critical
  pm_fails "$pm/pg2.yaml" wrong-class "Cluster/platform-pg has priorityClassName 'platform-apps'" "a database on the class of the services is named" priority t platform-addons-critical
  contract "$pm/pg2.yaml" priority t platform-addons-critical Job/not-there
  check "an exception that is not in the render is named, so the list does not go stale" grep -q 'the exception Job/not-there is not in the render' "$work/cout"
  contract "$pm/monitors.yaml" priority t platform-addons-critical
  check "a render with no pod in it is not accepted as passing" grep -q 'no pod or pod-creating resource found' "$work/cout"

  contract "$pm/classes.yaml" priority-classes t
  check "the priority classes are in order: add-ons, services, observability" test "$rc" -eq 0
  pm_fails "$pm/classes.yaml" swap-classes "the values must fall in the order" "the stack ranked above the services is named" priority-classes t
  pm_fails "$pm/classes.yaml" default-class "is the global default" "a class that becomes the default is named" priority-classes t
  pm_fails "$pm/classes.yaml" drop-class "PriorityClass platform-observability is missing" "a missing class is named" priority-classes t

  contract "$pm/monitors.yaml" scaling-rules t docs/runbooks/alerts.md
  check "the four scaling alerts are tickets, wait long enough, use known metrics and link to headings of the runbook" test "$rc" -eq 0
  pm_fails "$pm/monitors.yaml" page "PodsPending must have severity ticket" "a scaling alert that pages is named" scaling-rules t docs/runbooks/alerts.md
  pm_fails "$pm/monitors.yaml" short-for "HpaAtMaxReplicas waits 5m and must wait at least 15m" "a duration below the minimum is named" scaling-rules t docs/runbooks/alerts.md
  pm_fails "$pm/monitors.yaml" bad-anchor "points at #nowhere, which is not a heading of the alerts runbook" "a runbook link to a heading that does not exist is named" scaling-rules t docs/runbooks/alerts.md
  pm_fails "$pm/monitors.yaml" other-metric "PodsPending uses the metrics ['kube_pod_info']" "a metric that was not checked is named" scaling-rules t docs/runbooks/alerts.md
  pm_fails "$pm/monitors.yaml" drop-alert "the alert PodDisruptionBudgetBlocked is missing" "a missing alert is named" scaling-rules t docs/runbooks/alerts.md
fi

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
