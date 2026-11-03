# ADR-0026: Resilience and autoscaling

- Status: Accepted
- Date: 2026-11-02

## Context

The services run on three Spot nodes that can be taken away with two minutes of notice. Until now each service ran at a fixed count, the database was a single instance, and nothing said what should happen to a pod when its node was drained or when the cluster was full. The run of 2026-11-02 showed what that costs: a Spot node was replaced, and PostgreSQL, a single instance, was down until its pod ran again somewhere else ([observability evidence](../observability-evidence.md)). It recovered by itself.

Three things were missing. The services could not follow load. A node drain or a Spot replacement could take all pods of a service at once, and nothing ranked the pods against each other, so an autoscaler adding a service pod on a full cluster could have pushed the database off a node. And the database had no second copy.

This change defines all of it in Git and checks it without a cluster. **Nothing in it has run on a cluster.** Every statement below about how the platform behaves is what the manifests and the documentation of the components say, not something observed here.

## Decision

Budgets, spread and autoscaling in the service chart, a priority order for the whole platform, a second PostgreSQL instance, and four alerts for the new objects.

### Which services may have more than one replica

A service gets a second replica only when its state is outside the pod. The code was read for each one.

| Service | Profile | Replicas | Why |
| --- | --- | --- | --- |
| gateway | memory | 2, fixed | Keeps no state. Fixed because the memory profile is the small, predictable one |
| gateway | data | 2 to 4, HPA | Keeps no state |
| orders | memory | 1 | The orders are kept in the pod, so a second replica would see half of them |
| orders | data | 2 to 4, HPA | The outbox relay takes its batch with `FOR UPDATE SKIP LOCKED` and sets `published_at` only after the broker confirms, and a test covers two relays running together. An order leaves `pending` only through `UPDATE ... WHERE status = 'pending'`, and the idempotency key is a unique key |
| payments | memory | 1 | In-memory repository |
| payments | data | 2, fixed | Safe with more (the unique idempotency key with `ON CONFLICT DO NOTHING` decides), but not scaled. A JVM uses a burst of CPU while it starts and warms up, which would read as load against a request of 100m. An autoscaler waits until there is load data to size it from |
| notifier | both | 1 | Its duplicate detection and its store of notifications are in memory, per pod. A redelivered event can reach a pod that has not seen it, and a request for the list of notifications would show only what that pod recorded |

Orders in the data profile publishes at least once, and the order of events is not kept across replicas, because two relays take different batches. The notifier stores each event under its own ID and does not depend on the order. The notifier stays at one replica until its state is shared, and scaling it by queue depth is future work (see the alternatives).

### Budgets, spread and rollout

- **PodDisruptionBudget** with `maxUnavailable: 1`, rendered only when the service starts with more than one replica (`replicas`, or `autoscaling.minReplicas`). On one replica a budget blocks every drain and every Spot replacement.
- **Topology spread** over `kubernetes.io/hostname` and `topology.kubernetes.io/zone`, `maxSkew` 1, with `matchLabelKeys: pod-template-hash` so that the pods of the old and the new ReplicaSet of a rollout are counted apart. The mode is the value `topologySpread.whenUnsatisfiable`: `ScheduleAnyway` here, which prefers the spread and never leaves a pod Pending for it; a production profile can set `DoNotSchedule`.
- **Rolling update** with `maxUnavailable: 0` and `maxSurge: 1`, as before. The grace period is 35 seconds against 30 needed (5 seconds of `preStop` sleep, 5 of drain, 20 for requests in flight). All four services fail `/readyz` on SIGTERM and drain. A check fails if the grace period is shorter than the sum.

### Autoscaling

A HorizontalPodAutoscaler (`autoscaling/v2`) for the gateway and orders in the data profile only, on CPU at 70 percent of the request, with a minimum of 2, a maximum of 4 and a scale-down window of five minutes. Scaling up is not delayed. The memory profile has none.

When the autoscaler is on, the Deployment has no `replicas` field, so Argo CD has nothing to put back when the count changes and no `ignoreDifferences` is needed. The chart refuses to render with both. The `platform-apps` AppProject allows `HorizontalPodAutoscaler`; without that the sync would be refused.

The target is a share of the request, and the requests are small (20m for the gateway, 50m for orders), so a gateway pod scales out at about 14m of average CPU and an orders pod at about 35m. Probes and scrapes alone may hold a pod above its minimum. This needs real load data at the next apply.

