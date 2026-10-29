#!/usr/bin/env bash
# Tests for the helper scripts: scripts/update-image-values.sh and scripts/changed-services.sh (used by CI),
# scripts/check-trivyignore.sh, scripts/teardown-prep.sh (against a fake kubectl and a fake aws) and
# scripts/verify-image.sh (against a fake cosign); the fakes are in scripts/tests/fakes.
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

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
