# Chaos experiments

How to run the chaos experiments of [`chaos/experiments`](../../chaos/experiments) on a dev cluster, in what order, what to watch while each one runs, what to do when a hypothesis fails or a rollback does not finish, and where the findings go. The framework, the format and what it cannot test are in [ADR-0029](../adr/0029-chaos-experiments.md) and the [chaos README](../../chaos/README.md).

**None of this has been run on a cluster.** The runner and every experiment have run against a fake `kubectl` and a fake Prometheus only. Every expectation below comes from the ADRs and runbooks the experiments test, which is the point: each one is a claim that has not been shown. The first game day is a first-time check of the runner as much as of the platform, and a surprise from the runner is a finding too. Write down what differs.

## Purpose and safety rules

An experiment breaks one thing on purpose, measures the SLO series while it is broken, puts it back, and says whether the hypothesis held. The rules, kept by the runner and tested offline:

- **Dev clusters only.** The cluster name must match the pattern of the experiment (it must contain `dev`), and you type the name to go on. There is no `--yes`.
- **A dry run first, always.** It prints the plan and changes nothing.
- **A tight blast radius,** checked in code before every change.
- **Any page alert aborts the run** and rolls back at once. A probe failing for longer than its grace period does the same.
- **The rollback always runs,** including on Ctrl-C, SIGTERM, an error and an abort.
- **Everything is labelled** `chaos.platform.example/managed-by`, so a leftover can be found and removed.
- **No AWS credentials and no Terraform.** Only `kubectl`.
- **Not in a production cluster,** and not while someone else is using the dev cluster for something that matters.

## Prerequisites for a run

All of these are **not run**. In every command `<CTX>` is the kubectl context of the dev cluster.

