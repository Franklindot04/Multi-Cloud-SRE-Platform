# ADR-0029: Chaos experiments with native Kubernetes operations

- Status: Accepted
- Date: 2026-11-03

## Context

The platform has been designed to survive failures: pod budgets, spread and priority classes ([ADR-0026](0026-resilience-and-autoscaling.md)), a second PostgreSQL instance, a canary that stops a bad release ([ADR-0028](0028-progressive-delivery.md)), and alerts on the SLOs ([ADR-0023](0023-slos-and-alerting.md)). **None of it has been shown to work on a cluster.** The runbooks list what is unproven (the drain, the failover, the autoscaler under load, the abort of a canary), and the apply-session checklist asks someone to look. Looking is not the same as breaking something on purpose and measuring what the users would have seen.

This change is the framework for doing that: how an experiment is written, a runner that keeps it safe, the tests of the runner and a workflow. The experiments themselves, the runbook and the game day template come in the next step. **Nothing here has run on a cluster.** The runner has run against a fake kubectl and a fake Prometheus only.

The constraints come from what the platform already is:

- The `shop` namespace enforces the Pod Security level `restricted`, Kyverno audits it, and every pod is behind a default-deny network policy ([ADR-0024](0024-network-policies.md), [ADR-0025](0025-admission-policies.md)). Anything we add that needs more than that is a hole we have to explain.
- The cluster is a Spot-backed dev cluster that is created and destroyed per session, on a small budget.
- Prometheus is in `observability`, and its network policy lets in only the pods that have a reason to call it.

## Decision

Experiments use native Kubernetes operations, driven from the engineer's machine by a runner script. There is no chaos operator in the cluster.

### Why not an operator

