#!/usr/bin/env bash
# Tests for the chaos framework: the schema, scripts/chaos-run.sh and scripts/chaos-run.py, against a fake kubectl that simulates a small
# cluster and a fake Prometheus whose answers are scripted (scripts/tests/fakes/chaos), with experiments from scripts/tests/fixtures/chaos.
# Plain bash (3.2 compatible), no framework, no network, no vendored chart. Run by scripts/test-scripts.sh and by scripts/chaos-check.sh.
#
# The real kubectl must never be reached: PATH starts with the fakes, KUBECONFIG is an empty file, and the first thing the script does
# is to check that the kubectl found is the fake. The runner must also never call aws, terraform or git: those are poisoned in the fakes.
#
#   scripts/chaos-tests.sh
set -euo pipefail

case "${1:-}" in
  -h | --help)
    echo "Usage: $0"
    exit 0
    ;;
esac

cd "$(dirname "${BASH_SOURCE[0]}")/.."

for var in $(env | sed -n 's/^\(AWS_[A-Za-z0-9_]*\)=.*/\1/p; s/^\(KUBECONFIG\)=.*/\1/p; s/^\(KUBECTL_[A-Za-z0-9_]*\)=.*/\1/p; s/^\(CHAOS_[A-Za-z0-9_]*\)=.*/\1/p; s/^\(FAKE_[A-Za-z0-9_]*\)=.*/\1/p'); do
  unset "$var"
done

fakes="$PWD/scripts/tests/fakes/chaos"
fx="scripts/tests/fixtures/chaos"
example="scripts/tests/fixtures/chaos/t-delete-pod.yaml"
cluster="multi-cloud-sre-dev"

