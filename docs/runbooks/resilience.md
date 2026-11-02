# Resilience and autoscaling

Applies the budgets, the spread, the autoscalers, the priority classes and the second PostgreSQL instance, checks them, tests them, and says what to do when a pod is Pending or a drain is blocked. What they are and why is in [ADR-0026](../adr/0026-resilience-and-autoscaling.md); the chart is described in the [service chart README](../../deploy/helm/README.md#replicas-budgets-and-autoscaling) and the database in the [postgres chart README](../../platform/data/postgres/README.md).

**Nothing in this runbook has been run on a cluster.** The commands are written from the manifests and from the documentation of the components. Every check and test below is marked "not run" until someone runs it and writes down what differs. The output is not shown on purpose, because none has been seen. A difference is a finding.

The services scale and have budgets in the **data profile** (`--apps-profile data`). The memory profile has fixed counts: the gateway at 2, the rest at 1, and no autoscaler.

## Apply

1. **Decide the node count.** The estimates in [capacity](#capacity) say that three nodes are tight and four are comfortable. The recommendation for the next apply is `node_desired_size = 4` in the local `terraform.tfvars` of `infra/terraform/environments/aws` (the module maximum is already 4). It rests on estimates. Then run `terraform plan` and read it before `terraform apply`.
2. **Merge to `main`.** Argo CD reads the `main` branch of the repository, so none of the changes exist for it before then.
3. **Run the bootstrap script** with the flags the cluster already has. It writes every label on each run, so a flag you leave out is switched off:

   ```bash
   ./scripts/bootstrap-argocd.sh --context <EKS_CONTEXT> --dry-run --enable-policy --enable-data --enable-observability --enable-apps --apps-profile data
   ```

   Read the printed cluster Secret, then run it again without `--dry-run`. The script also writes the AppProject definitions, including `platform-apps`, which now allows `HorizontalPodAutoscaler`.
4. **Argo CD syncs in waves.** The priority classes come first (wave 0), then the add-ons, the data layer, the observability stack and the services (wave 20). If a pod is refused with `no PriorityClass with name platform-observability`, the classes have not synced yet: sync the Application `priority-classes-*` first, and the pod is created on the next retry.
5. **Expect restarts once.** Putting the PostgreSQL cluster, RabbitMQ, Valkey, Kyverno and the observability stack on priority classes changes their pod templates, so Kubernetes replaces those pods. On a cluster that still has one PostgreSQL instance that is a restart of the database, and the second instance is created and cloned from it at the same time. Do it when nothing matters. Not seen on a cluster.
6. **Switching a release from fixed replicas to the autoscaler** (gateway and orders) takes the `replicas` field out of the Deployment. The first sync can take the Deployment to one replica for a moment before the autoscaler raises it to its minimum of 2. Not seen on a cluster.
7. **Check, in this order** (below). Stop at the first check that fails.

## Check after an apply

All of these are **not run**. In every command, `<EKS_CONTEXT>` is the context of the cluster.

1. **The Applications are Synced and Healthy,** and stay Synced when the autoscaler changes a count (the Deployments have no `replicas` field for Argo CD to compare). Not run.

   ```bash
   kubectl --context <EKS_CONTEXT> -n argocd get applications
   ```

2. **metrics-server answers.** The autoscalers read CPU from the metrics API. The add-on is the Application `metrics-server-*`, a Deployment `metrics-server` in `kube-system`. Not run.

   ```bash
   kubectl --context <EKS_CONTEXT> get apiservice v1beta1.metrics.k8s.io
   kubectl --context <EKS_CONTEXT> top nodes
   kubectl --context <EKS_CONTEXT> -n shop top pods
   ```

   The APIService should be `True` under AVAILABLE. If `top` says the metrics API is not available, the autoscalers cannot work: look at the metrics-server pods and logs before anything else.
3. **The AppProject allows the autoscaler.** Not run.

   ```bash
   kubectl --context <EKS_CONTEXT> -n argocd get appproject platform-apps -o yaml | grep -B1 HorizontalPodAutoscaler
   ```

4. **The priority classes exist, and the pods use them.** Three classes of ours are expected: `platform-addons-critical`, `platform-apps` and `platform-observability`. Not run.

   ```bash
   kubectl --context <EKS_CONTEXT> get priorityclass
   kubectl --context <EKS_CONTEXT> get pods -A -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,CLASS:.spec.priorityClassName'
   ```

   Expected: the pods in `data`, `cnpg-system`, `kyverno`, `cert-manager` and `external-dns` on `platform-addons-critical`; the pods in `shop` on `platform-apps`; the pods in `observability` on `platform-observability`. Two exceptions are expected to show `<none>`: the RabbitMQ Cluster Operator in `rabbitmq-system`, and Kyverno's migration Job if it is running. Pods in `argocd` also have no class.
5. **The autoscalers.** One for the gateway and one for orders, named after the Deployments. Not run.

   ```bash
   kubectl --context <EKS_CONTEXT> -n shop get hpa
   kubectl --context <EKS_CONTEXT> -n shop describe hpa gateway orders
   ```

   Expected: MINPODS 2 and MAXPODS 4, a CPU target of 70 percent, and a current value that is not `<unknown>`. In `describe`, `AbleToScale` and `ScalingActive` should be `True`. `<unknown>` means the metrics API does not answer (check 2) or the pods have no CPU request.
6. **The disruption budgets.** One for each service that starts with more than one replica: the gateway, orders and payments. None for the notifier. Not run.

   ```bash
   kubectl --context <EKS_CONTEXT> -n shop get pdb
   ```

   Expected: `MAX UNAVAILABLE` 1 and `ALLOWED DISRUPTIONS` 1 for each. A 0 there with all pods ready means the selector does not match the pods.
7. **The spread.** The pods of one service should be on different nodes, and the nodes in different zones where the cluster has them. Not run.

   ```bash
   kubectl --context <EKS_CONTEXT> get nodes -L topology.kubernetes.io/zone,eks.amazonaws.com/capacityType
   kubectl --context <EKS_CONTEXT> -n shop get pods -o wide
   ```

   The spread is a preference (`ScheduleAnyway`): two pods on one node are possible when that is the only place with room, and are not an error.
8. **The PostgreSQL cluster.** Two instances, `platform-pg-1` and `platform-pg-2`, one of them the primary, on different nodes. Not run.

   ```bash
   kubectl --context <EKS_CONTEXT> -n data get cluster.postgresql.cnpg.io platform-pg
   kubectl --context <EKS_CONTEXT> -n data get cluster.postgresql.cnpg.io platform-pg -o jsonpath='{.status.currentPrimary}'; echo
   kubectl --context <EKS_CONTEXT> -n data get pods -l cnpg.io/cluster=platform-pg -o wide
   kubectl --context <EKS_CONTEXT> -n data get pvc
   kubectl --context <EKS_CONTEXT> -n data get pdb
   ```

   Expected: the status `Cluster in healthy state` with 2 ready instances; two pods on two nodes; two claims for the cluster (`platform-pg-1`, `platform-pg-2`) next to `platform-valkey`; the disruption budgets that the operator created. The chart creates none of them. With the CloudNativePG plugin installed (see [the switchover test](#postgresql-switchover-test)), `kubectl cnpg status platform-pg -n data` also shows the streaming replication of the primary.
9. **The replica is streaming.** The replica connects to the primary through the `platform-pg-rw` Service, which this CNI matches against the Service address. The network policy rules cover it. If the replica does not become ready, or the status shows it is not streaming, read its log and then the [network policy runbook](network-policies.md#see-what-is-being-dropped). Not run.

   ```bash
   kubectl --context <EKS_CONTEXT> -n data logs <the replica pod> -c postgres --tail=50
   ```

10. **The alerts are loaded.** The PrometheusRule `scaling` has four alerts in the group `scaling-and-capacity`. Not run.

    ```bash
    kubectl --context <EKS_CONTEXT> -n observability get prometheusrule scaling
    kubectl --context <EKS_CONTEXT> -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090
    ```

    Open <http://localhost:9090/rules> and look for `HpaAtMaxReplicas`, `PodDisruptionBudgetBlocked`, `PodsPending` and `PostgresInstancesNotReady`; all four should be inactive and healthy. Then check that the metrics they read exist, in the expression browser:

    ```text
    kube_horizontalpodautoscaler_status_desired_replicas{namespace="shop"}
    kube_poddisruptionbudget_status_pod_disruptions_allowed{namespace="shop"}
    sum(kube_pod_status_ready{namespace="data", pod=~"platform-pg-[0-9]+", condition="true"})
    count(kube_persistentvolumeclaim_info{namespace="data", persistentvolumeclaim=~"platform-pg-[0-9]+"})
    ```

    The last two should both be 2. If they differ, the alert for the PostgreSQL instances is about to fire or is wrong. What each alert means is in the [alert runbook](alerts.md#alerts-for-scaling-and-capacity).

## Load test

This is a suggestion. The repo has no load tool, and the smoke test is the closest thing to one that already exists. It is not a load generator: it sends about twenty requests and checks the answers. Repeated in several shells it can raise the CPU of a gateway pod. Not run.

A port-forward goes to a single pod and does not use the network policies of the pods, which is why it works from outside the cluster. So the load lands on one gateway pod, and the autoscaler looks at the average over the pods.

```bash
kubectl --context <EKS_CONTEXT> -n shop port-forward svc/gateway 8080:8080 &
kubectl --context <EKS_CONTEXT> -n shop port-forward svc/notifier 8083:8083 &
for i in 1 2 3 4; do (while true; do ./scripts/smoke-test.sh > /dev/null 2>&1; done) & done
kubectl --context <EKS_CONTEXT> -n shop get hpa -w
```

Each pass creates real orders in the data profile. Stop with `kill %1 %2 %3 %4 %5 %6` (the job numbers that `jobs` shows).

What to look for, and what is not known:

- The CPU target should rise above 70 percent and `REPLICAS` should grow, up to 4, within a few minutes. The target is a share of the CPU request (20m for the gateway, 50m for orders), so the absolute load that moves it is small, and it is not known how much of it the probes and the scrapes already are.
- New pods should start on other nodes where there is room (`kubectl -n shop get pods -o wide`).
- After the load stops, the autoscaler should wait five minutes and then go back towards 2.
- If the maximum is reached and holds for 15 minutes, `HpaAtMaxReplicas` fires. The test is too short to show it unless it runs that long.

## Drain test

A drain evicts the pods of one node. Do it on a cluster you can break, one node at a time, and watch what each budget does. `emptyDir` volumes (payments, Loki, Prometheus) need `--delete-emptydir-data`. With three nodes and the requests in [capacity](#capacity), some pods may stay Pending until the node is back. Not run.

```bash
kubectl --context <EKS_CONTEXT> get pods -A -o wide --field-selector spec.nodeName=<node>
kubectl --context <EKS_CONTEXT> drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=300s
kubectl --context <EKS_CONTEXT> uncordon <node>
```

What to expect from each budget, from the manifests and the documentation of the components:

| Pod | Budget | Expected during the drain |
| --- | --- | --- |
| gateway, orders, payments | `maxUnavailable: 1` | One pod is evicted. The next one waits until the replacement is ready on another node, because the budget allows no second disruption in the meantime. The drain prints that it cannot evict and retries |
| notifier | none (one replica) | Evicted at once. It is down until it starts elsewhere. Events wait in the queue |
| PostgreSQL replica | the operator's budget | Can be evicted. The cluster has no standby until it is back |
| PostgreSQL primary | the operator's budget | Per the documentation of the operator (version 1.30), the drain waits. A switchover (below) moves the primary off the node and lets it continue. A Spot reclaim does not wait: the node goes after two minutes, and the replica is promoted |
| Valkey, RabbitMQ | none in the standard profile | Evicted at once. They are down until their pods start elsewhere. The orders outbox keeps events meanwhile |
| Prometheus, Grafana, Loki, Tempo, the collector | none | Evicted at once. Data in `emptyDir` is lost, as before |

While it runs, watch `kubectl -n shop get pdb`, `kubectl -n shop get pods -w` and the SLOs dashboard. Afterwards check [the alerts](#check-after-an-apply) are quiet.

## PostgreSQL switchover test

A switchover moves the primary to the replica on purpose. The commands are from the documentation of CloudNativePG 1.30, the version of the pinned operator (chart 0.29.1, application 1.30.1); that page was read, and the commands have not been run. They need the `kubectl cnpg` plugin, which this repository does not install; its installation is in the same documentation. Not run.

```bash
kubectl cnpg status platform-pg -n data
kubectl cnpg promote platform-pg platform-pg-2 -n data
kubectl --context <EKS_CONTEXT> -n data get cluster.postgresql.cnpg.io platform-pg -w
```

Use the instance that is not the primary in `promote` (the first command, or the `jsonpath` of check 8, says which). Both the cluster name and the instance are positional. The second form of the command accepts the instance number.

What to look for: the status moves through a switchover and returns to healthy; `status.currentPrimary` changes to the other instance; the services keep using `platform-pg-rw` and reconnect, so orders and payments may log connection errors for a short time and the orders pod may go not ready while it reconnects. Read the SLOs dashboard during the switchover. A switchover is a planned promotion; the loss window of asynchronous replication is about a **failover**, when the primary is lost without a clean stop, and the size of that window is not known. To see a failover, delete the primary pod, and only on a cluster where nothing matters.

After it, run check 8 again and make sure the old primary has come back as a replica and is streaming.

## A pod is Pending

Start with `kubectl -n <namespace> describe pod <pod>` and read the events. The alert is [pods-pending](alerts.md#pods-pending).

- **`Insufficient cpu` or `Insufficient memory`.** The cluster is full. Look at the Cluster capacity dashboard and the numbers in [capacity](#capacity). Options: wait for a replacement node, add a node (`node_desired_size`), or lower what is requested (a smaller autoscaler maximum in `deploy/helm/values/<service>-data.yaml`). A service pod can push out observability pods and pods with no class to make room; it cannot push out the database.
- **`volume node affinity conflict`.** The volume of a PostgreSQL instance is in one zone and no node there has room. The instance has to start in the zone of its volume. Add a node in that zone.
- **`didn't match pod anti-affinity rules`.** Only with the `required` type, which the high availability profile uses. The dev profile prefers separate nodes and does not require them.
- **`ImagePullBackOff`.** The image or its pull secret. Compare the digest in `deploy/helm/values/images.yaml` with the registry.

## A drain is blocked

`kubectl drain` prints `Cannot evict pod ... disallowed by the PodDisruptionBudget` and retries. That is the budget working. Find out why it allows no disruption: `kubectl -n <namespace> get pdb` and then the pods behind it. Usually one pod is not ready (see [pod-disruption-budget-blocked](alerts.md#pod-disruption-budget-blocked)). Fix that pod and the drain continues. Do not delete the budget. For the database primary, switch over first (above). If a drain must go ahead at once, for a node that is failing, `--disable-eviction` deletes the pods and ignores every budget; use it only for that.

## Capacity

These numbers are **estimates**, from the Cluster capacity dashboard reading of 2026-11-02 and [ADR-0020](../adr/0020-metrics-stack.md). Nothing was measured for this work, and the requests were not summed from a render of every chart.

| Item | CPU | Memory |
| --- | --- | --- |
| Allocatable, three Spot nodes (`t3.large` or `m5.large`) | about 5.85 vCPU | about 20.4 GiB |
| Requested before this work, with Kyverno | about 3.7 vCPU | about 7.0 GiB |
| The second PostgreSQL instance | +250m | +512Mi |
| Gateway and orders at the autoscaler maximum (4 each) | +140m (gateway +40m, orders +100m) | +256Mi (gateway +64Mi, orders +192Mi) |
| Left, with everything at its maximum | about 1.7 vCPU | about 12.2 GiB |

CPU is the limit. With **one node lost** two nodes hold about 3.9 vCPU and the requests are about 3.95 vCPU, slightly more, so a pod can stay Pending until a replacement node arrives. Four nodes would hold about 7.8 vCPU. The recommendation for the next apply is therefore `node_desired_size = 4`. It follows from estimates; check it against the Cluster capacity dashboard after the apply, and change the number if the dashboard says otherwise. Without a Cluster Autoscaler or Karpenter the node count is a number in Terraform and nothing adds a node by itself (see the alternatives in the ADR).

The second PostgreSQL volume is another 5 GiB EBS volume. The Cluster capacity dashboard shows the requested and allocatable CPU and memory, and the pods per node.

## Teardown

Nothing new is needed. `scripts/teardown-prep.sh` deletes every claim in the `data` namespace, so both PostgreSQL claims, and checks that no EBS volume tagged for a claim is left; the autoscalers and budgets go with their Applications. The scripts were tested against a fake `kubectl` and a fake `aws` with two claims and two volumes, not against a cluster. See the [data layer runbook](data-layer.md#teardown).

## Known limits

- **The notifier runs one replica.** Its duplicate detection and its store of notifications are in memory, per pod. It has no budget, so a drain takes it down until it starts elsewhere. It stays at one until that state is shared.
- **Orders in the memory profile is one pod** and keeps its orders in the pod. The memory profile has no autoscaler.
- **Payments is fixed at two.** It is safe with more; it is not scaled until there is load data.
- **RabbitMQ and Valkey are single instances.** A node loss stops them until their pods run elsewhere. RabbitMQ would need three nodes and quorum queues, which is future work.
- **Replication is asynchronous.** After a failover the most recent committed transactions can be missing on the new primary. The size of that is not known. The replica is not a backup, and no backups are configured.
- **The autoscaler thresholds are small.** A gateway pod scales out at about 14m of average CPU and an orders pod at about 35m, because the target is a share of the request. This needs real load data.
- **The node-loss capacity is tight** (see [capacity](#capacity)).
- **Pods with no class rank below the services.** Argo CD is one of them.
- **The alert for the PostgreSQL instances hard-codes the names `platform-pg-N`.**
- **Not proven:** real replication, failover and switchover; how the VPC CNI treats the replica's connection; the operator's budgets during a drain; the replica rebuild time after a Spot loss; preemption; whether the alerts fire on real metrics; the autoscalers under real load; `matchLabelKeys` on the cluster (the renders pass kubeconform for Kubernetes 1.36 and 1.37, and the versions documented for the Kyverno release are 1.33 to 1.35).