### Priority order

| Class | Value | Used by |
| --- | --- | --- |
| `system-*` | built in | the pieces in `kube-system` (the load balancer controller, metrics-server) |
| `platform-addons-critical` | 1,000,000 | the add-ons, Kyverno, the PostgreSQL cluster, the RabbitMQ cluster, Valkey, the CloudNativePG operator and the data hook Jobs |
| `platform-apps` | 100,000 | the four services |
| `platform-observability` | 10,000 (new) | the metrics, logging and tracing stack |

The data layer was already on `platform-addons-critical`, so no separate data class was added. The data layer and the controllers share a class, which means they never preempt each other. A service pod that cannot be placed can push out observability pods and pods with no class, but not the database. Two things cannot be given a class: the RabbitMQ Cluster Operator, a vendored manifest that is checked against a SHA-256, and the migration Job of the Kyverno chart, which has no setting for it. Both are named as exceptions in the check that looks at every pod.

### PostgreSQL

Two instances in the data profile, a primary and one replica (`cluster.instances`, back to one by value), 250m CPU and 512Mi memory requested for each, and a 5 GiB volume for each.

- **Asynchronous replication** (`minSyncReplicas` and `maxSyncReplicas` are 0). The primary acknowledges a commit without waiting for the replica. If the primary is lost, the replica is promoted, and the most recent committed transactions can be lost. This ADR gives no figure, because it depends on the load and the network and has not been measured. The replica is not a backup: no backups are configured, and a dropped table is replicated.
- **Placement.** Anti-affinity over the hostname, `preferred` in the data profile so that a cluster with fewer nodes than instances still runs them and `required` in the high availability profile, and a zone spread (`zoneSpread`, `ScheduleAnyway` here and `DoNotSchedule` in the high availability profile).
- **Updates.** `primaryUpdateStrategy: unsupervised` and `primaryUpdateMethod: switchover`: the replica is updated first, then the primary is switched over to an updated replica instead of being restarted in place. `switchoverDelay` is 300 seconds. The operator refuses an update that changes the image and the PostgreSQL parameters together while the method is switchover.
- **Budgets.** The operator creates and owns the budgets of the cluster (`enablePDB`, on above one instance). The chart renders none, and a check fails if one appears. From the operator's documentation: a drain that finds the primary on the node waits, and a Spot reclaim does not wait and the replica is promoted.
- **Access.** The services keep using `platform-pg-rw`, which points at whichever instance is the primary. No pod name is configured anywhere. A replica streams from the primary through the same Service, so with this CNI the egress rule is matched against the Service address; the rules and the flow matrix from [ADR-0024](0024-network-policies.md) already cover it, and denied flows were added next to them.

RabbitMQ and Valkey stay single instances. RabbitMQ would need three nodes and quorum queues, which is future work.

### Alerts