1. **An apply session with four nodes.** `node_desired_size = 4` in the local `terraform.tfvars`, as the [resilience runbook](resilience.md#apply) recommends. The node drain needs four; three are tight when one is lost. Check: `kubectl --context <CTX> get nodes` shows four Ready.
2. **The bootstrap flags that put everything in place:** `--enable-policy --enable-external-secrets --enable-progressive-delivery --enable-data --enable-observability --enable-apps --apps-profile data`. The experiments need the data profile (PostgreSQL, Valkey, RabbitMQ), the observability layer (the probes read Prometheus), Kyverno, the External Secrets Operator in its external mode (only for `eso-down`) and the Argo Rollouts controller (the gateway is a Rollout). The checks of the [apply session](progressive-delivery.md#checks-for-the-next-apply-session) have passed first: do not run chaos on a cluster that is not healthy.
3. **No page alert firing,** and every Application Synced and Healthy.
4. **The load helper running,** and the gateway showing about two requests a second:

   ```bash
   scripts/chaos-load.sh start
   scripts/chaos-load.sh status
   ```

   In Prometheus (`kubectl --context <CTX> -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090`): `sum(rate(http_requests_total{service="gateway", route!~"/healthz|/readyz|/metrics|/version"}[1m]))` should be near 2. It runs for half an hour by default; start it again when it ends (`--duration` up to 3600).
5. **Grafana open on the dashboards,** each in its own tab: **SLOs** (the availability and latency of the gateway), **Sample services**, **Cluster capacity**, **Data layer**, **Progressive delivery**, and the Alertmanager page. Watch them with your own eyes: the runner measures what its probes say, and you may see something they do not.
6. **Argo CD paused for the four workloads that are scaled to zero,** only when you reach them (experiments 3 to 6), and resumed afterwards. See [the chaos README](../../chaos/README.md#argo-cd). The command to pause is `kubectl --context <CTX> -n argocd annotate application <app> argocd.argoproj.io/skip-reconcile=true` and to resume it `kubectl --context <CTX> -n argocd annotate application <app> argocd.argoproj.io/skip-reconcile-`. The four are `delivery-argo-rollouts-in-cluster`, `eso-operator-in-cluster`, `policy-kyverno-in-cluster` and `data-valkey-in-cluster`. **Whether the annotation really stops the self-heal, and whether the ApplicationSet leaves it alone, has not been seen.** If a run ends with the status 5, it did not.
7. **Two terminals:** one for the runner, one for the commands in the entries below. And someone who can stop everything: `Ctrl-C` in the runner, then `scripts/chaos-run.sh --cleanup --execute`.

## The first game day

One experiment at a time, in this order, from the safest to the riskiest. Dry-run all eleven first (`for f in chaos/experiments/*.yaml; do scripts/chaos-run.sh "$f"; done`), read each plan, and stop at the first experiment whose plan is not what you expect. Between experiments wait until the dashboards are quiet and no alert is pending, look at the result file, and fill in the [game day record](../../chaos/templates/game-day-record.md).

| # | Experiment | Takes about | Before it | After it |
| --- | --- | --- | --- | --- |
| 1 | `gateway-pod-kill` | 5 min | the load helper | |
| 2 | `payments-pod-kill` | 5 min | | |
| 3 | `rollouts-controller-down` | 15 min | pause `delivery-argo-rollouts-in-cluster` | resume it |
| 4 | `eso-down` | 8 min | external secrets mode; pause `eso-operator-in-cluster` | resume it |
| 5 | `kyverno-admission-down` | 8 min | pause `policy-kyverno-in-cluster` | resume it |
| 6 | `valkey-down` | 8 min | pause `data-valkey-in-cluster` | resume it |
| 7 | `isolated-gateway-pod` | 8 min | | |
| 8 | `orders-pod-kill-under-load` | 8 min | | |
| 9 | `rabbitmq-pod-kill` | 10 min | | |
| 10 | `postgres-primary-failover` | 25 min | | check the replica is streaming (`resilience.md`, check 9) |
| 11 | `node-drain` | 20 min | four nodes | |

Do the loop at the end of each: result file read, rollback `ok`, the cluster as before (`kubectl get pods -A`, `kubectl get nodes`, `kubectl -n shop get hpa,pdb`), no pending alert, then the next. If an experiment ends with the status 4, 5 or 1, stop and understand it before the next.

## The experiments

Each entry: what to watch while it runs, the first things to check if the hypothesis fails, and how to stop it and clean up by hand. For **every** experiment, the first way to stop is `Ctrl-C` in the runner (it rolls back), and the second is `scripts/chaos-run.sh --cleanup --execute`, which finds and reverts what a run left. The by-hand forms are for when the script is not available.

### gateway-pod-kill

- **Watch:** the SLOs dashboard (gateway availability and latency), `kubectl -n shop get pods -l app.kubernetes.io/name=gateway -w`, the endpoints of the Service (`kubectl -n shop get endpointslices -l kubernetes.io/service-name=gateway`).
- **If the hypothesis fails:** was the dying pod still in the endpoints when it stopped? Compare the `preStop` sleep (5 s) and the drain period (5 s) with what you saw. Was the replacement slow to be Ready (events of the pod)? Was one replica alone too slow (the latency probe fails, the availability one holds)?
- **By hand:** nothing to undo; the Rollout replaces the pod. `kubectl -n shop get rollout gateway` shows it.

### payments-pod-kill

- **Watch:** the SLOs dashboard, the payments pods (`kubectl -n shop get pods -l app.kubernetes.io/name=payments -w`), and the logs of the gateway for 502s.
- **If it fails:** how long did the new payments pod take to be Ready (the JVM start)? Did the orders in flight at the moment of the kill fail, and did they retry? Is the one remaining pod saturated (the **Sample services** dashboard, latency of payments)?
- **By hand:** nothing to undo.

### rollouts-controller-down

- **Watch:** the **Progressive delivery** dashboard (the controller panel goes to no data), the alert page (`RolloutsControllerDown` is pending after a few minutes and fires after ten), the gateway availability.
- **During the window, by hand (the half of the claim the runner does not test):** start a canary by a pull request that changes a pod annotation of the gateway, and see that the Rollout stays where it is and does not advance (`kubectl -n shop get rollout gateway`). Revert or promote it after the experiment. Skip this if you do not want a rollout in flight during the test.
- **If it fails:** the traffic changed when the controller went (look at the Service endpoints and the replica sets of the gateway), or the alert did not fire after ten minutes (check `kube_deployment_status_replicas_available{namespace="argo-rollouts"}` and the rule `delivery`).
- **By hand:** `kubectl -n argo-rollouts scale deployment argo-rollouts --replicas=1`, then remove the annotation `chaos.platform.example/original-replicas` and the three `chaos.platform.example/` labels from the Deployment, and **resume the Application**.

### eso-down

- **Watch:** the pods of `shop`, `data` and `observability` (`kubectl get pods -A -w`: nothing restarts), the ExternalSecrets (`kubectl get externalsecrets -A`: they stay as they were), the gateway availability.
- **If it fails:** which pod restarted and why (`kubectl describe pod`)? Did a Secret disappear (`kubectl -n shop get secret orders-db`)? Did the webhook block something (events)?
- **Not valid in the generated mode:** the probe on the ExternalSecret series refuses the run. That is the intended check.
- **By hand:** `kubectl -n external-secrets scale deployment external-secrets --replicas=1`, the labels and the annotation as above, and resume the Application.

### kyverno-admission-down

- **Watch:** the gateway availability, the pods of `shop`. The runner cannot create a pod, so the other half of the claim is yours.
- **During the window, by hand:** create a pod in `shop` and see it start, with the restricted profile (the policies audit, so a report is not made while the controller is down):

  ```bash
  kubectl --context <CTX> -n shop apply -f - << 'EOF'
  apiVersion: v1
  kind: Pod
  metadata:
    name: chaos-admission-probe
    labels:
      app.kubernetes.io/name: chaos-admission-probe
      chaos.platform.example/managed-by: chaos-load
  spec:
    restartPolicy: Never
    automountServiceAccountToken: false
    securityContext: {runAsNonRoot: true, runAsUser: 65534, runAsGroup: 65534, seccompProfile: {type: RuntimeDefault}}
    containers:
      - name: probe
        image: docker.io/library/busybox:1.37@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec
        command: [sleep, "60"]
        resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {cpu: 50m, memory: 32Mi}}
        securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
  EOF
  kubectl --context <CTX> -n shop get pod chaos-admission-probe -w
  kubectl --context <CTX> -n shop delete pod chaos-admission-probe
  ```

  Expected: the pod is admitted and runs. If it is refused with an error about the webhook, a Kyverno webhook fails closed, which is the finding.
- **If it fails:** `kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o yaml | grep failurePolicy`: any `Fail` is the cause ([Kyverno runbook](kyverno.md#check-after-an-apply), check 3).
- **By hand:** `kubectl -n kyverno scale deployment kyverno-admission-controller --replicas=1`, the labels and the annotation, and resume the Application.

### valkey-down

- **Watch:** the gateway availability **and latency**, the **Data layer** dashboard (cache lookups: errors, then the fall back), `/readyz` of orders (it reports Valkey as degraded; look at the logs of orders).
- **If it fails:** is the latency probe the one that failed (the fall back to PostgreSQL is slower than 0.5 s), or the availability one (orders waits for Valkey)? Look at the client timeouts of orders against the timeout of the gateway ([ADR-0015](../adr/0015-service-data-integration.md)).
- **By hand:** `kubectl -n data scale deployment platform-valkey --replicas=1`, the labels and the annotation, and resume the Application. The volume claim is kept; the cache is empty.

### isolated-gateway-pod

- **Watch:** `kubectl -n shop get pods -l app.kubernetes.io/name=gateway --show-labels -w` (one pod has lost its labels and has the label `chaos.platform.example/isolated`, a new one starts), the endpoints of the Service (the isolated pod is not there), and that pod's Ready column (`kubectl -n shop get pod <name>`: it should turn to `0/1`).
- **If it fails:** the isolated pod stayed Ready (the deny policy did not take hold: `kubectl -n shop get networkpolicy -l chaos.platform.example/managed-by=chaos-run`, and the policy agent's log), or the Service still sent traffic to it, or the other replica could not carry the load.
- **By hand:** `kubectl -n shop delete networkpolicy -l chaos.platform.example/managed-by=chaos-run`, and `kubectl -n shop delete pod -l chaos.platform.example/managed-by=chaos-run` (the isolated pod only: the label is on no other pod).

### orders-pod-kill-under-load

- **Watch:** the **Data layer** dashboard (outbox backlog and age, messages published by result, the notifier's consumption), the orders pods, the notifier log for duplicates.
- **If it fails:** is the outbox age back to a few seconds (the probe `outbox-age`)? Is the difference between orders created and events recorded small (the probe `orders-against-notifications`: a proxy, see the header of the file)? If the proxy is off, count by hand: orders created in PostgreSQL in the window against the notifier's records. A proper check needs per-order accounting that does not exist yet, so a failure is a finding and a pass is weak evidence.
- **By hand:** nothing to undo.

### rabbitmq-pod-kill

- **Watch:** the **Data layer** dashboard (broker metrics, outbox age), `kubectl -n data get pods -l app.kubernetes.io/name=platform-mq -w`, the notifier log (it reconnects), the alert page.
- **If it fails:** was anything dead-lettered (`messages_consumed_total{result="dead_letter"}`)? Did orders return errors while the broker was gone (the availability probe)? Does the outbox drain after the broker is back, and how long did that take?
- **By hand:** nothing to undo; the StatefulSet replaces the pod.

### postgres-primary-failover

- **Watch:** the SLOs dashboard, the **Data layer** dashboard (PostgreSQL connections, replication), `kubectl -n data get cluster.postgresql.cnpg.io platform-pg -w` (the primary changes), the orders and payments logs for connection errors, `PostgresInstancesNotReady` on the alert page (it fires only if the replica is not back within ten minutes).
- **If it fails:** how long was the gap (the time the availability probe was outside its threshold)? Did orders and payments reconnect without a restart? Was the new replica rebuilt, and how long did that take? What the run does **not** say: how many acknowledged writes the promotion lost (replication is asynchronous). Count them by hand if you care: compare the orders the load helper created with the rows after.
- **By hand:** nothing to undo; the operator recreates the instance. Check `kubectl -n data get cluster.postgresql.cnpg.io platform-pg` returns to `Cluster in healthy state` with two instances.

### node-drain

- **Watch:** the **Cluster capacity** dashboard, `kubectl -n shop get pods -o wide -w`, `kubectl -n shop get pdb`, `kubectl get pods -A --field-selector status.phase=Pending`, the alert page (`PodsPending` after ten minutes).
- **If it fails:** the drain timed out (the PostgreSQL primary was on the node and the operator's budget made it wait: use a switchover first, [resilience runbook](resilience.md#postgresql-switchover-test)); pods stayed Pending (`kubectl describe pod`: `Insufficient cpu` means the capacity numbers are wrong); a budget blocked the drain (`kubectl -n shop get pdb`).
- **By hand:** `kubectl uncordon <node>` (the node is in the result file and in the output), then `kubectl label node <node> chaos.platform.example/managed-by- chaos.platform.example/run- chaos.platform.example/experiment-`.

## When a rollback fails

The runner prints `ROLLBACK FAILED` and exits with 1. It tried every step; the result file lists each step and the error.

1. **Do not run another experiment.** The next run refuses to start while something is left.
2. **Look:** `scripts/chaos-run.sh --cleanup` lists what is left (policies, workloads at zero, isolated pods, cordoned nodes, the load helper's objects).
3. **Revert:** `scripts/chaos-run.sh --cleanup --execute` (type the cluster name). If it fails too, use the by-hand lines of the experiment above.
4. **Look at the cluster:** `kubectl get nodes`, `kubectl get pods -A`, `kubectl -n shop get hpa,pdb`, the alert page.
5. **Resume Argo CD** for every Application you paused: `kubectl -n argocd annotate application <app> argocd.argoproj.io/skip-reconcile-`. Cleanup does not do this (the teardown scripts do, but only so that a teardown cannot hang).
6. **Record it:** a rollback that fails is a finding about the runner.

## From a finding to a fix

Every run writes a result file, and every finding is recorded there: the probe values, the alerts, the timings, what was changed. At the end of the game day copy what matters into the [game day record](../../chaos/templates/game-day-record.md): for each experiment what was expected, what was observed, the SLO impact in numbers, the alerts that fired and whether the hypothesis held, and the follow-ups. A claim in an ADR or a runbook that turned out to be wrong is listed with its file and section, so it can be corrected. What is done with the findings, and who decides, is for the team. This runbook does not define a postmortem process.

## What has not been shown

- Everything on a real cluster. The runner, the load helper and the experiments have run against fakes.
- That the annotation `argocd.argoproj.io/skip-reconcile` pauses the self-heal of an Application made by an ApplicationSet, and that the ApplicationSet leaves it there (`preservedFields`).
- That `kubectl port-forward` to Prometheus works as the runner uses it, that a pod without labels leaves its ReplicaSet, the Service and the allow policies on the VPC CNI, and that the load pod reaches the gateway through the temporary policy.
- The probes on real traffic: the thresholds are the SLO objectives or, for the failover, a stated guess (0.95).
- What the experiments do not measure, said in each file: acknowledged writes lost in a failover, a proper count of orders against notifications, admission of a new pod, a rollout stalling.

## Teardown

`scripts/teardown-prep.sh` and `scripts/teardown-argocd.sh` now deal with what a game day leaves, so none of it has to be done by hand first:

- **The load helper.** `teardown-prep.sh` deletes the pod and the NetworkPolicy labelled `chaos.platform.example/managed-by=chaos-load` in `shop`, before it waits for the namespace to empty.
- **Paused Applications.** Argo CD v3.5.6 does not queue an Application that carries `argocd.argoproj.io/skip-reconcile`, so its deletion (the finalizer `resources-finalizer.argocd.argoproj.io`) would never be processed. Both scripts remove the annotation from every Application that has it, and `teardown-prep.sh` warns first, because a paused Application means a run was left unfinished. An Application without the annotation is left alone. This is read from the controller's source at that version; it has not been seen on a cluster.
- **Chaos leftovers.** `teardown-prep.sh` warns, and does not fail or remove anything, when it finds what `scripts/chaos-run.sh --cleanup` would find (the label `chaos.platform.example/managed-by=chaos-run` on workloads, pods and policies of `shop`, `data`, `observability`, `kyverno`, `external-secrets` and `argo-rollouts`, and on nodes). The warning names the command to run.

Stopping the load (`scripts/chaos-load.sh stop`), running `scripts/chaos-run.sh --cleanup` and resuming the Applications you paused is still the right order at the end of a game day: the teardown is a safety net, not the plan, and a deny policy, a scaled-down workload or a cordoned node is better reverted by the runner that knows what it changed. The result files stay on your machine; the cluster is destroyed.
