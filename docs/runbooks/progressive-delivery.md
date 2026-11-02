# Progressive delivery

Switches on the Argo Rollouts controller and the canary release of the gateway, shows how a release flows and how to watch, promote, abort and roll it back, tests it with a good, a bad and an idle release, and says what each alert means. It ends with the checks for the next apply session, for everything that has been merged and not yet run on a cluster. The reasoning is in [ADR-0028](../adr/0028-progressive-delivery.md); the controller is described in the [`argo-rollouts` README](../../platform/delivery/argo-rollouts/README.md) and the canary in the [service chart README](../../deploy/helm/README.md#canary-rollouts-argo-rollouts).

**Nothing in this runbook has been run on a cluster.** The commands are written from the manifests, from the documentation of Argo Rollouts and from its source at the pinned version (chart 2.43.8, application v1.10.1). Every check and test below is marked "not run" until someone runs it and writes down what differs. Where a command could not be checked against the project's documentation, it says so. The output is not shown on purpose, because none has been seen.

## What is installed and how it is switched on

- **The controller.** One pod in the namespace `argo-rollouts` (50m CPU, 64Mi of memory), five CRDs, a metrics Service on port 8090, default-deny network policies. No dashboard, no notifications, no webhook. Argo CD deploys it to clusters labelled `platform.example/progressive-delivery=true`.
- **The canary.** On the same clusters, in the data profile, the gateway is a `Rollout` and not a `Deployment`, with an `AnalysisTemplate` named `gateway-canary`. With the observability layer as well (`platform.example/observability=true`) the canary is judged on Prometheus; without it the canary has timed pauses only. Orders, payments and the notifier stay Deployments.
- **The flag.** `--enable-progressive-delivery` of `scripts/bootstrap-argocd.sh` sets the label. The script writes every label on each run, so repeat the flags the cluster already has or they are switched off:

  ```bash
  ./scripts/bootstrap-argocd.sh --context <EKS_CONTEXT> --dry-run --enable-policy --enable-external-secrets --enable-progressive-delivery --enable-data --enable-observability --enable-apps --apps-profile data
  ```

  Read the printed cluster Secret, then run it again without `--dry-run`.
- **The order.** The controller is wave 18 and its network policies wave 19, after the observability stack (waves 10 to 17) and before the services (20 to 22). A wave only orders the creation of the ApplicationSets, so nothing waits: if the gateway Application syncs before the CRDs exist, its sync fails and retries (ten times, up to ten minutes apart) until they do. The network policies also need the Service range from the cluster Secret, as the other policies do.
- **The monitoring.** The ServiceMonitor `argo-rollouts` (in the `monitors` chart) scrapes the controller; the rules and the dashboard **Progressive delivery** need the observability layer.

## How a release flows

```text
 pull request edits images.yaml (a new digest)         [deploy/helm/values/images.yaml]
          |  merge to main
          v
 Argo CD syncs apps-gateway: the pod template changes -> the Rollout has a new revision
          |
          v
 step 1  setWeight 25      canary ReplicaSet scaled up (a share of the replicas, no traffic router)
          |                background analysis starts at the first pause (2 minutes of delay, then one measurement a minute)
 step 2  pause 5m   <----- analysis: success ratio and fast ratio of the canary pods, from Prometheus
          |                   good enough          -> carries on
          |                   below a threshold     -> Failed -> the rollout is aborted, the canary is scaled down
          |                   too little traffic    -> Inconclusive -> the rollout pauses and waits for a person
 step 3  setWeight 50
 step 4  pause 5m
          v
 promoted: the canary becomes the stable ReplicaSet, the old pods are scaled down
```

The numbers are the defaults of the chart (`rollout.steps`, `rollout.analysis`). The split of requests follows the pod counts, so it is approximate: with two gateway pods, 25 percent is one canary pod and one stable pod. Argo CD shows the Application as `Progressing` while the steps run, `Suspended` while it is paused and `Healthy` when the rollout is complete. The release of an image is described in [releasing images](releasing-images.md).

## Watch a rollout

With plain `kubectl`. In every command `<EKS_CONTEXT>` is the context of the cluster. Not run.

```bash
kubectl --context <EKS_CONTEXT> -n shop get rollout gateway
kubectl --context <EKS_CONTEXT> -n shop describe rollout gateway
kubectl --context <EKS_CONTEXT> -n shop get analysisrun
kubectl --context <EKS_CONTEXT> -n shop get replicasets -l app.kubernetes.io/name=gateway -L rollouts-pod-template-hash
kubectl --context <EKS_CONTEXT> -n shop get pods -l app.kubernetes.io/name=gateway -L rollouts-pod-template-hash
kubectl --context <EKS_CONTEXT> -n shop get events --sort-by=.lastTimestamp | tail -20
```

- `get rollout` shows the desired, current, up-to-date and available replicas. `describe` shows the phase, the current step, the pause conditions and the message of the condition `Progressing`.
- `get analysisrun` lists the runs the Rollout made, named `<rollout>-<pod template hash>-<revision>-gateway-canary`. `describe analysisrun <name>` shows each measurement of each metric, with its value and phase.
- The pods of the canary have the hash of the new ReplicaSet in their name. That is the hash the analysis queries select.
- To see the metrics the analysis sees, open Prometheus ([observability runbook](observability.md#reach-grafana-and-prometheus)) and run `rollout_info{namespace="shop"}` and `analysis_run_info{namespace="shop"}`. The dashboard **Progressive delivery** in Grafana shows the same.

With the `kubectl argo rollouts` plugin. **This repository does not install the plugin;** install it from the project's page, <https://argo-rollouts.readthedocs.io/en/stable/installation/#kubectl-plugin-installation>, at the same version as the controller (v1.10.1). Not run.

```bash
kubectl --context <EKS_CONTEXT> argo rollouts get rollout gateway -n shop --watch
kubectl --context <EKS_CONTEXT> argo rollouts list rollouts -n shop
```

`get rollout --watch` draws the tree of ReplicaSets, pods and analysis runs and updates it as the rollout moves. Everything it shows is also in the plain commands above.

## Promote, abort, retry and roll back

Argo CD manages the Rollout with `selfHeal`, so a change to its **spec** by hand is put back. The commands below change only its **status**, which Argo CD does not compare, so they hold. The `kubectl patch` forms are the ones the plugin applies at v1.10.1, read from its source (`pkg/kubectl-argo-rollouts/cmd`); the project's documentation describes the plugin commands and not these patches, so **they are marked "form read from the source, not run"**. `--subresource=status` needs kubectl 1.24 or later.

| Action | Plugin command | Plain form |
| --- | --- | --- |
| Promote past the current pause (also an inconclusive analysis) | `kubectl argo rollouts promote gateway -n shop` | `kubectl -n shop patch rollout gateway --subresource=status --type merge -p '{"status":{"pauseConditions":null}}'` (form read from the source, not run) |
| Promote all the way, skipping the remaining steps and the analysis | `kubectl argo rollouts promote --full gateway -n shop` | `kubectl -n shop patch rollout gateway --subresource=status --type merge -p '{"status":{"promoteFull":true}}'` (form read from the source, not run) |
| Abort | `kubectl argo rollouts abort gateway -n shop` | `kubectl -n shop patch rollout gateway --subresource=status --type merge -p '{"status":{"abort":true}}'` (form read from the source, not run) |
| Retry an aborted rollout | `kubectl argo rollouts retry rollout gateway -n shop` | `kubectl -n shop patch rollout gateway --subresource=status --type merge -p '{"status":{"abort":false}}'` (form read from the source, not run) |

Add `--context <EKS_CONTEXT>` to each. The promote patch in the source has two more forms (it also sets the step index when the rollout is at a step, and un-pauses `spec.paused` when that is set); the plain form above covers a pause that comes from a pause step or an inconclusive analysis, which is what this chart produces. If it does not move the rollout, use the plugin.

- **Abort** sets the canary weight to zero, so the canary pods are scaled down (as far as the stable pods being available allows) and the stable pods keep serving. The rollout stays aborted, and Argo CD shows `Degraded`, until the spec changes or it is retried. An aborted rollout does not retry by itself.
- **Retry** starts the same revision again from the first step. Do it only after the cause is fixed (for example Prometheus was down).
- **Roll back** by changing Git: revert the pull request that changed `images.yaml` (or the values). That is a new revision equal to the stable one, and Rollouts goes back to it without steps, because it is already the stable ReplicaSet. The plugin has `undo`, and a patch of the pod template would work, but Argo CD would put the spec back from Git, so the revert in Git is the way. The procedure for the images is in [releasing images](releasing-images.md#roll-back-to-a-previous-version).

What Argo CD shows (from its built-in health check for a `Rollout`, read in its source at v3.5.6; not seen on a cluster):

| State of the Rollout | Health of the Application |
| --- | --- |
| Stepping up, or waiting for pods | `Progressing` |
| Paused at a pause step, or by an inconclusive analysis | `Suspended` |
| Aborted, or past its progress deadline, or an invalid spec | `Degraded` |
| Complete: the canary is the stable ReplicaSet | `Healthy` |

The sync status stays `Synced` in all of them, because the spec in the cluster is the spec in Git. An `AnalysisTemplate` has no status and no health check.

## A controlled test release

Do these on a cluster you can disturb, with the data profile, the observability layer and `--enable-progressive-delivery`. All are **not run**. Each is a pull request to `main` that changes the gateway's pod template, because Argo CD tracks `main` and puts back anything done by hand.

First check the starting point: the Rollout is `Healthy`, two gateway pods are ready, there is no analysis run, and the controller is scraped:

```bash
kubectl --context <EKS_CONTEXT> -n shop get rollout gateway
kubectl --context <EKS_CONTEXT> -n shop get analysisrun
```

### Load for the check

The analysis judges the canary only when it served at least 20 requests in two minutes (`rollout.analysis.minRequests`). A cluster with no users has none, so a test needs traffic through the **Service**, which spreads it over the stable and the canary pods. A `kubectl port-forward` goes to one pod and would not.

The gateway's network policy lets in only Prometheus (and a load balancer, if the ingress is on), so a pod in `shop` is refused. Two objects are needed, both temporary: a pod, and a policy that lets that pod in. The pod runs in `shop`, which enforces the restricted Pod Security level, so it has the restricted settings. The pod is not selected by any deny (the denies select only the pods of a release), so its own egress is free. The image is the busybox of the [network policy runbook](network-policies.md) (read its digest again before relying on it); it is from `docker.io`, so the audit policies will list it in a policy report, which is expected.

```bash
export DEBUG_IMAGE='docker.io/library/busybox:1.37@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec'
kubectl --context <EKS_CONTEXT> apply -f - << EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: loadgen-to-gateway
  namespace: shop
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: gateway
      app.kubernetes.io/instance: gateway
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: loadgen
      ports:
        - protocol: TCP
          port: 8080
---
apiVersion: v1
kind: Pod
metadata:
  name: loadgen
  namespace: shop
  labels:
    app.kubernetes.io/name: loadgen
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: loadgen
      image: ${DEBUG_IMAGE}
      command:
        - sh
        - -c
        - 'while true; do wget -q -O /dev/null -T 3 http://gateway:8080/api/orders; sleep 0.5; done'
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          cpu: 100m
          memory: 32Mi
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
EOF
```

That is about two requests a second to `GET /api/orders` through the Service, about 240 in two minutes over the gateway pods, so a canary with one of two pods gets about 120, above the minimum. If the autoscaler adds pods, the canary's share falls; at four pods it still has more than 20. Check that it works before relying on it (the number should rise):

```bash
kubectl --context <EKS_CONTEXT> -n shop get pod loadgen
```

The pod should be `Running`. In Prometheus, `sum(rate(http_requests_total{service="gateway", route="/api/orders"}[2m]))` should be near 2. The loop prints nothing and does not stop if the gateway answers with an error, so the rate in Prometheus is the check. Stop the load with `kubectl -n shop delete pod loadgen`, and delete the policy when the tests are over: `kubectl -n shop delete networkpolicy loadgen-to-gateway`. Neither is in Git; Argo CD lists them as orphaned resources (a warning) and does not prune them.

### A good release

Change something harmless in the pod template, for example a pod annotation in `deploy/helm/values/gateway.yaml` (`podAnnotations: {platform.example/test-release: "good-1"}`), or release a real image. With the load running:

1. The Rollout goes to step 1 (one canary pod and one stable pod) and pauses 5 minutes; the Application is `Suspended`.
2. Two minutes later the analysis run starts measuring, one measurement a minute. In `describe analysisrun` both metrics show `Successful`, with a success ratio near 1 and a fast ratio near 1.
3. After the pause the weight goes to 50 percent, pauses 5 minutes, and the Rollout completes. Ten minutes in all. Expected: `Healthy`, no alert.

### A bad release

The gateway has a built-in fault switch ([`apps/gateway`](../../apps/gateway/README.md)): `FAULT_INJECTION_ENABLED`, `FAULT_ERROR_RATE` (the share of requests answered with `503 fault_injected`) and `FAULT_LATENCY_MS` (a delay added to every request). They are environment variables, so a bad release needs no change to the application: put them in the `env` of `deploy/helm/values/gateway.yaml` in a pull request. The probes are not affected (the operational routes are exempt). With the load running:

- **Errors:** `FAULT_INJECTION_ENABLED: "true"` and `FAULT_ERROR_RATE: "0.3"`. The canary's success ratio is about 0.7, below 0.99. Expected: the first measurements fail; after more than two failures (about 5 minutes after the first pause starts) the run is `Failed`, the Rollout is aborted, the canary pod is scaled down, and the Application is `Degraded`. `RolloutAborted` and `AnalysisRunFailed` fire after their waits. The stable pods served all the time, and the gateway SLO may have burned a little.
- **Slow:** `FAULT_INJECTION_ENABLED: "true"` and `FAULT_LATENCY_MS: "800"`. Every request on the canary takes more than 0.5 s, so its fast ratio is near 0, below 0.90; the success ratio is fine. The same end.

Then revert the pull request. The Rollout goes back to the stable revision at once.

### An idle release

No load. Release the same harmless change as for the good release. Expected: the canary is created and the first pause starts; the analysis starts measuring after 2 minutes, finds too little traffic (the query returns NaN), and after more than two such measurements (about 5 minutes after the first pause starts, before the pauses end) the run is `Inconclusive` and the Rollout is `Paused` with a message about the analysis. The Application is `Suspended`. It is not promoted and not aborted. Promote or abort it by hand (above). If you leave it, `RolloutPausedTooLong` fires after 30 minutes.

## Alerts

All seven are tickets, defined in [`delivery-rules.yaml`](../../platform/observability/monitors/templates/delivery-rules.yaml) and tested in [`delivery-rules.test.yaml`](../../platform/observability/monitors/tests/delivery-rules.test.yaml). They are tickets because in every case the stable pods keep serving; a canary that fails requests burns the SLO, and those alerts are the ones that page. The metrics are those of the controller (`rollout_info`, `analysis_run_info`, `analysis_run_metric_phase`, `rollout_reconcile_error`, `analysis_run_reconcile_error`), read from the project's documentation and source and **not seen on a cluster**. Each alert is on state, so it resolves when the state does. In the commands `<EKS_CONTEXT>` is the context of the cluster.

### rollout-aborted

**What it means.** `RolloutAborted`: a Rollout in `shop` has been in the phase `Abort` for 5 minutes (`rollout_info{phase="Abort"}`). The analysis failed, the progress deadline passed, or a person aborted it. The canary is scaled down and the stable version serves. The new revision is not live.

**First three things to check.**

1. `kubectl --context <EKS_CONTEXT> -n shop describe rollout gateway`: the message and the events say why.
2. `kubectl --context <EKS_CONTEXT> -n shop get analysisrun` and `describe` the newest: did a metric fail (the canary was bad) or error (it could not be measured)?
3. The pull request that changed the pod template: was the change the cause (a bad image, a fault setting left on)?

**Do first.** If the canary was bad, fix or revert the change in Git. If the analysis erred for another reason (Prometheus was down), fix that and retry. **Recovered when** a new revision is rolled out or the rollout is retried.

### rollout-degraded

**What it means.** `RolloutDegraded`: a Rollout has been in the phase `Timeout`, `Error` or `InvalidSpec` for 10 minutes. `Timeout` is the progress deadline (600 s): no progress, for example pods that do not become ready; the chart aborts then, so `RolloutAborted` follows. `Error` and `InvalidSpec` mean the controller could not act on the object. Argo CD shows `Degraded`.

**First three things to check.**

1. `kubectl --context <EKS_CONTEXT> -n shop describe rollout gateway`: the condition `Progressing` and `InvalidSpec`, if any.
2. `kubectl --context <EKS_CONTEXT> -n shop get pods -l app.kubernetes.io/name=gateway`: pods Pending (see [pods-pending](alerts.md#pods-pending)), crashing or not ready?
3. `kubectl --context <EKS_CONTEXT> -n argo-rollouts logs deploy/argo-rollouts --tail=100`: errors about the object.

**Recovered when** the phase is no longer one of the three.

### rollout-paused-too-long

**What it means.** `RolloutPausedTooLong`: a Rollout has been paused for 30 minutes. The pause steps last 5 minutes on their own, so this is a pause that waits for a person. The usual cause is an inconclusive analysis: the canary got fewer than 20 requests in the window, so it could not be judged.

**First three things to check.**

1. `kubectl --context <EKS_CONTEXT> -n shop describe rollout gateway`: the pause conditions and the message.
2. `kubectl --context <EKS_CONTEXT> -n shop describe analysisrun <name>`: `Inconclusive`? Then look at the request rate of the gateway in Prometheus: `sum(rate(http_requests_total{service="gateway", route!~"/healthz|/readyz|/metrics|/version"}[5m]))`.
3. Whether anyone is meant to promote it. On a dev cluster with no traffic, it is expected.

**Do first.** Decide: send traffic (the load pod above) and retry, promote it if you accept the canary unjudged, or abort it. **Recovered when** the rollout moves on.

### analysis-run-failed

**What it means.** `AnalysisRunFailed`: an analysis run in `shop` is in the phase `Failed`. A metric was below its threshold more than twice: the canary's success ratio was under 0.99, or its share of requests within 0.5 s was under 0.90. The Rollout was aborted. The run stays in the cluster while the Rollout keeps it (its history limit), so this alert does not resolve the moment the rollout is fixed; it resolves when the run is removed.

**First three things to check.**

1. `kubectl --context <EKS_CONTEXT> -n shop describe analysisrun <name>`: which metric, which values.
2. The canary's logs: `kubectl --context <EKS_CONTEXT> -n shop logs <canary pod>` (its name has the new hash), and the **Sample services** dashboard.
3. The change in the pull request, and the fault settings (`FAULT_*`) in the values.

**Recovered when** the failed run is gone (`kubectl -n shop delete analysisrun <name>` once you have read it).

### analysis-run-error

**What it means.** `AnalysisRunError`: a metric of an analysis run could not be measured (phase `Error`). Usually the controller could not query Prometheus: Prometheus is down, the address is wrong, or the network policy does not let the controller reach port 9090. After three errors in a row the run errors and the Rollout is **aborted**, so a release can be stopped for a reason that has nothing to do with the canary. The canary was not judged.

**First three things to check.**

1. `kubectl --context <EKS_CONTEXT> -n shop describe analysisrun <name>`: the message of the measurement, for example a connection refused or a timeout.
2. Is Prometheus up, and does the Service exist at the address in the AnalysisTemplate? `kubectl --context <EKS_CONTEXT> -n observability get svc kube-prometheus-stack-prometheus`, and `kubectl --context <EKS_CONTEXT> -n shop get analysistemplate gateway-canary -o yaml | grep address`.
3. The network policies: `controller-allow-prometheus-query` in `argo-rollouts` and `prometheus-allow-from-argo-rollouts` in `observability` ([network policy runbook](network-policies.md#see-what-is-being-dropped)).

**Do first.** Fix the cause, then retry the rollout (above). **Recovered when** the run is removed.

### rollouts-controller-down

**What it means.** `RolloutsControllerDown`: for 10 minutes the controller's target was down, or its Deployment had no available pod. Existing pods keep serving. A rollout in progress does not advance, an abort is not carried out, and a new release is not started. With one replica, a node loss causes this until the pod runs elsewhere.

**First three things to check.**

1. `kubectl --context <EKS_CONTEXT> -n argo-rollouts get deployments,pods`
2. `kubectl --context <EKS_CONTEXT> -n argo-rollouts describe pod -l app.kubernetes.io/name=argo-rollouts` and the events (Pending for capacity, image pull, a failed probe, the Pod Security level).
3. `kubectl --context <EKS_CONTEXT> -n argo-rollouts logs deploy/argo-rollouts --previous --tail=100` if it restarts.

**Recovered when** the pod is ready and scraped.

### rollouts-controller-not-reconciling

**What it means.** `RolloutsControllerNotReconciling`: the controller's reconcile error counters (`rollout_reconcile_error`, `analysis_run_reconcile_error`) for `shop` rose in the last 10 minutes, for 15 minutes. It is running but failing to act on a Rollout or an analysis run, so rollouts may not advance.

**First three things to check.**

1. `kubectl --context <EKS_CONTEXT> -n argo-rollouts logs deploy/argo-rollouts --tail=200`: the error, and the Rollout it names.
2. Whether the controller can reach the API server: the network policy `allow-kube-api-controller` in `argo-rollouts` and `serviceCidr` in the cluster Secret.
3. `kubectl --context <EKS_CONTEXT> -n shop describe rollout gateway`: an object it cannot process (`InvalidSpec`).

**Recovered when** the counters stop rising.

## Known limits

- **The split of requests is approximate.** There is no traffic router, so a step's weight is a share of the replicas, rounded to whole pods, and the Service sends requests to all ready pods. With two pods, 25 percent is half of the requests. The autoscaler changes the counts, and so the split.
- **A canary is judged on few requests.** Two minutes of traffic is a few hundred requests at best, and the thresholds have a margin below the SLO for that reason. A subtle regression can pass.
- **Not proven on a cluster:** the `pod` label on the series and the pod hash in the pod names (the analysis depends on both); that an inconclusive analysis pauses the rollout as the project documents; that `increase()` over two minutes behaves with the real scrape timing; the replica split; the abort and the scale-down; the health Argo CD shows; the switch of an existing Deployment to a Rollout; the HPA driving a Rollout; the metric names and labels of the alerts; the `honorLabels` setting of the ServiceMonitor.
- **Orders is not covered.** It stays a Deployment: its work is the outbox, which a request-ratio analysis does not see. Payments and the notifier have no SLO series and keep state per pod.
- **Kyverno and `Enforce`.** The probe policy matches Rollouts, and the pod policies match their pods, but Kyverno has no autogen for a Rollout, so with `Enforce` a bad Rollout would be accepted and fail when its ReplicaSet creates a pod. In `Audit`, as now, there is no difference ([policies README](../../platform/security/policies/README.md#argo-rollouts)).
- **The controller is a single replica.** If it is down, rollouts stop where they are (see [rollouts-controller-down](#rollouts-controller-down)); existing pods are not affected. `values-ha.yaml` of the controller has two.
- **A paused rollout needs a person.** An inconclusive analysis is not resolved by waiting.
- **Kubernetes 1.37 is not confirmed** for this version of Argo Rollouts: the project's end-to-end tests cover 1.32 to 1.35.

## Teardown

Nothing new is needed. The label `platform.example/progressive-delivery` is removed with the others by `scripts/teardown-prep.sh`, which then waits for the `delivery-*` Applications and for the `shop` namespace to hold no pods. The Rollout is deleted with its Application and its ReplicaSets and pods follow through their owner references. The controller has no finalizer that outlives it, and the CRDs go with their Application; the Rollout objects are not listed in the wait, because asking for a kind whose CRD is already gone is an error. The temporary pod and policy of the load test, if left behind, are not tracked by Argo CD: delete them (`kubectl -n shop delete pod loadgen`, then `kubectl -n shop delete networkpolicy loadgen-to-gateway`). None of this was tried on a cluster.

## Checks for the next apply session

For everything that has been merged and not run on a cluster. Use it with `docs/runbooks/aws-eks.md`. Each step names the runbook that explains it. **First-time** means it has never run on a cluster. In every command `<EKS_CONTEXT>` is the context of the cluster. Stop at the first step that fails.

### Before the apply

1. **Merge to `main`.** Argo CD reads `main`, so none of this exists for it before then.
2. **Set the node count.** Put `node_desired_size = 4` in the local `terraform.tfvars` of `infra/terraform/environments/aws` (the variable default is 2, the module maximum 4; the last cluster used 3). Three nodes are tight when one is lost: [capacity](resilience.md#capacity).
3. **Check the seeded parameters.** Expected: all six present, none missing (the output names no value). Needs AWS credentials for the account.

   ```bash
   ./scripts/seed-secrets.sh --region eu-north-1 --profile <PROFILE> --check
   ```

   If any is missing, run it without `--check` once ([secrets runbook](secrets.md#first-time-setup)).
4. **Terraform** as in [AWS EKS](aws-eks.md#apply). Expected: the outputs `vpc_cidr_block`, `service_cidr_block`, `external_secrets_role_arn` and `secrets_parameter_prefix` exist (`terraform output`).
5. **Bootstrap, dry run first,** with every flag. The flags are `--enable-policy`, `--enable-external-secrets`, `--enable-progressive-delivery`, `--enable-data`, `--enable-observability` and `--enable-apps --apps-profile data`.

   ```bash
   ./scripts/bootstrap-argocd.sh --context <EKS_CONTEXT> --dry-run --enable-policy --enable-external-secrets --enable-progressive-delivery --enable-data --enable-observability --enable-apps --apps-profile data
   ```

   Expected: the printed cluster Secret has `"true"` for each of the labels `policy`, `external-secrets`, `progressive-delivery`, `data`, `observability` and `apps`, and the annotations `service-cidr`, `vpc-cidr`, `external-secrets-role-arn` and `secrets-prefix`. Then run it without `--dry-run`.

### After the apply, in this order

- **Step 6. All Applications are Synced and Healthy** (first time for the Kyverno, External Secrets and Argo Rollouts Applications). Give the waves ten minutes.

   ```bash
   kubectl --context <EKS_CONTEXT> -n argocd get applications
   ```

   Expected: every Application `Synced` and `Healthy`. The service Applications may retry for a few minutes while the CRDs and Secrets arrive.
- **Step 7. Network policies: DNS first** (first time for this version, which has the Service range in every egress rule). Run the three lookups of [DNS first](network-policies.md#1-dns-first). Expected: each prints an address. If one times out, stop and read that section: nothing after it can be trusted.
- **Step 8. Network policies: the API server.** The pods that call it must be working. Expected: no Prometheus target is down, and Alloy has no API errors ([targets](network-policies.md#4-prometheus-targets) and [logs](network-policies.md#5-logs-in-loki)).

   ```bash
   curl -s http://localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | select(.health != "up") | "\(.scrapePool) \(.scrapeUrl) \(.lastError)"'
   kubectl --context <EKS_CONTEXT> -n observability logs deploy/alloy -c alloy --tail=50
   ```

   (The first needs `kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090` running.) Expected: the first prints nothing; the second has no error about the API server. Then the request path ([step 2](network-policies.md#2-the-request-path)) and the data layer ([step 3](network-policies.md#3-the-services-and-the-data-layer)), with their positive controls.
- **Step 9. Kyverno** (first time): the pods, the webhooks failing open, the six policies in `Audit` and a policy report for `shop`, as in [Check after an apply](kyverno.md#check-after-an-apply). Key commands and the expected result:

   ```bash
   kubectl --context <EKS_CONTEXT> -n kyverno get deployments
   kubectl --context <EKS_CONTEXT> get validatingpolicies.policies.kyverno.io,imagevalidatingpolicies.policies.kyverno.io
   kubectl --context <EKS_CONTEXT> -n shop get policyreports.wgpolicyk8s.io
   ```

   Expected: four Deployments with one ready pod each; six policies, each with `Audit`; a report for `shop` that lists the services (an empty one after a few minutes is worth a look at the background controller). Nothing is blocked.
- **Step 10. Resilience** (first time), as in [Check after an apply](resilience.md#check-after-an-apply): the autoscalers, the budgets, the priority classes and the second PostgreSQL instance.

    ```bash
    kubectl --context <EKS_CONTEXT> -n shop get hpa,pdb
    kubectl --context <EKS_CONTEXT> get priorityclass
    kubectl --context <EKS_CONTEXT> -n data get cluster.postgresql.cnpg.io platform-pg
    ```

    Expected: an autoscaler for the gateway and for orders (minimum 2, maximum 4); a budget for the gateway, orders and payments and none for the notifier; the classes `platform-addons-critical`, `platform-apps` and `platform-observability`; the PostgreSQL cluster in a healthy state with two instances on two nodes. Then, if the cluster can be disturbed, the [drain test](resilience.md#drain-test).
- **Step 11. External secrets** (first time on a cluster; the seed script has run on real AWS): the store, the ExternalSecrets, the Secrets and the RabbitMQ default user, as in [Check after an apply](secrets.md#check-after-an-apply).

    ```bash
    kubectl --context <EKS_CONTEXT> get clustersecretstore aws-parameter-store
    kubectl --context <EKS_CONTEXT> get externalsecrets -A
    kubectl --context <EKS_CONTEXT> -n data get rabbitmqcluster platform-mq
    kubectl --context <EKS_CONTEXT> -n data logs platform-mq-server-0 --tail=50
    ```

    Expected: the store `Valid` and ready; nine ExternalSecrets, each `SecretSynced`; the RabbitMQ cluster ready and its log with no authentication error. Whether the broker accepts the default user file as built is the open question (step 9 of that section); the notifier log must show no authentication error.
- **Step 12. The controller** (first time). Expected: one ready pod under the restricted level, five CRDs, a scraped target, and the policies in place.

    ```bash
    kubectl --context <EKS_CONTEXT> -n argo-rollouts get deployments,pods
    kubectl --context <EKS_CONTEXT> get crd | grep argoproj.io
    kubectl --context <EKS_CONTEXT> -n argo-rollouts get networkpolicy
    kubectl --context <EKS_CONTEXT> -n argo-rollouts logs deploy/argo-rollouts --tail=50
    ```

    Expected: `argo-rollouts` 1/1; the CRDs `rollouts`, `analysisruns`, `analysistemplates`, `clusteranalysistemplates` and `experiments`; five policies (`default-deny`, `allow-dns`, `allow-kube-api-controller`, `controller-allow-prometheus-scrape`, `controller-allow-prometheus-query`); no error about the API server in the log. In Prometheus, `up{job="argo-rollouts"}` is 1 and `rollout_info{namespace="shop"}` has a series. If it has none, look at the label `exported_namespace`: the `honorLabels` setting is unproven.
- **Step 13. The metrics the alerts and the analysis need** (first time). In Prometheus:

    ```text
    count by (pod) (http_requests_total{service="gateway"})
    rollout_info{namespace="shop"}
    ```

    Expected: the first has one series per gateway pod, named `gateway-<hash>-<suffix>` (this confirms the `pod` label and the name pattern the analysis uses); the second has one series with `phase="Completed"`. Also check that the alerts and the dashboard load: `kubectl -n observability get prometheusrule delivery`, and open **Progressive delivery** in Grafana.
- **Step 14. The canary** (first time): the tests in [A controlled test release](#a-controlled-test-release), in this order: the starting point, the load pod, a good release, a bad release (errors, then slow), and an idle release. Expected results are with each. Write down what differs.
- **Step 15. Teardown** at the end ([teardown](#teardown)): `scripts/teardown-prep.sh`, then `scripts/teardown-argocd.sh`, then `terraform destroy`. The Rollout and its analysis runs are the new things to watch.
