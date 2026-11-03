# chaos

Chaos experiments for the dev cluster, and the runner that keeps them safe. An experiment breaks one thing on purpose (a pod, a node, a dependency), watches the SLO series while it is broken, puts everything back, and records whether the system behaved as the hypothesis said. The reasoning, and what this approach cannot test, are in [ADR-0029](../docs/adr/0029-chaos-experiments.md). How to run a game day is in the [chaos runbook](../docs/runbooks/chaos.md).

**Nothing here has run on a cluster.** The runner has run against a fake `kubectl` and a fake Prometheus only (`scripts/chaos-tests.sh`), and every experiment has been dry-run and run against a simulated cluster. The first real run is a first-time check, and each experiment is written so that the first run can show its claim to be wrong.

## What is here

| Path | What |
| --- | --- |
| `experiments/` | One YAML file for each experiment: [the eleven below](#the-experiments) |
| `schema/experiment.schema.json` | The schema every experiment is checked against |
| `metrics-allowlist.txt` | Metric names a probe may use that no rule, dashboard or confirmed list has, each with its source |
| `templates/` | The [game day record](templates/game-day-record.md) and the [result summary](templates/result-summary.md) |
| `results/` | The results of runs: a JSON file and a Markdown summary for each. **Ignored by Git** and kept on the machine that ran them |
| [`scripts/chaos-run.sh`](../scripts/chaos-run.sh), [`chaos-run.py`](../scripts/chaos-run.py) | The runner: a thin shell wrapper and the Python that does the work |
| [`scripts/chaos-load.sh`](../scripts/chaos-load.sh) | The load helper the experiments need |
| [`scripts/chaos-lint.py`](../scripts/chaos-lint.py) | The lint of the experiments against the rules, the metrics and their blast radius |
| [`scripts/chaos-tests.sh`](../scripts/chaos-tests.sh), [`chaos-check.sh`](../scripts/chaos-check.sh) | The tests and the check that CI runs (`make chaos-check`) |
| `scripts/tests/fakes/chaos/`, `scripts/tests/fixtures/chaos/` | The fake `kubectl` and Prometheus and the fixtures of the tests |

## The experiments

In the order of the first real run, from the safest to the riskiest. Each file has a header that names the ADR or runbook section whose claim it tests.

| # | Experiment | What it does | What a failure would mean |
| --- | --- | --- | --- |
| 1 | `gateway-pod-kill` | Deletes one gateway pod under load | Requests are lost when a gateway pod goes: the shutdown sequence or the readiness gate does not do what the ADRs say |
| 2 | `payments-pod-kill` | Deletes one of the two payments pods | Payments is a single point of failure in practice |
| 3 | `rollouts-controller-down` | Scales the Argo Rollouts controller to zero for twelve minutes | The traffic depends on the controller, or the alert `RolloutsControllerDown` does not notice it is gone |
| 4 | `eso-down` | Scales the External Secrets Operator controller to zero (external secrets mode only) | A pod depends on the operator at run time, or restarts when its Secret is touched |
| 5 | `kyverno-admission-down` | Scales the Kyverno admission controller to zero | A webhook fails closed, and nothing can be created while Kyverno is down |
| 6 | `valkey-down` | Scales Valkey to zero | Valkey is on the request path after all, and orders waits for it |
| 7 | `isolated-gateway-pod` | Cuts one gateway pod off the network | Traffic still reaches the cut-off pod, or the other replica cannot carry the load |
| 8 | `orders-pod-kill-under-load` | Deletes one orders pod while orders are being created | An accepted order is lost or notified twice, or the outbox does not drain |
| 9 | `rabbitmq-pod-kill` | Deletes the RabbitMQ pod | Events are lost or dead-lettered when the broker goes, or orders stops accepting orders without it |
| 10 | `postgres-primary-failover` | Deletes the PostgreSQL primary pod | The failover is slower than two minutes, or the services do not reconnect without a restart |
| 11 | `node-drain` | Drains one node (needs four nodes) | The capacity numbers are wrong and pods stay Pending, or a budget blocks the drain |

All of them need the load helper running, and a probe on the request rate checks it. The four that scale a workload need Argo CD paused for that workload first ([Argo CD](#argo-cd)).

## Run an experiment

You need `kubectl` with a context for a **dev cluster**, Python with PyYAML (installing `yamllint` provides it), and nothing else: no AWS credentials, no Terraform. In the commands, the experiment is `gateway-pod-kill`.

```bash
# 1. Start the load. Every experiment's probes are about requests.
scripts/chaos-load.sh start

# 2. Check the file (what CI does for every file under chaos/experiments).
scripts/chaos-run.sh --validate chaos/experiments/*.yaml

# 3. The dry run, which is the default: it prints the plan and changes nothing. It reads only the name of the kubectl context.
scripts/chaos-run.sh chaos/experiments/gateway-pod-kill.yaml

# 4. The real run. It prints the plan again, then asks you to type the name of the cluster. There is no --yes.
scripts/chaos-run.sh chaos/experiments/gateway-pod-kill.yaml --execute

# 5. Stop the load.
scripts/chaos-load.sh stop
```

### The load helper

`scripts/chaos-load.sh start` makes one pod, `chaos-load`, in the `shop` namespace, and a NetworkPolicy that lets only that pod into the gateway (the gateway's own policy lets in only Prometheus). The pod has the restricted security settings, the busybox that the [network policy runbook](../docs/runbooks/network-policies.md) pins by digest, and a deadline of its own. It sends `GET /api/orders` about twice a second and creates an order every fourth request (`POST /api/orders` with a new `Idempotency-Key`), which is about half an order a second: it creates real orders in PostgreSQL, so the outbox and the notifier have work. It stops by itself after `--duration` seconds (1800 by default, 3600 at most). `stop` removes both objects, and `chaos-run.sh --cleanup` finds them if you forget. It refuses a cluster that is not a dev cluster. Its network side was read from the policies and not seen on a cluster: the load pod is selected by no policy of its own, so its egress is open, and the script refuses to start if a policy of the namespace would select it for egress.

### What a run does

1. **Checks the cluster.** The kubectl context must name a cluster that matches `preconditions.clusterNamePattern`, which must contain `dev`. Only the cluster name is compared and printed; an account number in an EKS context is never shown.
2. **Checks the preconditions.** Enough ready nodes, enough ready replicas of the target, no page alert firing, and no leftover of an earlier run (the load helper is not one).
3. **Checks the steady state.** Every probe that applies before the injection must pass. A red steady state means nothing is injected.
4. **Injects.** One typed action. Its rollback is registered before it changes anything.
5. **Watches** for the duration, every `CHAOS_TICK_SECONDS` (5 by default). A probe failing for longer than `abort.probeFailureGraceSeconds`, or **any page alert**, aborts the run. An alert in `mustNotFire` that fires makes the hypothesis fail. For an action that leaves a state behind (a scaled-down workload, a cordoned node, a deny policy) the run also checks every tick that the state is still there.
6. **Rolls back, always:** after success, after an abort, after an error, and on SIGINT, SIGTERM and SIGHUP.
7. **Waits for recovery** (up to `rollback.timeoutSeconds`), checks the steady state again and writes the result.

The exit status: `0` the run finished and the hypothesis held; `1` the run was refused, or its rollback failed; `2` the file or the command line is not valid; `4` the run finished and the **hypothesis did not hold**, a finding and not a failure of the tool; `5` the run finished but **proved nothing**, because the injection was undone from outside while it ran; `130`, `143` and `129` an interrupted run (the rollback ran).

### Argo CD

Argo CD with `selfHeal` (every Application of this platform has it) puts a replica count back within seconds. So `scale-to-zero` on a workload that Argo CD manages would be undone almost at once, and the run would prove nothing. Two rules follow:

- **The runner refuses** to scale a workload that carries the Argo CD tracking annotation unless it can read the Application and finds that it does not self-heal, or is paused with the annotation `argocd.argoproj.io/skip-reconcile: "true"`.
- **A run notices** when the injection stops holding (the workload is no longer at zero), says so, rolls back and exits with `5`.

To pause an Application for a run, and to resume it afterwards (the four applications are `data-valkey-in-cluster`, `policy-kyverno-in-cluster`, `eso-operator-in-cluster` and `delivery-argo-rollouts-in-cluster`):

```bash
kubectl --context <CTX> -n argocd annotate application data-valkey-in-cluster argocd.argoproj.io/skip-reconcile=true
# ... run the experiment ...
kubectl --context <CTX> -n argocd annotate application data-valkey-in-cluster argocd.argoproj.io/skip-reconcile-
```

The Applications are made by ApplicationSets, which overwrite what is not in their template, so the four ApplicationSets list that annotation in `preservedFields`. That is a change to the platform made for the experiments, and it is **not yet seen to work**: Argo CD documents the annotation as alpha, and says that all processing of the Application stops, which should include self-heal; that is read from its documentation and not tried. If the run still ends with `5`, the Application was not paused. **Resume the Application when you are done**: it stays paused until the annotation is removed.

### Where the results go

`chaos/results/<experiment>-<run id>.json` and `.md` (change the folder with `--results-dir`). They hold the timings of each phase, the value of every probe before, during and after, every change made to the cluster, which of the expected alerts were seen firing, which of the alerts that must not fire did, whether the run was aborted and why, the rollback, whether the system recovered, and whether the hypothesis held. A run that is refused before it injects writes nothing. The [result summary template](templates/result-summary.md) shows what the Markdown looks like, and the [game day record](templates/game-day-record.md) is where a game day copies what it wants to keep.

### The safety rules

- A dry run is the default; a real run needs `--execute` **and** the cluster name typed in full.
- The cluster is identified by its name only, and must match the dev pattern of the experiment.
- Every change is checked against the experiment's **blast radius** (namespaces, label selectors, workloads, the most pods and nodes) before it is made, using the labels of the objects the cluster returns. Anything else is refused, and named.
- `kubectl delete` is used only on a pod, or on a network policy, that passed that check.
- It never calls AWS, Terraform or Git, and edits no file but its results.
- Everything it makes or changes is labelled `chaos.platform.example/managed-by=chaos-run` (the load helper `chaos-load`), with the run and the experiment; the replicas it changes are kept in an annotation.

### Leftovers

If a run is killed in a way it cannot catch (SIGKILL, a lost terminal, a power cut), something may be left: a deny policy, a workload at zero replicas, a cordoned node. The next run **refuses to start** while a leftover exists. Find and revert them:

```bash
scripts/chaos-run.sh --cleanup                      # lists what an earlier run, or the load helper, left in the namespace shop and on the nodes
scripts/chaos-run.sh --cleanup --execute            # reverts it, after you type the cluster name
scripts/chaos-run.sh --cleanup --namespace data     # another namespace (repeat the flag for more)
```

`--cleanup` does not resume anything in Argo CD: remove the `skip-reconcile` annotation yourself. (`scripts/teardown-prep.sh` and `scripts/teardown-argocd.sh` remove it from every Application before they wait for or delete them, because a paused Application is not processed, deletion included, and they delete the load helper's pod and policy; they only warn about the other leftovers. See the [runbook](../docs/runbooks/chaos.md#teardown).)

## The actions

| Action | What it does | Rollback | Notes |
| --- | --- | --- | --- |
| `delete-pod` | Deletes `count` ready pods that match the selector | waits until as many pods are ready as before (those that match `readySelector`, if it is set) | `count` is at most `blastRadius.maxPods`. For a database cluster, the target can be the primary and the ready selector the whole cluster |
| `drain-node` | Cordons and drains `count` nodes that run a target pod, skipping a node that runs a pod of `avoid` | uncordons them and waits for the pods | refuses a node where the drain would evict a pod outside the blast radius, in any namespace (`blastRadius.anyPodInNamespaces` makes a whole namespace part of it); needs `minReadyNodes` of at least `count` + 1 |
| `scale-to-zero` | Scales a Deployment or StatefulSet to zero | restores the replica count kept in an annotation | refuses a workload that an autoscaler drives, and one that Argo CD would put back ([Argo CD](#argo-cd)) |
| `apply-network-deny` | Cuts `count` pods off the network | deletes the policy and the isolated pods | a NetworkPolicy cannot take away what another policy allows, so the pod is taken out of reach of the other policies (labels removed, a new pod starts) and a deny policy selects it; refuses if a policy would still select it. See the ADR |

The set is closed: a new action is a change to the runner with its tests, and each action has a rollback that the schema makes mandatory. There was a fifth, `set-gateway-fault`, which set the gateway's fault variables. It was removed: the gateway is a Rollout in the data profile, and Argo CD restores any manual change. A bad release is tested through a pull request instead, as the [progressive delivery runbook](../docs/runbooks/progressive-delivery.md#a-bad-release) describes.

## Add an experiment

1. Copy the nearest experiment to `chaos/experiments/<name>.yaml`. **The file name is the experiment name.**
2. Write one line of **hypothesis** that a result can prove wrong, tie it to a claim in an ADR or a runbook (say which, in the header), and link it to the SLO or the alert it is about (`relatesTo`).
3. Declare the **blast radius**: the namespaces, the label selectors, the workloads and the most pods and nodes. The target of the injection must lie inside it, and the blast radius must be no wider than the injection (the lint checks that).
4. Write the **steady-state probes** as PromQL instant queries that return one number, with a comparator and a threshold. Use series that exist: the SLO series ([`platform/observability/monitors`](../platform/observability/monitors)), and the metrics the lint accepts. Say what no data means (`noData`, default `fail`). A probe on a series that the injection takes away has to apply `before` and `after` only (`phases`). Include a probe on the request rate, so the run refuses when the load helper is not running.
5. Choose the **injection** and its **rollback** (the one that undoes it, see the table), the duration, the abort rule, the alerts you expect to fire (`expectedObservations`) and those that must not (`mustNotFire`).
6. Check it: `scripts/chaos-run.sh --validate chaos/experiments/<name>.yaml`, `make chaos-check`, then the dry run.

CI validates every file under `chaos/experiments` against the schema and the rules across its fields, and lints it: every metric is one the platform has (the rules, the confirmed upstream list, a dashboard, or `metrics-allowlist.txt`), every alert exists, every probe parses in promtool, and the blast radius is no wider than the injection. Every experiment is also dry-run and run against a simulated cluster in the tests.

## Test the runner

```bash
make chaos-check            # validates and lints the experiments, runs the tests, yamllint and shellcheck
scripts/chaos-tests.sh      # only the tests
```

The tests use a fake `kubectl` (a small simulated cluster that can delete pods, cordon and drain, scale, label and apply a policy, with a database cluster that promotes a replica and Argo CD Applications) and a fake Prometheus whose answers are scripted, so a test can make a probe go bad at a chosen read. The real `kubectl` can not be reached: the `PATH` starts with the fake, `KUBECONFIG` is an empty file, the first test checks that the kubectl found is the fake, and `aws`, `terraform` and `git` are poisoned. The tests need no network and no chart (the lint renders the local monitors chart, which has no dependency).

What the fake cannot do: it does not schedule by resources, does not enforce a PodDisruptionBudget (a drain always succeeds at once), does not know that a primary pod's drain waits, does not run Argo CD (the Application is a record whose answer the test decides), and its Prometheus returns the numbers a test scripted, not the numbers a cluster would. So a pass against the fake proves that the runner does what it says, not that the platform survives.
