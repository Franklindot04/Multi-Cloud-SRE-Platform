#!/usr/bin/env bash
# Tests for the helper scripts: scripts/update-image-values.sh and scripts/changed-services.sh (used by CI) and
# scripts/teardown-prep.sh (against a fake kubectl and a fake aws, scripts/tests/fakes).
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
check "it removes the label keys, not sets them to false" grep -q 'label secret cluster-in-cluster platform.example/apps- platform.example/data-$' "$state/kubectl.log"
check "labels come before the Cluster deletion" test "$(line_of 'label secret')" -lt "$(line_of 'delete cluster.postgresql')"
check "the Cluster is deleted before the RabbitmqCluster" test "$(line_of 'delete cluster.postgresql')" -lt "$(line_of 'delete rabbitmqcluster')"
check "the surviving StatefulSet is deleted after the RabbitmqCluster" test "$(line_of 'delete rabbitmqcluster')" -lt "$(line_of 'delete statefulset')"
check "claims are deleted after the StatefulSet" test "$(line_of 'delete statefulset')" -lt "$(line_of 'delete persistentvolumeclaim/platform-valkey')"
check "platform-valkey is deleted" grep -q 'delete persistentvolumeclaim/platform-valkey' "$state/kubectl.log"
check "kubectl get pv is checked after the claims are deleted" test "$(line_of 'get pv')" -gt "$(line_of 'delete persistentvolumeclaim/platform-valkey')"
check "the AWS checks run after kubectl get pv: volumes, load balancers, security groups" test "$(sed -n 's/^--region eu-north-1 \([a-z0-9]*\) \([a-z-]*\).*/\2/p' "$state/aws.log" | tr '\n' ' ')" = "describe-volumes get-resources describe-security-groups "
check "the volume query uses the pvc name tag" grep -q 'Name=tag-key,Values=kubernetes.io/created-for/pvc/name' "$state/aws.log"
check "the load balancer query uses the controller tag" grep -q 'Key=elbv2.k8s.aws/cluster ' "$state/aws.log"
check "every deletion names its namespace" test "$(grep ' delete ' "$state/kubectl.log" | grep -vc -e '-n data delete')" = 0
check "no call uses --force" test "$(cat "$state/kubectl.log" "$state/aws.log" | grep -c -e '--force')" = 0
check "it changes nothing outside argocd, shop and data, and only lists operator pods elsewhere" test "$(grep -e '-n ' "$state/kubectl.log" | grep -v -e '-n argocd' -e '-n shop' -e '-n data' | grep -vc -e '^-n cnpg-system get pods -l ' -e '^-n rabbitmq-system get pods -l ')" = 0
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

new_cluster
printf 'vol-0123456789abcdef0\n' > "$state/aws-volumes"
run_teardown --context test-cluster --region eu-north-1 --timeout 2
check "a leftover EBS volume fails the run" test "$rc" -eq 1
check "and the volume is named" grep -q 'vol-0123456789abcdef0' "$work/tdout"
check "the security group check does not run after that" test "$(grep -c 'describe-security-groups' "$state/aws.log")" = 0

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

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