Four tickets, none of them pages, in the PrometheusRule `scaling`: `HpaAtMaxReplicas` (15 minutes), `PodDisruptionBudgetBlocked` (30 minutes, `shop` only, because the budget for the database primary allows no disruption by design), `PodsPending` (10 minutes, `shop` and `data`) and `PostgresInstancesNotReady` (10 minutes). CloudNativePG exports no metric for the number of instances the Cluster asks for, so the last one counts the volume claims named `platform-pg-N` against the ready pods named the same, using kube-state-metrics; the rule hard-codes that naming. The runbook entries are in the [alert runbook](../runbooks/alerts.md#alerts-for-scaling-and-capacity).

## Alternatives considered

- **KEDA, scaling the notifier by queue depth.** It would give the notifier a count that follows its work, which CPU cannot do for a consumer that waits on a queue. Not in this change, because the notifier cannot have a second replica until its duplicate detection and its store are shared; scaling something that is wrong with two replicas adds nothing. When that state is shared, queue depth is the signal to scale on.
- **Synchronous replication.** It would remove the loss window: a commit is acknowledged after the replica has it. The price is that writes stop when no replica can confirm them, and with one replica on a Spot node that is every node replacement. For a development cluster that costs more than the window does. A profile with three instances and a quorum could take it.
- **A hard spread rule (`DoNotSchedule`).** It would keep the pods of a service on separate nodes and zones always. On a small cluster it leaves a pod Pending whenever a node is gone, which is the opposite of what a Spot cluster needs. It stays a value for a production profile.
- **Cluster Autoscaler or Karpenter.** It would add a node when pods are Pending and remove one when it is empty, so capacity would follow the HPA instead of being a fixed count. It is a bigger change (IAM, node group tags or a provisioner, a new controller in the cluster) and is not needed to try the objects in this ADR. Until it exists, capacity is the node count in Terraform.
- **A separate priority class for the data layer.** It would put the data layer under the controllers. The data layer was already on `platform-addons-critical`, nothing needs the controllers to preempt it, and a new class would be another place to keep in order.
- **Autoscaling payments on CPU.** It is safe, and it was left out for the reason above. It is a values change once there is data.

## Consequences

- **The capacity for losing a node is tight.** Estimates, from the dashboard reading of 2026-11-02 and [ADR-0020](0020-metrics-stack.md), not measured: about 5.85 vCPU and 20.4 GiB allocatable on three nodes. Before this change about 3.7 vCPU and 7.0 GiB were requested, including Kyverno. The replica adds 250m and 512Mi, and the services at the HPA maximum add 140m and 256Mi, which leaves about 1.7 vCPU and 12.2 GiB. With one node lost the requests (about 3.95 vCPU) are slightly above what two nodes hold (about 3.9 vCPU), so a pod can stay Pending until a replacement node arrives. The recommendation for the next apply is a local `node_desired_size` of 4 (the module maximum is already 4). It rests on estimates.
- **The notifier is a limit.** One pod, no budget, and a node drain takes it down for as long as it takes to start elsewhere. Events wait in the queue meanwhile.
- **Orders in the memory profile is one pod,** for the same kind of reason: its data is in the pod.
- **The data-loss window is real** with asynchronous replication, and its size is unknown.
- **RabbitMQ and Valkey are still single.** A node loss stops them until their pods run elsewhere. The outbox keeps the events meanwhile.
- **Changing the pod specs restarts pods once.** Moving the data layer, Kyverno and the observability stack onto priority classes changes their pod templates, so they are replaced. While the database has one instance that is a restart of the database. The first sync after switching a release from fixed replicas to the autoscaler can also take the Deployment to one replica for a moment before the autoscaler raises it to the minimum.
- **Pods with no class rank below the services.** Argo CD, for one, has no priority class, so a service pod can push it out on a full cluster. That is not changed here.
- **The alerts depend on metric names** from kube-state-metrics 2.20 and on the naming `platform-pg-N`.

## What is proven offline and what is not

Proven by checks that run without a cluster:

- Every service and profile renders the replicas or the autoscaler in the table above, with no `replicas` next to an autoscaler, a budget exactly when there is more than one replica, the spread, the rollout and a grace period that covers the drain. A service with in-memory state cannot be given a second replica without a check failing. The renders pass kubeconform for Kubernetes 1.36 and 1.37 and are allowed by the AppProject.
- The PostgreSQL cluster renders one, two or three instances as asked, with the instances kept off one node, asynchronous replication, switchover updates, the operator's budgets and no budget of our own.
- Every pod of the data layer, Kyverno and the observability stack has its class, except the two named exceptions, and the classes keep their order.
- The network policies and the flow matrix, including the replica's streaming through the Service and the denied flows beside it (2242 flows in the data profile, 194 allowed; 108 in the memory profile, 52 allowed). The Kyverno policies still pass (350 results, and the reality check on 13 workloads).
- The four rules pass `promtool` lint and unit tests, including the cases that must stay quiet, and each runbook link points at a heading that exists.
- The teardown scripts delete both PostgreSQL claims and check for two leftover volumes, against the fake `kubectl` and the fake `aws`.

Not proven, because it needs a cluster:

- Real replication, failover and switchover, and how long a replica takes to rebuild after a Spot loss.
- How the VPC CNI treats the replica's connection to the primary. That the replica connects through the `-rw` Service is the default behaviour of CloudNativePG; it has not been seen here.
- The operator's budgets during a drain, which are described above as the documentation describes them.
- Preemption: that a service pod never pushes out the database.
- The autoscaler under real load, at 70 percent of a small request, and the scale-down after five minutes.
- Whether the alerts fire on real metrics.
- `matchLabelKeys` on the cluster. The renders pass kubeconform for 1.36 and 1.37, and the Kubernetes versions documented for the Kyverno release are 1.33 to 1.35.
- The capacity numbers, which are estimates.