| | Chaos Mesh | LitmusChaos | AWS Fault Injection Service |
| --- | --- | --- | --- |
| Version read on 2026-11-03 | v2.8.7, released 2026-10-28 ([releases](https://github.com/chaos-mesh/chaos-mesh/releases)) | 3.33.0, released 2026-10-15 ([releases](https://github.com/litmuschaos/litmus/releases)); CNCF incubating since January 2022, graduation not confirmed | managed service, no version |
| What runs in the cluster | the controller, a dashboard, and `chaos-daemon` on every node | a control plane and an agent, and for each fault a runner and helper pods | no operator; for pod actions FIS creates a fault orchestration pod and ephemeral containers in the target namespace |
| Privileges | the chart runs `chaos-daemon` **privileged by default**, with the runtime socket of the node (`runtime` and `socketPath` in the chart's [values](https://github.com/chaos-mesh/chaos-mesh/blob/master/helm/chaos-mesh/values.yaml), docker by default, containerd and CRI-O as options). Not privileged, it adds `SYS_ADMIN`, `NET_ADMIN`, `SYS_PTRACE`, `MKNOD`, `SYS_CHROOT`, `KILL` and others | a fault definition for network latency ([chaos-charts](https://github.com/litmuschaos/chaos-charts/blob/master/faults/kubernetes/pod-network-latency/fault.yaml)) names the container runtime and the containerd socket path, and a Role that creates and deletes pods and Jobs and executes in pods. I could not confirm from the definitions whether its helpers run privileged | the service role and a Kubernetes service account with rights in the target namespace. `fisPodSecurityPolicy` sets the Pod Security level of FIS's pods to `privileged`, `baseline` or `restricted` ([actions reference](https://docs.aws.amazon.com/fis/latest/userguide/fis-actions-reference.html)); the documentation says one action works at every level, and for others it lists `privileged` and `baseline` only |
| Fit with `restricted` | a privileged DaemonSet with host access cannot run in `shop`; it would need its own namespace at the `privileged` level and an exemption in every policy that names `shop` | the same for any fault that uses the node's socket | the pod actions that need the `restricted` level are few; the network and stress actions need more |
| Fit with Kyverno and the network policies | the daemon and the controller need rules in both; a fault that blocks traffic acts below the CNI's policies | the same | FIS pods in `shop` need allow rules for what they do |
| Cost | the nodes' CPU and memory for a DaemonSet and a controller, on a cluster that is tight on CPU when one node is lost ([resilience runbook](../runbooks/resilience.md#capacity)) | a control plane that is itself an application to run | $0.10 per action-minute, whatever the action ([pricing](https://aws.amazon.com/fis/pricing/)), plus the IAM roles to review |
| What it can do that we cannot | kernel-level network faults (latency, loss, partition between two services), CPU and memory stress, disk faults, DNS faults, clock skew | the same family, and a catalogue of faults | `aws:ec2:send-spot-instance-interruptions` (a real two-minute notice), `aws:eks:terminate-nodegroup-instances`, `aws:network:disrupt-connectivity`, `aws:eks:pod-network-latency`, `pod-network-packet-loss`, `pod-cpu-stress`, `pod-memory-stress` |

Three reasons decide it.

- **The privilege is the cost.** The platform gets its security from the `restricted` level, from audit policies and from default-deny network policies. An operator whose daemon runs privileged on every node, with the runtime socket, is the most privileged thing in the cluster, and it would be installed to break things on purpose. For the faults we need now it is not needed.
- **What we want to know is about Kubernetes behaviour.** Does a pod budget keep a pod up in a drain? Does the Service stop sending to a deleted pod before it dies? Does the canary abort? Do the alerts fire? These are answered by pod deletes, drains, scaling a dependency to zero and the fault settings the gateway already has. They need no kernel access.
- **A runner on the engineer's machine has no standing presence.** Nothing is left in the cluster between experiments, nothing needs an upgrade, and the rights are the engineer's own.

### What this design cannot test

Said plainly, because it is easy to over-claim:

- **Network faults between services.** A NetworkPolicy cannot take away what another policy allows: the rules add up, and every pod of this platform has allow rules. So `apply-network-deny` does not add a deny and hope. It adds a deny policy that selects nothing, then takes **one pod** out of reach of the other policies by removing its labels (which also removes it from its ReplicaSet, a new pod starts, and from the Service), and the deny policy selects the one label it is given. That tests a pod that is cut off from the network, not a slow or lossy link, not a partition between two services and not a blocked port.
- **Latency, loss, CPU, memory, disk and clock faults.** The only faults on the request path are the gateway's own (`FAULT_ERROR_RATE`, `FAULT_LATENCY_MS`), which need a change of the pod template.
- **A real Spot interruption.** A drain is a polite eviction with a grace period. A Spot reclaim gives two minutes and then the node is gone, with no eviction of the pods. The budgets are not consulted.
- **Failures of AWS itself:** a zone, the NAT gateway, a load balancer.
- **The failure of a node with its pods still running on it.** The `drain-node` action cordons and evicts. It does not make a node unreachable.

A later step could add the AWS Fault Injection Service for the Spot interruption and the node termination (it needs a role, a template and a cost, and nothing in the cluster), and Chaos Mesh, if it is ever wanted, in a namespace of its own at the `privileged` level with exemptions that are written down, for the network faults. That is a separate decision and this one does not make it.

### The experiment format

One YAML file for each experiment under `chaos/experiments`, checked by `chaos/schema/experiment.schema.json` and by rules that cross fields. The file name is the experiment name. The fields are:

- `hypothesis` (one line), `relatesTo` (the SLO or alert), and `blastRadius`: namespaces, label selectors, workloads, the most pods and the most nodes it may touch.
- `preconditions`: a cluster name pattern that must contain `dev`, the least number of ready nodes, the least replicas of the target, and no page alert firing.
- `steadyState`: probes, each a PromQL instant query with a comparator and a threshold and what to do with no data. They are evaluated before, during and after.
- `injection`: one of four typed actions (below), a `duration`, a mandatory `rollback`, `abort` conditions, `expectedObservations` (alerts that should fire) and `mustNotFire` (alerts that must not). A probe may apply only `before` and `after` (`phases`), which is how a probe on a series that the injection takes away is written.

The rollback is required by the schema, and the runner checks that it undoes the injection (`delete-pod` waits for the pods to be ready, `drain-node` uncordons, `scale-to-zero` restores the replicas, `apply-network-deny` removes the policy and the isolated pod). The abort conditions are a probe failing for longer than a grace period, and **any** page alert; the second cannot be turned off.

### The closed set of actions

`delete-pod`, `drain-node`, `scale-to-zero` and `apply-network-deny`. It is closed so that every action has a rollback that is written, tested and bounded by a blast radius. A new action is a code change to the runner, with its tests, and an ADR if it needs a new kind of right.

- `scale-to-zero` refuses a workload that an autoscaler drives (it would undo the experiment). The original count is kept in an annotation on the workload, with labels that mark it.
- `drain-node` picks nodes that run a target pod, and **refuses a node on which the drain would evict a pod outside the blast radius**, in any namespace, because a drain does not look at namespaces. DaemonSet pods are left alone, as the drain leaves them.
- **Argo CD and `scale-to-zero`.** Every Application of the platform self-heals, which puts a replica count back within seconds, so a workload that Argo CD manages would be scaled up again almost at once and the run would prove nothing. The runner reads the Application named in the tracking annotation of the workload and **refuses** unless it does not self-heal or is paused with the annotation `argocd.argoproj.io/skip-reconcile`. The four ApplicationSets of the workloads the experiments scale list that annotation in `preservedFields`, because an ApplicationSet overwrites what its template does not have. And every tick the run checks that the injection still holds; when it does not, the run stops, rolls back and exits with `5`, "proved nothing". That the annotation really pauses the self-heal is read from Argo CD's documentation (alpha, "all processing is stopped") and is **not seen**.
- **Why there is no `set-gateway-fault`.** The first version of the framework had a fifth action that set the gateway's fault variables (`FAULT_ERROR_RATE`, `FAULT_LATENCY_MS`). It was removed. In the data profile with `--enable-progressive-delivery` the gateway is a Rollout, and an environment change on a Rollout is a new revision: a canary, which is the progressive delivery test and not a chaos experiment. On a Deployment Argo CD restores the change within seconds. A bad release is tested through a pull request, as the [progressive delivery runbook](../runbooks/progressive-delivery.md#a-bad-release) describes.
- **`delete-pod`** may name a `readySelector`, the pods that must be ready again before the rollback is done (for a database cluster the target is its primary and the pods to wait for are the whole cluster). **`drain-node`** may name pods to `avoid` (the node of Prometheus, which the probes read), and the blast radius may list `anyPodInNamespaces`, whole namespaces whose pods a drain may evict whatever their labels.
- `apply-network-deny` is described above.

### The runner

`scripts/chaos-run.sh` is a thin wrapper around `scripts/chaos-run.py`. The repository's helpers for this kind of work are Python (the contract checks, the policy test inputs), and the orchestration scripts are shell. The runner needs to parse YAML and a schema, ask Prometheus over HTTP, hold the state of a run and, above all, keep a rollback that survives a signal, an error and a half-done injection. Shell does none of that well. The wrapper only finds a Python with PyYAML (`scripts/python-with-yaml.sh`) and executes it, so a signal goes straight to the runner.

The safety rules, each tested in `scripts/chaos-tests.sh`:

- **A dry run is the default.** It validates the file, prints the plan (what would be touched, the rollback, the abort rule) and reads nothing from the cluster but the name of the context.
- **A real run needs `--execute` and the cluster name typed in full,** like `--purge` in `scripts/seed-secrets.sh`. There is no `--yes`.
- **The cluster is checked by name.** The kubectl context must name a cluster that matches the experiment's pattern, and only that name is ever printed. An EKS context is often an ARN with the account number in it; the part after the last slash is the name, and the rest is never shown. Every call uses `--context` with the checked context, so nothing can switch under it.
- **Every change is checked against the blast radius first,** in code: the namespace, the labels of the object the cluster returned (not the ones the experiment hoped for), the workload list, the nodes it has verified. A pod that comes back from the cluster and matches no selector is refused and named.
- **The order is fixed:** preconditions (including no leftover of an earlier run), the steady state (red means no injection), the injection, the watch, the rollback, the recovery and the steady state again. Each action registers its rollback **before** it changes anything.
- **The rollback always runs:** after success, after an abort, after an error, and on SIGINT, SIGTERM and SIGHUP. Signals are ignored while it runs. If it fails the run says so and exits 1, and `--cleanup` finds what is left.
- **No credentials.** It never calls AWS, Terraform or Git, and changes no file but its result files. The tests put poisoned commands for those on the PATH.

An experiment that breaks the hypothesis is a **finding**, not an error: the run ends with the exit status 4, and the result says what happened. The exit status 1 is a refusal or a failure of the run itself.

### How the runner reads Prometheus

The three ways are `kubectl port-forward`, the API server's service proxy and a throwaway pod.

- The **API server proxy** reaches the Prometheus pod from the API server's network interfaces in the VPC. The network policies of `observability` let Prometheus receive only from the pods that have a reason to ask (Grafana, the operator, the Argo Rollouts controller) and none from the VPC range, so the proxy would be dropped on EKS.
- A **throwaway pod** needs a policy that lets it in, and so a change to the policies for the sake of the tool, and a pod in a namespace at the `restricted` level with an image.
- **`kubectl port-forward`** enters the pod from the node, through the kubelet, and the network policy agent does not filter it (the same fact the service chart relies on for its probes and the port-forward in the runbooks). It needs `pods/portforward` on the engineer's own rights and nothing else.

The runner uses `kubectl port-forward` to the Prometheus Service on a free local port. This is read from the policies and not seen on a cluster.

### Results

Each run writes a JSON file and a short Markdown summary to `chaos/results`, which Git ignores: the timings of each phase, the probe values before, during and after, the changes made, which expected alerts fired, whether it was aborted and why, the rollback, whether the system recovered, and whether the hypothesis held. They are kept on the machine that ran them; a game day copies what it wants into a postmortem.

### Leftovers

Every object an experiment makes or changes carries the label `chaos.platform.example/managed-by=chaos-run`, with the run and the experiment, and the original replica count is kept in an annotation. The load helper has its own value of the label, `chaos-load`, so that a run does not take it for a leftover and `--cleanup` still finds it. `chaos-run.sh --cleanup` lists what it finds in the given namespaces and on the nodes, and with `--execute` and the typed cluster name reverts it.

### The experiments

Eleven experiments in [`chaos/experiments`](../../chaos/experiments), each a claim from an ADR or a runbook that has not been shown on a cluster. They are written so that the first run can falsify the claim; the answer is not in the file. In the order of the first run, safest first:

| Experiment | The claim it tests | Source |
| --- | --- | --- |
| `gateway-pod-kill` | One gateway pod can go under load without the availability and latency SLOs leaving their objectives | [ADR-0026](0026-resilience-and-autoscaling.md), [ADR-0016](0016-service-deployment-model.md) |
| `payments-pod-kill` | One of the two payments pods can go without the gateway availability leaving its objective | ADR-0026 |
| `rollouts-controller-down` | With the controller gone for twelve minutes the traffic is unaffected and `RolloutsControllerDown` fires | [ADR-0028](0028-progressive-delivery.md) |
| `eso-down` | With the External Secrets Operator gone the Secrets keep working and nothing restarts (external mode only) | [ADR-0027](0027-external-secrets.md) |
| `kyverno-admission-down` | With the admission controller gone the webhooks fail open and the services are unaffected | [ADR-0025](0025-admission-policies.md) |
| `valkey-down` | Without Valkey, orders falls back to PostgreSQL and the SLOs hold | [ADR-0015](0015-service-data-integration.md), [ADR-0014](0014-data-layer.md) |
| `isolated-gateway-pod` | A cut-off gateway pod is not Ready, leaves the Service, and the others serve | [ADR-0024](0024-network-policies.md), ADR-0026 |
| `orders-pod-kill-under-load` | No order is lost or notified twice when an orders pod dies, because of the outbox | ADR-0014, ADR-0015 |
| `rabbitmq-pod-kill` | Notifications are delayed and not lost when the broker goes | ADR-0015, [resilience runbook](../runbooks/resilience.md) |
| `postgres-primary-failover` | The replica is promoted within two minutes and the gateway availability stays above 0.95 | ADR-0026 |
| `node-drain` | With four nodes a drain leaves room for every pod and no budget blocks | ADR-0026, resilience runbook |

The probes use series that exist: the SLO series of the gateway, the outbox and notifier series of the services, kube-state-metrics, and the controller's own metrics. One probe counts the ExternalSecret series of the operator, whose labels its documentation does not list. A probe is never written against a metric that does not exist; the lint (`scripts/chaos-lint.py`) fails on a name that no rule, dashboard, confirmed list or allow list has, on an alert that is not in the rules, and on a blast radius wider than the injection, and promtool parses every query. The experiments need a request load, which `scripts/chaos-load.sh` provides: one throwaway pod in `shop` with the restricted settings and a temporary policy for the gateway, about two requests a second and an order every fourth, which stops by itself.

## Alternatives considered

- **Chaos Mesh or LitmusChaos.** See the table. Not chosen for now: the privileges, and the faults they add (network, stress) are not what we need to learn first. Not rejected for good.
- **The AWS Fault Injection Service.** The only way to a real Spot interruption. It costs per action-minute, needs roles that have to be reviewed, and nothing in the cluster. A good next step for that one question, and a different tool from this one.
- **Commands from a runbook, by hand.** What the resilience runbook has now. It has no hypothesis, no probes, no abort, and no rollback if the engineer is interrupted. The runner is that runbook with the safety on.
- **A shell script per experiment.** Each would have to get the confirmation, the context check, the rollback and the signals right on its own.
- **Chaos Toolkit or another general framework.** It would bring the format and the runner, and a dependency, for four actions. The format here is small enough to read in a minute.

## Consequences

- **Experiments are cheap and leave nothing behind,** but they are limited to what Kubernetes itself can do, which is said above.
- **The runner is the most dangerous script in the repository,** because it changes a live cluster. It is kept small, its actions are a closed set, and it is tested against a fake that the tests can make misbehave. It has still never touched a real cluster.
- **A dev cluster only.** The pattern must contain `dev`, and the name is typed.
- **Four of the experiments need Argo CD paused** for the workload they scale to zero, and the pause is by hand and unproven.
- **Some claims can only be half tested.** The experiments say in their headers what they do not measure: acknowledged writes lost in a failover, a proper count of orders against notifications, the admission of a new pod, a rollout stalling. A pass on those is weak evidence.

## What is proven and what is not

Proven offline, by `scripts/chaos-tests.sh` against a fake kubectl and a fake Prometheus: the schema rejects a missing rollback, a missing blast radius, an unknown action, a threshold without a comparator and the other cases in the tests; the dry run changes nothing and reads nothing; a wrong cluster name, a wrong confirmation, a failed precondition and a red steady state each refuse; a probe failing during the run and a page alert abort and roll back; SIGINT, SIGTERM and SIGHUP during an injection still roll back; a target outside the declared selectors, and a drain that would evict outside the blast radius, are refused; the cleanup reverts a leftover network policy, a scaled-down workload, an isolated pod and a cordoned node; every experiment is dry-run and run to the end against a simulated cluster (Postgres with a primary and a replica, Valkey, RabbitMQ, Kyverno, the External Secrets Operator, the Rollouts controller, Argo CD Applications, four nodes) and leaves it as it was; an injection that Argo CD would put back is found and the run is marked not valid; the load helper makes the pod and the policy it should and `--cleanup` removes them; the lint rejects a metric that does not exist, an alert that does not exist and a blast radius wider than the injection.

**Not proven, and not testable offline:**

- That `argocd.argoproj.io/skip-reconcile` pauses the self-heal of an Application made by an ApplicationSet, and that `preservedFields` keeps it.
- Everything on a real cluster: that `kubectl port-forward` to Prometheus works as read here, that the drain behaves as the fake does, that the RBAC of the engineer is enough.
- That removing the labels of a pod takes it out of its ReplicaSet and its Service and out of the reach of the allow policies on the VPC CNI. That is how Kubernetes documents it, and the policy agent's behaviour is not seen.
- That a deleted pod is replaced and ready within the rollback timeout of each experiment.
- What Argo CD does to the changes the actions make (a scaled-down Deployment is a drift that self-heal reverts).
- The probes' queries on real traffic. The experiments need load, and say so.
- The versions and the privileges in the comparison were read from the projects' pages on 2026-11-03. The Litmus helper privileges could not be confirmed.