py="$(./scripts/python-with-yaml.sh)" || {
  echo "  skip  no Python with PyYAML found (installing yamllint provides it)"
  exit 0
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
state="$work/state"
results="$work/results"
exps="$work/exp"
mkdir -p "$exps"
: > "$work/kubeconfig"
marker="$work/marker"
: > "$marker"

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
check() {
  local label="$1"
  shift
  if "$@" > /dev/null 2>&1; then ok "$label"; else bad "$label"; fi
}

# The fake, and only the fake, must be what the runner finds.
mkdir -p "$work/state0"
found="$(PATH="$fakes:$PATH" command -v kubectl)"
if [ "$found" != "$fakes/kubectl" ] || [ "$(PATH="$fakes:$PATH" FAKE_STATE="$work/state0" KUBECONFIG="$work/kubeconfig" kubectl version --client 2> /dev/null)" != "FAKE_KUBECTL=1" ]; then
  echo "FATAL: the kubectl on the PATH is not the fake ($found): refusing to run any test, because one could reach a real cluster" >&2
  exit 1
fi
ok "kubectl resolves to the fake, and KUBECONFIG is an empty file"

# --- helpers ---------------------------------------------------------------------------------------------------------------------

good_prom='{"probes":{"fake_availability":[0.999]},"page":[[]],"alerts":{}}'

new_state() {
  rm -rf "$state" "$results"
  mkdir -p "$state"
  cp "$fx/cluster.json" "$state/cluster.json"
  printf '%s\n' "${1:-$good_prom}" > "$state/prom.json"
  printf '%s\n' "$cluster" > "$work/stdin"
}

# edit_cluster PYTHON: change the simulated cluster; s is its state.
edit_cluster() {
  python3 - "$state/cluster.json" "$1" << 'PYEND'
import json
import sys

path, code = sys.argv[1:3]
with open(path, encoding="utf-8") as handle:
    s = json.load(handle)
exec(code)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(s, handle)
PYEND
}

# cluster_query PYTHON: print something about the simulated cluster (it initialises the pods first, as the fake would).
cluster_query() {
  PATH="$fakes:$PATH" FAKE_STATE="$state" kubectl get nodes -o json > /dev/null
  python3 - "$state/cluster.json" "$1" << 'PYEND'
import json
import sys

path, code = sys.argv[1:3]
with open(path, encoding="utf-8") as handle:
    s = json.load(handle)
print(eval(code))
PYEND
}

# chaos ARGS...: run the wrapper against the fakes; the output is in $work/out and the status in $rc. Stdin is $work/stdin.
chaos() {
  rc=0
  PATH="$fakes:$PATH" FAKE_STATE="$state" FORBIDDEN_LOG="$work/forbidden.log" KUBECONFIG="$work/kubeconfig" CHAOS_TICK_SECONDS=0.1 \
    ./scripts/chaos-run.sh "$@" --results-dir "$results" > "$work/out" 2>&1 < "$work/stdin" || rc=$?
}

# expect STATUS TEXT DESCRIPTION: the last run ended with STATUS and printed TEXT.
expect() {
  if [ "$rc" -eq "$1" ] && grep -qF -- "$2" "$work/out"; then ok "$3"; else bad "$3 (status $rc, wanted $1 and '$2')"; sed 's/^/        /' "$work/out" | tail -5 >&2; fi
}

# changes: how many calls to kubectl changed something.
changes() {
  [ -e "$state/kubectl.log" ] || { echo 0; return; }
  { grep -c -E '"args": \["(delete|scale|label|annotate|cordon|uncordon|drain|apply|set)"' "$state/kubectl.log" 2> /dev/null || true; } | head -1
}

# exp NAME HOW [SRC]: a variant of a fixture, named NAME, with the change HOW.
exp() {
  local name="$1" how="$2" src="${3:-$fx/t-delete-pod.yaml}"
  "$py" - "$src" "$exps/$name.yaml" "$name" "$how" << 'PYEND'
import copy
import sys

import yaml

src, dst, name, how = sys.argv[1:5]
e = yaml.safe_load(open(src, encoding="utf-8"))
e["name"] = name
inj = e["injection"]
if how == "none":
    pass
elif how == "no-rollback":
    del e["rollback"]
elif how == "no-blast":
    del e["blastRadius"]
elif how == "unknown-action":
    inj["action"] = "explode"
elif how == "no-comparator":
    del e["steadyState"][0]["comparator"]
elif how == "wrong-rollback":
    e["rollback"]["action"] = "uncordon"
elif how == "selector-outside":
    inj["target"]["selector"] = "app.kubernetes.io/name=orders"
elif how == "namespace-outside":
    inj["target"]["namespace"] = "data"
elif how == "count-over":
    inj["count"] = 2
elif how == "page-not-aborting":
    e["abort"]["onPageAlert"] = False
elif how == "not-dev":
    e["preconditions"]["clusterNamePattern"] = "^prod-.*$"
elif how == "no-probe":
    e["steadyState"] = []
elif how == "multiline":
    e["hypothesis"] = "first line\nsecond line of the hypothesis"
elif how == "unknown-field":
    e["surprise"] = True
elif how == "workload-outside":
    inj["target"]["name"] = "orders"
elif how == "drain-too-few-nodes":
    e["preconditions"]["minReadyNodes"] = 1
elif how == "no-page-check":
    e["preconditions"]["noPageAlerts"] = False
elif how == "short":
    e["duration"] = 2
    e["rollback"]["timeoutSeconds"] = 20
elif how == "long":
    e["duration"] = 30
elif how == "two-replicas":
    e["preconditions"]["minReplicas"][0]["count"] = 3
elif how == "ack":
    inj["acknowledgeSelfHeal"] = True
elif how == "gateway-scale":
    inj["target"]["name"] = "gateway"
    e["blastRadius"]["workloads"] = [{"kind": "Deployment", "name": "gateway"}]
    e["blastRadius"]["selectors"] = ["app.kubernetes.io/name=gateway"]
elif how == "narrow-drain":
    e["blastRadius"]["selectors"] = ["app.kubernetes.io/name=gateway"]
    inj["target"]["selector"] = "app.kubernetes.io/name=gateway"
elif how == "alerts":
    e["expectedObservations"] = [{"alert": "ServiceTargetDown"}, {"alert": "NeverFires"}]
else:
    sys.exit("unknown variant " + how)
yaml.safe_dump(e, open(dst, "w", encoding="utf-8"), sort_keys=False)
PYEND
}

# field FILE EXPRESSION: a value from a result file.
field() {
  python3 -c 'import json, sys; r = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}

result_json() { find "$results" -name "*.json" 2> /dev/null | head -1; }

# --- the schema ------------------------------------------------------------------------------------------------------------------

echo "chaos experiments: the schema"

new_state
chaos --validate "$fx"/t-*.yaml
check "the four fixtures are valid" test "$rc" -eq 0

exp v-ok none
check "an unchanged copy of a fixture is valid" "$py" scripts/chaos-run.py --validate "$exps/v-ok.yaml"

schema_fails() {
  # schema_fails VARIANT SRC MESSAGE DESCRIPTION
  exp "v-$1" "$1" "$2"
  chaos --validate "$exps/v-$1.yaml"
  expect 2 "$3" "$4"
}
schema_fails no-rollback "$fx/t-delete-pod.yaml" "required property 'rollback' is missing" "an experiment without a rollback is refused"
schema_fails no-blast "$fx/t-delete-pod.yaml" "required property 'blastRadius' is missing" "an experiment without a blast radius is refused"
schema_fails unknown-action "$fx/t-delete-pod.yaml" "experiment.injection.action: 'explode' is not one of delete-pod, drain-node, scale-to-zero, apply-network-deny" "an unknown action is refused, with the closed set named"
schema_fails no-comparator "$fx/t-delete-pod.yaml" "experiment.steadyState[0]: required property 'comparator' is missing" "a threshold without a comparator is refused"
schema_fails no-probe "$fx/t-delete-pod.yaml" "experiment.steadyState: needs at least 1 item(s)" "an experiment without a steady-state probe is refused"
schema_fails page-not-aborting "$fx/t-delete-pod.yaml" "experiment.abort.onPageAlert: must be True, not False" "an abort rule that ignores page alerts is refused"
schema_fails no-page-check "$fx/t-delete-pod.yaml" "experiment.preconditions.noPageAlerts: must be True, not False" "a precondition that allows page alerts is refused"
schema_fails multiline "$fx/t-delete-pod.yaml" "experiment.hypothesis:" "a hypothesis of more than one line is refused"
schema_fails unknown-field "$fx/t-delete-pod.yaml" "experiment: unknown property 'surprise'" "an unknown field is refused"
schema_fails not-dev "$fx/t-delete-pod.yaml" "experiment.preconditions.clusterNamePattern: '^prod-.*\$' does not match dev" "a cluster pattern that is not a dev pattern is refused"
schema_fails wrong-rollback "$fx/t-delete-pod.yaml" "experiment.rollback.action: 'uncordon' does not undo delete-pod (it needs wait-for-ready)" "a rollback that does not undo the injection is refused"
schema_fails selector-outside "$fx/t-delete-pod.yaml" "is not within any selector of blastRadius.selectors" "a target selector outside the blast radius is refused"
schema_fails namespace-outside "$fx/t-delete-pod.yaml" "experiment.injection.target.namespace: 'data' is not in blastRadius.namespaces" "a target namespace outside the blast radius is refused"
schema_fails count-over "$fx/t-delete-pod.yaml" "experiment.injection.count: 2 is above blastRadius.maxPods (1)" "more pods than the blast radius allows are refused"
schema_fails workload-outside "$fx/t-scale-to-zero.yaml" "experiment.injection.target: Deployment/orders is not in blastRadius.workloads" "a workload outside the blast radius is refused"
schema_fails drain-too-few-nodes "$fx/t-drain-node.yaml" "is too low to drain 1 node(s); it needs at least 2" "a drain that could leave no node is refused"
cp "$fx/t-delete-pod.yaml" "$exps/other-name.yaml"
chaos --validate "$exps/other-name.yaml"
expect 2 "experiment.name: 't-delete-pod' must be the name of the file (other-name.yaml)" "a name that is not the file name is refused"
check "the schema file is JSON with the four actions" python3 -c 'import json; s = json.load(open("chaos/schema/experiment.schema.json")); assert len(s["properties"]["injection"]["oneOf"]) == 4'
check "the runner has no command for aws, terraform or git" test "$(grep -c -E '"(aws|terraform|git)"' scripts/chaos-run.py)" = 0
check "the only kubectl delete in the runner is checked against the blast radius first" test "$(grep -c '"delete"' scripts/chaos-run.py)" = "$(grep -c 'kube.mutate(\["delete"' scripts/chaos-run.py)"

# --- dry run and the refusals before anything happens ------------------------------------------------------------------------------

echo "chaos-run.sh: dry run and refusals"

new_state
chaos "$example"
expect 0 "This was a dry run. Nothing was changed and the cluster was not read." "the default is a dry run"
check "it prints the plan: the hypothesis, the blast radius, the rollback and the abort rule" test "$(grep -c -e 'Hypothesis' -e 'Blast radius' -e 'Rollback     wait-for-ready' -e 'Abort        a probe failing' "$work/out")" -ge 4
check "it made one kubectl call, to read the context name, and none changed anything" test "$(wc -l < "$state/kubectl.log" | tr -d ' ')" = 1 -a "$(changes)" = 0
check "it asked Prometheus nothing" test ! -e "$state/prom.log"
check "and wrote no result" test ! -e "$results"

: > "$work/stdin"
chaos "$example" --execute
expect 1 "refused: not confirmed" "no answer at all is not a confirmation"
new_state
printf 'yes\n' > "$work/stdin"
chaos "$example" --execute
expect 1 "refused: not confirmed: nothing was changed" "a wrong confirmation text is refused"
check "and nothing was changed" test "$(changes)" = 0
new_state
printf '%s\n' "${cluster}x" > "$work/stdin"
chaos "$example" --execute
expect 1 "not confirmed" "the cluster name with a character more is not a confirmation"

new_state
edit_cluster 's["context"] = "prod-eu-1"'
chaos "$example"
expect 1 "the cluster 'prod-eu-1' does not match the pattern ^[a-z0-9-]+-dev\$ of the experiment" "a dry run on a cluster that is not a dev cluster is refused"
printf '%s\n' "prod-eu-1" > "$work/stdin"
chaos "$example" --execute
expect 1 "the cluster 'prod-eu-1' does not match the pattern" "a real run on a cluster that is not a dev cluster is refused, even when its name is typed"
check "and nothing was changed or asked of Prometheus" test "$(changes)" = 0 -a ! -e "$state/prom.log"

new_state
edit_cluster 's["context"] = "arn:aws:eks:eu-north-1:123456789012:cluster/multi-cloud-sre-dev"'
chaos "$example"
expect 0 "Cluster      multi-cloud-sre-dev (matches" "a context that is an ARN is compared on the cluster name"
check "and the account in it is never printed" test "$(grep -c '123456789012' "$work/out")" = 0

new_state
edit_cluster 's["nodes"][2]["ready"] = False; s["nodes"][1]["ready"] = False'
chaos "$example" --execute
expect 1 "precondition: 1 schedulable ready node(s), the experiment needs 2" "too few ready nodes is refused"
check "and nothing was changed" test "$(changes)" = 0
new_state
exp p-replicas two-replicas
chaos "$exps/p-replicas.yaml" --execute
expect 1 "precondition: Deployment shop/gateway has 2 ready replica(s), the experiment needs 3" "too few replicas of the target is refused"
new_state '{"probes":{"fake_availability":[0.999]},"page":[["ApiDown"]],"alerts":{}}'
chaos "$example" --execute
expect 1 "precondition: page alert(s) are firing: ApiDown" "a page alert firing before the start is refused"
check "and nothing was changed" test "$(changes)" = 0
new_state
edit_cluster 's["networkpolicies"].append({"name": "chaos-deny-old", "ns": "shop", "labels": {"chaos.platform.example/managed-by": "chaos-run"}, "spec": {"podSelector": {}, "policyTypes": ["Ingress"]}})'
chaos "$example" --execute
expect 1 "run chaos-run.sh --cleanup first" "a leftover of an earlier run is refused"
new_state '{"probes":{"fake_availability":[0.5]},"page":[[]],"alerts":{}}'
chaos "$fx/t-delete-pod.yaml" --execute
expect 1 "the steady state does not hold before the injection (gateway-availability violated (0.5)); nothing was injected" "a steady state that is red before the injection is refused"
check "and nothing was changed" test "$(changes)" = 0
new_state '{"probes":{"fake_availability":[null]},"page":[[]],"alerts":{}}'
chaos "$fx/t-delete-pod.yaml" --execute
expect 1 "gateway-availability no-data" "no data on a probe whose noData is fail is refused"
new_state '{"probes":{"other_query":[1]},"page":[[]],"alerts":{}}'
chaos "$fx/t-delete-pod.yaml" --execute
expect 1 "gateway-availability error" "a probe that cannot be answered is refused, not ignored"

# --- a run that goes well --------------------------------------------------------------------------------------------------------

echo "chaos-run.sh: a run"

new_state '{"probes":{"fake_availability":[0.999]},"page":[[]],"alerts":{"ServiceTargetDown":["","pending","firing"]}}'
exp r-delete none
exp r-alerts alerts
chaos "$exps/r-delete.yaml" --execute
expect 0 "Hypothesis HELD." "the example experiment runs against the fakes and the hypothesis holds"
check "exactly one pod was deleted, in shop" test "$(grep -c '"args": \["delete", "pod"' "$state/kubectl.log")" = 1 -a "$(changes)" = 1
check "the pods are back at two, all ready" test "$(cluster_query 'len([p for p in s["pods"] if p["ns"] == "shop" and p["labels"].get("app.kubernetes.io/name") == "gateway" and p["readyIn"] <= 0])')" = 2
check "a JSON and a Markdown result were written to the results folder" test "$(find "$results" -type f | wc -l | tr -d ' ')" = 2
r="$(result_json)"
check "the result says the hypothesis held, nothing aborted, the rollback worked and it recovered" test "$(field "$r" '[r["hypothesisHeld"], r["aborted"], r["rollback"]["ok"], r["recovered"]]')" = "[True, None, True, True]"
check "it has the timings, the probe values before, during and after, and the one change made" test "$(field "$r" '[len(r["phases"]) >= 6, len(r["probes"]["before"]), len(r["probes"]["during"]) > 3, len(r["probes"]["after"]), len(r["mutations"])]')" = "[True, 1, True, 1, 1]"
check "the cluster is named in it, and no account" test "$(field "$r" 'r["cluster"]')" = "$cluster" -a "$(grep -c -E '[0-9]{12}' "$r")" = 0
check "the Markdown summary says the hypothesis held" grep -q 'the hypothesis held' "$results"/*.md
check "the Prometheus queries went through the port-forward" test "$(grep -c '"port-forward"' "$state/kubectl.log")" = 1
check "every kubectl call but the first, which reads the context name, named the checked context" test "$(grep -v -e 'current-context' -e '"context": null' "$state/kubectl.log" | grep -c -v "\"context\": \"$cluster\"")" = 0

new_state '{"probes":{"fake_availability":[0.999]},"page":[[]],"alerts":{"ServiceTargetDown":["","pending","firing"]}}'
chaos "$exps/r-alerts.yaml" --execute
r="$(result_json)"
check "an expected alert that fired is recorded as fired, and one that never did as not seen" test "$(field "$r" '[r["alerts"]["fired"], r["alerts"]["missing"]]')" = "[['ServiceTargetDown'], ['NeverFires']]"

# --- a run that breaks the hypothesis --------------------------------------------------------------------------------------------

echo "chaos-run.sh: abort and rollback"

exp a-scale none "$fx/t-scale-to-zero.yaml"
exp a-long long "$fx/t-scale-to-zero.yaml"
new_state '{"probes":{"fake_availability":[0.999,0.999,0.999,0.2,0.999]},"page":[[]],"alerts":{}}'
chaos "$exps/a-scale.yaml" --execute
expect 4 "ABORT: probe gateway-availability failed for 0s (grace 0s): gateway-availability violated (0.2)" "a probe failing during the run aborts it"
check "the notifier is back at one replica, without the chaos labels and the annotation" test "$(cluster_query '[d["replicas"] for d in s["deployments"] if d["name"] == "notifier"] + [sorted(k for k in d["labels"] if "chaos" in k) for d in s["deployments"] if d["name"] == "notifier"] + [sorted(k for k in d["annotations"] if "chaos" in k) for d in s["deployments"] if d["name"] == "notifier"]')" = "[1, [], []]"
r="$(result_json)"
check "the result is a finding: the hypothesis did not hold, it was aborted, the rollback worked" test "$(field "$r" '[r["hypothesisHeld"], r["aborted"]["reason"].startswith("probe gateway-availability failed"), r["rollback"]["ok"]]')" = "[False, True, True]"
check "the notifier was scaled down and then up again, in that order" test "$(grep -n -E '"--replicas=(0|1)"' "$state/kubectl.log" | sed 's/.*--replicas=\([01]\).*/\1/' | tr -d '\n')" = "01"
check "the Markdown says the hypothesis did not hold" grep -q 'did not hold' "$results"/*.md

new_state '{"probes":{"fake_availability":[0.999]},"page":[[],[],["PayDown"]],"alerts":{}}'
chaos "$exps/a-scale.yaml" --execute
expect 4 "ABORT: page alert(s) firing: PayDown" "a page alert firing during the run aborts it at once"
check "and the notifier is back" test "$(cluster_query '[d["replicas"] for d in s["deployments"] if d["name"] == "notifier"][0]')" = 1
check "the page alert is in the result" test "$(field "$(result_json)" 'r["alerts"]["page"]')" = "['PayDown']"

new_state '{"probes":{"fake_availability":[0.999]},"page":[[]],"alerts":{}}'
touch "$state/fail-restore"
exp a-restore none "$fx/t-scale-to-zero.yaml"
chaos "$exps/a-restore.yaml" --execute
expect 1 "ROLLBACK FAILED. Find what is left with: scripts/chaos-run.sh --cleanup" "a rollback that fails says so and exits 1"
check "the failure is in the result" test "$(field "$(result_json)" '[r["rollback"]["ok"], r["hypothesisHeld"]]')" = "[False, False]"

# SIGINT, SIGTERM and SIGHUP during the injection
run_and_signal() {
  # run_and_signal SIGNAL EXPERIMENT WAIT_FOR: start a run in the background, wait for the injection, signal it, wait for it to end.
  local sig="$1" experiment="$2" waitfor="$3"
  PATH="$fakes:$PATH" FAKE_STATE="$state" FORBIDDEN_LOG="$work/forbidden.log" KUBECONFIG="$work/kubeconfig" CHAOS_TICK_SECONDS=0.1 \
    ./scripts/chaos-run.sh "$experiment" --execute --results-dir "$results" > "$work/out" 2>&1 < "$work/stdin" &
  local pid=$!
  for _ in $(seq 1 100); do
    grep -q -E "$waitfor" "$state/kubectl.log" 2> /dev/null && break
    sleep 0.1
  done
  kill "-$sig" "$pid"
  rc=0
  wait "$pid" || rc=$?
}
for sig in INT TERM HUP; do
  new_state
  run_and_signal "$sig" "$exps/a-long.yaml" '"--replicas=0"'
  case "$sig" in INT) want=130 ;; TERM) want=143 ;; HUP) want=129 ;; esac
  expect "$want" "ABORT: interrupted by SIG$sig" "SIG$sig during the injection ends the run"
  check "SIG$sig: the notifier is back at one replica" test "$(cluster_query '[d["replicas"] for d in s["deployments"] if d["name"] == "notifier"][0]')" = 1
  check "SIG$sig: the result says it was interrupted, and the rollback worked" test "$(field "$(result_json)" '[r["aborted"]["reason"], r["rollback"]["ok"]]')" = "['interrupted by SIG$sig', True]"
done
exp a-drain long "$fx/t-drain-node.yaml"
new_state
run_and_signal TERM "$exps/a-drain.yaml" '"drain"'
expect 143 "ABORT: interrupted by SIGTERM" "SIGTERM during a drain ends the run"
check "and every node is schedulable again, without chaos labels" test "$(cluster_query '[(n.get("unschedulable"), sorted(k for k in n.get("labels", {}) if "chaos" in k)) for n in s["nodes"]]')" = "[(False, []), (False, []), (False, [])]"

# --- the blast radius, in code ---------------------------------------------------------------------------------------------------

echo "chaos-run.sh: the blast radius"

new_state
touch "$state/leak-pods"
chaos "$exps/r-delete.yaml" --execute
expect 1 "pod other/orders-leak is in the namespace other, which is not in the blast radius (shop)" "a pod the cluster returns from a namespace outside the blast radius is refused"
check "no delete was sent" test "$(grep -c '"args": \["delete"' "$state/kubectl.log")" = 0
new_state
printf 'shop\n' > "$state/leak-pods"
chaos "$exps/r-delete.yaml" --execute
expect 1 "pod shop/orders-leak (labels app.kubernetes.io/name=orders) matches none of the selectors of the blast radius (app.kubernetes.io/name=gateway)" "a pod of the right namespace whose labels match no selector is refused, and named"
check "no delete was sent" test "$(grep -c '"args": \["delete"' "$state/kubectl.log")" = 0

new_state
exp b-drain narrow-drain "$fx/t-drain-node.yaml"
chaos "$exps/b-drain.yaml" --execute
expect 1 "no node can be drained inside the blast radius" "a node that also runs pods outside the blast radius is not drained"
check "and nothing was cordoned or drained" test "$(grep -c -E '"args": \["(cordon|drain)"' "$state/kubectl.log")" = 0

new_state
chaos "$fx/t-drain-node.yaml" --execute
expect 0 "Hypothesis HELD." "a drain inside the blast radius works"
check "one node was cordoned, drained and uncordoned, in that order" test "$(grep -o -E '"args": \["(cordon|drain|uncordon)"' "$state/kubectl.log" | sed 's/.*\["//; s/"//' | tr '\n' ' ')" = "cordon drain uncordon "
check "the daemon pods were not counted as strays" test "$(grep -c 'skipped' "$work/out")" = 0

new_state
exp b-hpa gateway-scale "$fx/t-scale-to-zero.yaml"
chaos "$exps/b-hpa.yaml" --execute
expect 1 "is scaled by the autoscaler gateway, which would undo the experiment" "a workload with an autoscaler is not scaled to zero"
check "and its replicas were never changed" test "$(grep -c '"--replicas' "$state/kubectl.log")" = 0

# --- the network deny ----------------------------------------------------------------------------------------

echo "chaos-run.sh: network deny"

new_state
chaos "$fx/t-network-deny.yaml" --execute
expect 0 "Hypothesis HELD." "a pod can be isolated and the run ends with the hypothesis held"
check "a deny policy named chaos-deny-... was applied, then the pod was relabelled, in that order" test "$(grep -o -E '"args": \["(apply|label)"' "$state/kubectl.log" | sed 's/.*\["//; s/"//' | tr '\n' ' ')" = "apply label "
check "no chaos policy and no isolated pod is left, and the gateway has two ready pods" test "$(cluster_query '[len([n for n in s["networkpolicies"] if n["name"].startswith("chaos-")]), len([p for p in s["pods"] if any("chaos" in k for k in p["labels"])]), len([p for p in s["pods"] if p["labels"].get("app.kubernetes.io/name") == "gateway" and p["readyIn"] <= 0])]')" = "[0, 0, 2]"
new_state
edit_cluster 's["networkpolicies"].append({"name": "shop-allow-all", "ns": "shop", "labels": {}, "spec": {"podSelector": {}, "policyTypes": ["Ingress"], "ingress": [{}]}})'
chaos "$fx/t-network-deny.yaml" --execute
expect 1 "the policy shop/shop-allow-all would still select an isolated pod and add allow rules to it" "a policy that would still allow the isolated pod makes the action refuse"
check "and no policy was applied" test "$(grep -c '"apply"' "$state/kubectl.log")" = 0

# --- cleanup ---------------------------------------------------------------------------------------------------------------------

echo "chaos-run.sh --cleanup"

leftovers() {
  edit_cluster '
s["networkpolicies"].append({"name": "chaos-deny-old", "ns": "shop", "labels": {"chaos.platform.example/managed-by": "chaos-run", "chaos.platform.example/run": "old", "chaos.platform.example/experiment": "t-network-deny"}, "spec": {"podSelector": {"matchLabels": {"chaos.platform.example/isolated": "old"}}, "policyTypes": ["Ingress"]}})
for d in s["deployments"]:
    if d["name"] == "notifier":
        d["replicas"] = 0
        d["labels"].update({"chaos.platform.example/managed-by": "chaos-run", "chaos.platform.example/run": "old"})
        d["annotations"]["chaos.platform.example/original-replicas"] = "1"
s["nodes"][1]["unschedulable"] = True
s["nodes"][1]["labels"] = {"chaos.platform.example/managed-by": "chaos-run", "chaos.platform.example/run": "old"}
'
  PATH="$fakes:$PATH" FAKE_STATE="$state" kubectl get nodes -o json > /dev/null
  edit_cluster '
s["pods"].append({"name": "gateway-stray", "ns": "shop", "labels": {"chaos.platform.example/managed-by": "chaos-run", "chaos.platform.example/isolated": "old"}, "node": "node-a", "owner": None, "readyIn": 0, "annotations": {}})
'
}
new_state
leftovers
chaos --cleanup
expect 0 "Nothing was changed. To revert these: chaos-run.sh --cleanup --execute" "cleanup lists the leftovers and changes nothing"
check "it found a policy, a scaled-down workload, an isolated pod and a cordoned node" test "$(grep -c -E '^  (networkpolicy|deployment|pod|node) ' "$work/out")" = 4
check "and made no change" test "$(changes)" = 0
printf 'nope\n' > "$work/stdin"
chaos --cleanup --execute
expect 1 "not confirmed" "cleanup with a wrong confirmation changes nothing"
check "and made no change" test "$(changes)" = 0
printf '%s\n' "$cluster" > "$work/stdin"
chaos --cleanup --execute
expect 0 "reverted networkpolicy chaos-deny-old" "cleanup reverts a leftover network policy"
check "the notifier is back at its original replica count, and the chaos labels and the annotation are gone" test "$(cluster_query '[[d["replicas"], sorted(k for k in d["labels"] if "chaos" in k), sorted(k for k in d["annotations"] if "chaos" in k)] for d in s["deployments"] if d["name"] == "notifier"][0]')" = "[1, [], []]"
check "the isolated pod is deleted, the node is schedulable and unlabelled, the policy is gone" test "$(cluster_query '[len([p for p in s["pods"] if p["name"] == "gateway-stray"]), s["nodes"][1].get("unschedulable"), sorted(s["nodes"][1].get("labels", {})), len(s["networkpolicies"])]')" = "[0, False, [], 1]"
chaos --cleanup
expect 0 "No leftover of a chaos run." "a second cleanup finds nothing"
new_state
edit_cluster 's["context"] = "prod-eu-1"'
chaos --cleanup
expect 1 "the cluster 'prod-eu-1' does not match the pattern" "cleanup on a cluster that is not a dev cluster is refused"

# --- the real experiments ----------------------------------------------------------------------------------------------------------

echo "the experiments of chaos/experiments"

new_full() {
  rm -rf "$state" "$results"
  mkdir -p "$state"
  cp "$fx/cluster-full.json" "$state/cluster.json"
  printf '%s\n' "$cluster" > "$work/stdin"
  cluster_query '0' > /dev/null
}

# prom_for EXPERIMENT: script the fake Prometheus so that every probe of the experiment holds.
prom_for() {
  "$py" - "$1" "$state/prom.json" << 'PYEND'
import json
import sys

import yaml

e = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
probes = {}
for p in e["steadyState"]:
    t = p["threshold"]
    probes[p["query"]] = [t if p["comparator"] in (">=", "<=", "==") else (t + 1 if p["comparator"] == ">" else t - 1)]
json.dump({"probes": probes, "page": [[]], "alerts": {}}, open(sys.argv[2], "w"))
PYEND
}

# signature: what a run must leave as it was (replicas, schedulable nodes, policies, chaos labels and annotations).
signature() {
  cluster_query '[sorted((d["name"], d["replicas"]) for d in s["deployments"]), [n.get("unschedulable") for n in s["nodes"]], sorted(n["name"] for n in s["networkpolicies"]),
    sum(1 for o in s["deployments"] + s["nodes"] + s["pods"] if any("chaos" in k for k in list(o.get("labels", {})) + list(o.get("annotations", {})))),
    sorted(p["labels"].get("app.kubernetes.io/name", "") for p in s["pods"] if p["ns"] == "shop")]'
}

experiments=""
for f in chaos/experiments/*.yaml; do experiments="$experiments $(basename "$f" .yaml)"; done
check "there are eleven experiments, and no example among them" test "$(echo "$experiments" | wc -w | tr -d ' ')" = 11 -a "$(echo "$experiments" | grep -c example)" = 0
chaos --validate chaos/experiments/*.yaml
check "every experiment is valid" test "$rc" -eq 0

for name in $experiments; do
  new_full
  chaos "chaos/experiments/$name.yaml"
  expect 0 "This was a dry run. Nothing was changed and the cluster was not read." "$name: the dry run prints the plan and changes nothing"
  check "$name: the plan names the injection, the rollback and the blast radius" test "$(grep -c -e '^Injection    ' -e '^Rollback     ' -e '^Blast radius' "$work/out")" = 3
  new_full
  before="$(signature)"
  exp "$name" short "chaos/experiments/$name.yaml"
  prom_for "$exps/$name.yaml"
  chaos "$exps/$name.yaml" --execute
  expect 0 "Hypothesis HELD." "$name: a run against the fake cluster ends with the hypothesis held"
  check "$name: the rollback worked and the cluster is as it was" test "$(field "$(result_json)" 'r["rollback"]["ok"]')" = True -a "$(signature)" = "$before"
  check "$name: the changes it made are in the result, and there is at least one" test "$(field "$(result_json)" 'len(r["mutations"])')" -ge 1
done

# What each experiment did to the fake cluster, in short.
new_full
exp postgres-primary-failover short chaos/experiments/postgres-primary-failover.yaml
prom_for "$exps/postgres-primary-failover.yaml"
chaos "$exps/postgres-primary-failover.yaml" --execute
check "postgres-primary-failover: it deleted one pod of the cluster (chosen by the label of the primary), and a replica was promoted" test "$(grep -c '"args": \["delete", "pod", "platform-pg-' "$state/kubectl.log")" = 1 -a "$(cluster_query 'sorted(p["labels"].get("cnpg.io/instanceRole") for p in s["pods"] if p["labels"].get("cnpg.io/cluster") == "platform-pg")')" = "['primary', 'replica']"
new_full
exp node-drain short chaos/experiments/node-drain.yaml
prom_for "$exps/node-drain.yaml"
chaos "$exps/node-drain.yaml" --execute
pnode="$(cluster_query '[p["node"] for p in s["pods"] if p["name"].startswith("prometheus")][0]')"
check "node-drain: one node was drained, and it is not the node of Prometheus" test "$(grep -c '"args": \["drain", "node-' "$state/kubectl.log")" = 1 -a "$(grep -c "\"args\": \[\"drain\", \"$pnode\"" "$state/kubectl.log")" = 0
check "node-drain: the node of Prometheus was skipped, and the result says so" grep -q 'asks to avoid' "$results"/node-drain-*.json
new_full
exp x-nodrain short chaos/experiments/node-drain.yaml
"$py" - "$exps/node-drain.yaml" << 'PYEND'
import sys

import yaml

e = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
e["blastRadius"]["anyPodInNamespaces"] = ["shop"]
yaml.safe_dump(e, open(sys.argv[1], "w", encoding="utf-8"), sort_keys=False)
PYEND
prom_for "$exps/node-drain.yaml"
chaos "$exps/node-drain.yaml" --execute
expect 1 "no node can be drained inside the blast radius" "node-drain: with only shop in anyPodInNamespaces no node is drained, because the others run pods of data, kube-system and the rest"
check "and nothing was cordoned" test "$(grep -c '"cordon"' "$state/kubectl.log")" = 0
new_full
edit_cluster 's["nodes"][3]["ready"] = False'
exp node-drain short chaos/experiments/node-drain.yaml
prom_for "$exps/node-drain.yaml"
chaos "$exps/node-drain.yaml" --execute
expect 1 "precondition: 3 schedulable ready node(s), the experiment needs 4" "node-drain is refused on a cluster with three nodes"

# Argo CD
echo "the experiments that scale a workload: Argo CD"

new_full
exp valkey-down short chaos/experiments/valkey-down.yaml
prom_for "$exps/valkey-down.yaml"
edit_cluster 'for a in s["applications"]:
    a["annotations"] = {}'
chaos "$exps/valkey-down.yaml" --execute
expect 1 "is managed by the Argo CD Application data-valkey-in-cluster, which self-heals: it would put the replica count back within seconds" "an Application that self-heals and is not paused refuses the scale to zero"
check "and the replicas were not touched" test "$(grep -c '"--replicas' "$state/kubectl.log")" = 0
new_full
prom_for "$exps/valkey-down.yaml"
edit_cluster 'for a in s["applications"]:
    a["annotations"] = {}
    a["spec"]["syncPolicy"]["automated"]["selfHeal"] = False'
chaos "$exps/valkey-down.yaml" --execute
expect 0 "Hypothesis HELD." "an Application that does not self-heal does not stop the run"
new_full
prom_for "$exps/valkey-down.yaml"
edit_cluster 's["applications"] = []'
chaos "$exps/valkey-down.yaml" --execute
expect 1 "that cannot be read" "a workload whose Application cannot be read is refused"
new_full
prom_for "$exps/valkey-down.yaml"
touch "$state/revert-scale"
chaos "$exps/valkey-down.yaml" --execute
expect 5 "the injection was undone from outside after" "an injection that something puts back is found, and the run is not valid"
check "the result says it is not valid, the hypothesis is not claimed and the rollback worked" test "$(field "$(result_json)" '[r["invalid"], r["hypothesisHeld"], r["rollback"]["ok"]]')" = "[True, False, True]"
check "the cluster is as it was" test "$(cluster_query '[d["replicas"] for d in s["deployments"] if d["name"] == "platform-valkey"][0]')" = 1

# the fields added for the experiments
echo "the experiment fields: phases, mustNotFire, readySelector, avoid"

new_state '{"probes":{"fake_availability":[0.999,0.999,0.2]},"page":[[]],"alerts":{}}'
"$py" - "$fx/t-delete-pod.yaml" "$exps/p-phases.yaml" << 'PYEND'
import sys

import yaml

e = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
e["name"] = "p-phases"
e["steadyState"][0]["phases"] = ["before", "after"]
yaml.safe_dump(e, open(sys.argv[2], "w", encoding="utf-8"), sort_keys=False)
PYEND
chaos "$exps/p-phases.yaml" --execute
expect 4 "gateway-availability violated (0.2)" "a probe limited to before and after is not read during the run (the bad value comes in the after check, which fails the run)"
check "it was read twice, not during" test "$(grep -c 'fake_availability' "$state/prom.log")" -le 4
"$py" - "$fx/t-delete-pod.yaml" "$exps/p-badphase.yaml" << 'PYEND'
import sys

import yaml

e = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
e["name"] = "p-badphase"
e["steadyState"][0]["phases"] = ["during", "later"]
yaml.safe_dump(e, open(sys.argv[2], "w", encoding="utf-8"), sort_keys=False)
PYEND
chaos --validate "$exps/p-badphase.yaml"
expect 2 "experiment.steadyState[0].phases[1]: 'later' is not one of before, during, after" "an unknown phase is refused"
new_state '{"probes":{"fake_availability":[0.999]},"page":[[]],"alerts":{"Boom":["","firing"]}}'
"$py" - "$fx/t-delete-pod.yaml" "$exps/p-forbidden.yaml" << 'PYEND'
import sys

import yaml

e = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
e["name"] = "p-forbidden"
e["mustNotFire"] = ["Boom"]
yaml.safe_dump(e, open(sys.argv[2], "w", encoding="utf-8"), sort_keys=False)
PYEND
chaos "$exps/p-forbidden.yaml" --execute
expect 4 "DID NOT HOLD" "an alert that must not fire and does makes the hypothesis fail"
check "it is named in the result and in the summary" test "$(field "$(result_json)" 'r["alerts"]["forbidden"]')" = "['Boom']" -a "$(grep -c 'must not fire, and did: Boom' "$results"/*.md)" = 1
"$py" - "$exps/p-forbidden.yaml" "$exps/p-both.yaml" << 'PYEND'
import sys

import yaml

e = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
e["name"] = "p-both"
e["expectedObservations"] = [{"alert": "Boom"}]
yaml.safe_dump(e, open(sys.argv[2], "w", encoding="utf-8"), sort_keys=False)
PYEND
chaos --validate "$exps/p-both.yaml"
expect 2 "experiment.mustNotFire: Boom is also in expectedObservations" "an alert that is expected and must not fire is refused"
exp p-ready none "chaos/experiments/postgres-primary-failover.yaml"
"$py" - "$exps/p-ready.yaml" << 'PYEND'
import sys

import yaml

e = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
e["injection"]["readySelector"] = "app.kubernetes.io/name=orders"
yaml.safe_dump(e, open(sys.argv[1], "w", encoding="utf-8"), sort_keys=False)
PYEND
chaos --validate "$exps/p-ready.yaml"
expect 2 "experiment.injection.readySelector: 'app.kubernetes.io/name=orders' is not within any selector of blastRadius.selectors" "a ready selector outside the blast radius is refused"

# the lint
echo "scripts/chaos-lint.py"

if ! command -v helm > /dev/null 2>&1; then
  echo "  skip  needs helm (the rules are read from the rendered monitors chart)"
else
  helm template m platform/observability/monitors --namespace observability > "$work/monitors.yaml" 2> /dev/null || true
  lint() {
    rc=0
    "$py" scripts/chaos-lint.py --rules "$work/monitors.yaml" --confirmed platform/observability/dashboards/confirmed-upstream.txt \
      --dashboards platform/observability/dashboards/files --allow chaos/metrics-allowlist.txt "$@" > "$work/out" 2>&1 || rc=$?
  }
  lint chaos/experiments/*.yaml
  expect 0 "11 experiment(s) are consistent" "every experiment passes the lint"
  lint_fails() {
    # lint_fails VARIANT SRC MESSAGE DESCRIPTION
    "$py" - "$2" "$exps/$1.yaml" "$1" << 'PYEND'
import sys

import yaml

src, dst, how = sys.argv[1:4]
e = yaml.safe_load(open(src, encoding="utf-8"))
e["name"] = how
b, inj = e["blastRadius"], e["injection"]
if how == "bad-metric":
    e["steadyState"][1]["query"] = e["steadyState"][1]["query"].replace("http_requests_total", "no_such_total")
elif how == "bad-expected-alert":
    e["expectedObservations"] = [{"alert": "NoSuchAlert"}]
elif how == "bad-forbidden-alert":
    e["mustNotFire"] = ["AlsoNoSuchAlert"]
elif how == "wider-namespace":
    b["namespaces"] = ["shop", "data"]
elif how == "wider-selector":
    b["selectors"] = ["app.kubernetes.io/name=gateway", "app.kubernetes.io/part-of=sre-sample"]
elif how == "more-pods":
    b["maxPods"] = 3
elif how == "workload-on-pod-action":
    b["workloads"] = [{"kind": "Deployment", "name": "gateway"}]
elif how == "nodes-on-pod-action":
    b["maxNodes"] = 1
elif how == "any-pod-without-drain":
    b["anyPodInNamespaces"] = ["shop"]
else:
    sys.exit("unknown variant " + how)
yaml.safe_dump(e, open(dst, "w", encoding="utf-8"), sort_keys=False)
PYEND
    lint "$exps/$1.yaml"
    expect 2 "$3" "$4"
  }
  lint_fails bad-metric chaos/experiments/gateway-pod-kill.yaml "probe gateway-availability: the metric no_such_total is not in the rules, the confirmed list, a dashboard or chaos/metrics-allowlist.txt" "a metric the platform does not have is named"
  lint_fails bad-expected-alert chaos/experiments/rollouts-controller-down.yaml "expectedObservations: the alert NoSuchAlert is not an alert of the rules" "an expected alert that does not exist is named"
  lint_fails bad-forbidden-alert chaos/experiments/gateway-pod-kill.yaml "mustNotFire: the alert AlsoNoSuchAlert is not an alert of the rules" "a forbidden alert that does not exist is named"
  lint_fails wider-namespace chaos/experiments/gateway-pod-kill.yaml "blastRadius.namespaces: data is not a namespace of the target (shop); only a drain may list more, as anyPodInNamespaces" "a blast radius wider than the target's namespace is named"
  lint_fails wider-selector chaos/experiments/gateway-pod-kill.yaml "blastRadius.selectors: 'app.kubernetes.io/part-of=sre-sample' is wider than the selector of the target" "a blast selector that the selector of the target does not contain is named"
  lint_fails more-pods chaos/experiments/gateway-pod-kill.yaml "blastRadius.maxPods: 3 is not what the injection touches (1)" "a maxPods above the count is named"
  lint_fails workload-on-pod-action chaos/experiments/gateway-pod-kill.yaml "blastRadius.workloads: a pod action has no workload to change; leave the list empty" "a workload in the blast radius of a pod action is named"
  lint_fails nodes-on-pod-action chaos/experiments/gateway-pod-kill.yaml "blastRadius.maxNodes: 1 is not what the injection touches (0)" "nodes in the blast radius of a pod action are named"
  lint_fails any-pod-without-drain chaos/experiments/gateway-pod-kill.yaml "blastRadius.anyPodInNamespaces: only a drain-node experiment evicts pods it did not select" "anyPodInNamespaces outside a drain is named"
fi

# --- the load helper ----------------------------------------------------------------------------------------------------------------

echo "chaos-load.sh"

load() {
  # load ARGS...: run the load helper against the fakes; the output is in $work/out and the status in $rc.
  rc=0
  PATH="$fakes:$PATH" FAKE_STATE="$state" FORBIDDEN_LOG="$work/forbidden.log" KUBECONFIG="$work/kubeconfig" ./scripts/chaos-load.sh "$@" > "$work/out" 2>&1 || rc=$?
}
# applied N: the JSON given to the Nth `kubectl apply -f -`.
applied() {
  python3 -c '
import json
import sys

n = int(sys.argv[2])
calls = [json.loads(l) for l in open(sys.argv[1]) if json.loads(l)["args"][:1] == ["apply"]]
print(json.dumps(json.loads(calls[n - 1]["input"])))
' "$state/kubectl.log" "$1"
}
jfield() { python3 -c 'import json, sys; o = json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2"; }

new_state
load start --duration 120
expect 0 "The load is running on the cluster multi-cloud-sre-dev: shop/chaos-load, about 2.0 requests a second, an order every 4 requests, for 120 seconds." "the load helper starts the load"
policy="$(applied 1)"
pod="$(applied 2)"
check "the policy is applied before the pod" test "$(jfield "$policy" 'o["kind"]')" = NetworkPolicy -a "$(jfield "$pod" 'o["kind"]')" = Pod
check "the policy lets only the load pod into the gateway, on its port, and nothing else in" test "$(jfield "$policy" '[o["spec"]["podSelector"]["matchLabels"], o["spec"]["policyTypes"], len(o["spec"]["ingress"]), o["spec"]["ingress"][0]["from"][0]["podSelector"]["matchLabels"]["app.kubernetes.io/name"], o["spec"]["ingress"][0]["ports"][0]["port"]]')" = "[{'app.kubernetes.io/name': 'gateway', 'app.kubernetes.io/instance': 'gateway'}, ['Ingress'], 1, 'chaos-load', 8080]"
check "the pod and the policy carry the label that --cleanup looks for" test "$(jfield "$policy" 'o["metadata"]["labels"]["chaos.platform.example/managed-by"]')" = chaos-load -a "$(jfield "$pod" 'o["metadata"]["labels"]["chaos.platform.example/managed-by"]')" = chaos-load
check "the pod runs as a non-root user, with the default seccomp profile, no privilege escalation, no capabilities and a read-only root filesystem" test "$(jfield "$pod" '[o["spec"]["securityContext"]["runAsNonRoot"], o["spec"]["securityContext"]["seccompProfile"]["type"], o["spec"]["containers"][0]["securityContext"]["allowPrivilegeEscalation"], o["spec"]["containers"][0]["securityContext"]["capabilities"]["drop"], o["spec"]["containers"][0]["securityContext"]["readOnlyRootFilesystem"], o["spec"]["automountServiceAccountToken"]]')" = "[True, 'RuntimeDefault', False, ['ALL'], True, False]"
check "it has requests and limits, lives in shop, and ends by itself 60 seconds after its loop" test "$(jfield "$pod" '[o["metadata"]["namespace"], sorted(o["spec"]["containers"][0]["resources"]), o["spec"]["activeDeadlineSeconds"], o["spec"]["restartPolicy"]]')" = "['shop', ['limits', 'requests'], 180, 'Never']"
digest="$(sed -n 's/.*busybox:1.37@\(sha256:[0-9a-f]*\).*/\1/p' docs/runbooks/network-policies.md | head -1)"
check "its image is the busybox pinned by digest in the network policy runbook and the progressive delivery runbook" test -n "$digest" -a "$(jfield "$pod" 'o["spec"]["containers"][0]["image"]')" = "docker.io/library/busybox:1.37@$digest" -a "$(grep -c "$digest" docs/runbooks/progressive-delivery.md)" -ge 1
check "the loop reads the orders and creates one with a new idempotency key" test "$(jfield "$pod" 'o["spec"]["containers"][0]["command"][2]' | grep -o -e '--post-data' -e 'Idempotency-Key: chaos-load-' -e 'http://gateway:8080/api/orders' | sort -u | wc -l | tr -d ' ')" = 3
check "its syntax is valid for sh" sh -n -c "$(jfield "$pod" 'o["spec"]["containers"][0]["command"][2]')"
# Run the loop with stubs for date, sleep and wget (an order every 2nd request instead of every 4th, to see one in three turns): it must stop at
# its end time and send a new key with each order.
mkdir -p "$work/stubs"
# shellcheck disable=SC2016 # the stubs are scripts: nothing in them is meant to expand here
printf '#!/bin/sh\nn=$(cat "$STUB_DIR/clock" 2>/dev/null || echo 0)\necho "$n"\necho $((n + 50)) > "$STUB_DIR/clock"\n' > "$work/stubs/date"
printf '#!/bin/sh\nexit 0\n' > "$work/stubs/sleep"
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "$*" >> "$STUB_DIR/wget.log"\n' > "$work/stubs/wget"
chmod +x "$work/stubs/date" "$work/stubs/sleep" "$work/stubs/wget"
rm -f "$work/stubs/clock" "$work/stubs/wget.log"
STUB_DIR="$work/stubs" PATH="$work/stubs:$PATH" sh -c "$(jfield "$pod" 'o["spec"]["containers"][0]["command"][2]' | sed 's/% 4)/% 2)/')" > /dev/null 2>&1 &
loop_pid=$!
for _ in $(seq 1 50); do
  kill -0 "$loop_pid" 2> /dev/null || break
  sleep 0.1
done
kill "$loop_pid" 2> /dev/null || true
check "the loop ends by itself when its time is up" test -s "$work/stubs/wget.log" -a "$(wc -l < "$work/stubs/wget.log" | tr -d ' ')" -le 6
check "it sent reads and at least one order, each order with its own key" test "$(grep -c -e '--post-data' "$work/stubs/wget.log")" -ge 1 -a "$(grep -c -v -e '--post-data' "$work/stubs/wget.log")" -ge 1 -a "$(grep -o 'Idempotency-Key: [^ ]*' "$work/stubs/wget.log" | sort -u | wc -l | tr -d ' ')" = "$(grep -c -e '--post-data' "$work/stubs/wget.log")"
load status
expect 0 "The load pod shop/chaos-load is there on the cluster multi-cloud-sre-dev" "status says the pod is there"
load start
expect 1 "the load pod shop/chaos-load is already there" "a second start is refused"
check "and nothing more was applied" test "$(grep -c '"args": \["apply"' "$state/kubectl.log")" = 2

# A chaos run does not mind the load helper; --cleanup finds both of its objects.
printf '%s\n' "$cluster" > "$work/stdin"
printf '%s\n' '{"probes":{"fake_availability":[0.999]},"page":[[]],"alerts":{}}' > "$state/prom.json"
chaos "$fx/t-delete-pod.yaml" --execute
expect 0 "Hypothesis HELD." "a chaos run goes ahead while the load helper is running"
chaos --cleanup
expect 0 "Nothing was changed. To revert these: chaos-run.sh --cleanup --execute" "cleanup lists what the load helper made"
check "it lists the pod and the policy of the load helper" test "$(grep -c -E '^  (pod|networkpolicy) .*chaos-load' "$work/out")" = 2
chaos --cleanup --execute
expect 0 "reverted networkpolicy chaos-load-to-gateway" "cleanup removes the policy of the load helper"
check "and the pod" test "$(cluster_query 'len([p for p in s["pods"] if p["name"] == "chaos-load"])')" = 0 -a "$(cluster_query 'len([n for n in s["networkpolicies"] if n["name"].startswith("chaos-")])')" = 0

load start --duration 120
load stop
expect 0 "The load is stopped on the cluster multi-cloud-sre-dev." "stop removes the pod and the policy"
check "nothing of the load helper is left" test "$(cluster_query 'len([p for p in s["pods"] if p["name"] == "chaos-load"]) + len([n for n in s["networkpolicies"] if n["name"].startswith("chaos-")])')" = 0
load status
expect 1 "No load pod on the cluster multi-cloud-sre-dev." "status after stop says there is none"

new_state
edit_cluster 's["context"] = "prod-eu-1"'
load start
expect 1 "the cluster 'prod-eu-1' does not match the pattern ^[a-z0-9-]+-dev\$: nothing was touched" "the load helper refuses a cluster that is not a dev cluster"
check "and applied nothing" test "$(grep -c '"apply"' "$state/kubectl.log")" = 0
new_state
edit_cluster 's["context"] = "arn:aws:eks:eu-north-1:123456789012:cluster/multi-cloud-sre-dev"'
load start
expect 0 "The load is running on the cluster multi-cloud-sre-dev" "a context that is an ARN is compared on the cluster name"
check "and the account in it is never printed" test "$(grep -c '123456789012' "$work/out")" = 0
new_state
load start --duration 59
expect 1 "--duration must be from 60 to 3600 seconds, not 59" "a duration below the minimum is refused"
load start --duration 3601
expect 1 "--duration must be from 60 to 3600 seconds, not 3601" "a duration above the maximum is refused: it cannot run on"
load start --interval 0.1
expect 1 "--interval must be from 0.2 to 5 seconds, not 0.1" "a faster load than the cluster should take is refused"
load start --order-every 0
expect 1 "--order-every must be from 1 to 100, not 0" "an order every zero requests is refused"
load start --duration abc
expect 1 "--duration must be a whole number of seconds, not 'abc'" "a duration that is not a number is refused"
check "none of them applied anything" test "$(changes)" = 0
edit_cluster 's["networkpolicies"].append({"name": "shop-default-deny", "ns": "shop", "labels": {}, "spec": {"podSelector": {}, "policyTypes": ["Ingress", "Egress"]}})'
load start
expect 1 "the network policy shop-default-deny selects the load pod for egress, so it could not reach the gateway" "a policy that would block the egress of the load pod stops the start"
check "and nothing was applied" test "$(grep -c '"apply"' "$state/kubectl.log")" = 0

# --- what must never happen ------------------------------------------------------------------------------------------------------

echo "chaos-run.sh: what never happens"

check "no run called aws, terraform or git" test ! -e "$work/forbidden.log"
check "no file of the repository was changed by the tests" test -z "$(find chaos scripts deploy platform docs -type f -newer "$marker" -not -name '*.pyc' -not -path '*/__pycache__/*' 2> /dev/null | head -1)"

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
