# ADR-0018: Secret generation, ordering and teardown

- Status: Accepted
- Date: 2026-10-29

## Context

The first run of the data layer and the services on a real EKS cluster found three problems:

1. The `data-secrets` and `data-rabbitmq-credentials` charts contained only Helm hooks. Argo CD reported both Applications Synced and Healthy without ever starting a sync (there was no `operationState`), so the generator Jobs never ran and none of the Secrets existed. Valkey waited in `Init` for `valkey-auth`.
2. The CloudNativePG `Cluster` was applied before `pg-orders` and `pg-payments` existed. Its managed roles stayed `pending-reconciliation` ("failed to get password secret"), the `Database` resources failed ("role does not exist"), and the orders migration failed with "password authentication failed" until the roles caught up.
3. Teardown by deleting Applications did not work (the ApplicationSets recreated them), and deleting a `RabbitmqCluster` left its StatefulSet, pod and claim behind.

### What the real run showed

These are the observations from the first run on EKS; they were reported from that cluster and are not something this repository's automation produced or could re-run.

- Both credential Applications were Synced and Healthy with no `operationState`, and none of the seven Secrets existed. Valkey waited in `Init`.
- The `Cluster` was applied before `pg-orders` and `pg-payments`. The managed roles stayed `pending-reconciliation` ("failed to get password secret pg-orders: secrets not found") and the `Database` resources failed ("role orders does not exist"). **After the Secrets appeared, the roles stayed pending for about 17 minutes and only reconciled after a manual annotation on the `Cluster`.** The orders migration failed with "password authentication failed" until a later retry.
- Deleting Applications by hand made the ApplicationSets recreate them, because the cluster Secret still carried the `platform.example/apps` and `platform.example/data` labels.
- Deleting the `RabbitmqCluster` left its StatefulSet and pod running, so the claim stayed `Bound` until the StatefulSet was deleted by hand. Deleting the `Cluster` removed its pod and claim correctly. The Valkey claim had to be deleted explicitly.

This ADR changes [ADR-0014](0014-data-layer.md) (how credentials are generated) and [ADR-0016](0016-service-deployment-model.md) (how the RabbitMQ credentials are copied, and how migrations wait) and corrects the teardown procedure.

## Decision

The hook blind spot: an Application that renders only hooks has nothing to compare

Argo CD starts an automated sync when the live state differs from the rendered resources. Hooks are not compared, so a chart that renders only hooks is permanently in sync and nothing ever starts the operation that would run them. This was reproduced on a local cluster with the pinned Argo CD (a hooks-only chart: Synced, Healthy, no operation, no Job). The fix is to make sure each chart renders at least one ordinary resource.

Credential generation: ordinary RBAC objects and a Sync hook Job

- The ServiceAccount, Roles and RoleBindings (and a ConfigMap listing the Secret names, never values) are ordinary resources in sync wave -5. They give the Application something to sync, so the first sync starts by itself, and they stay in place, visible with `kubectl`.
- The generator is a Job annotated as an Argo CD **Sync hook**, wave 0, with `hook-delete-policy: BeforeHookCreation,HookSucceeded`, `ttlSecondsAfterFinished` (a failed Job is kept for an hour), a `backoffLimit` and an `activeDeadlineSeconds`, and the restricted security context. It creates each Secret only if it does not exist and never regenerates or overwrites a password (tested: re-syncing left `pg-orders` unchanged).
- **Why not a plain (non-hook) Job with a TTL.** The task asked for evaluating this. On a local cluster with the pinned Argo CD, a regular Job with `ttlSecondsAfterFinished: 15` was deleted by the TTL controller, Argo CD saw a missing resource, reported the Application `OutOfSync`, and recreated and re-ran the Job again and again (a new Job roughly every minute, alternating Synced and OutOfSync). Nothing in `ignoreDifferences` or the sync options covers a resource that is missing from the live state. A regular Job without a TTL is stable, but it is immutable (a changed script needs `Replace` or a renamed Job) and it never cleans up. A Sync hook is not compared with the live state, so its disappearance changes nothing and it runs again only when a sync runs, which is exactly when it should. The same charts, run through Argo CD on the local cluster, stayed Synced and Healthy for the observation period with the Job started once.
- **Why not a reconciler Deployment.** A long-running idempotent loop would also heal a deleted Secret, but it needs a permanent pod per chart on small nodes and standing permission to create Secrets. The hook Job needs neither. Secrets that are deleted by accident are recreated by the next sync (`kubectl -n argocd patch application ... -p '{"operation":{"sync":{}}}'`), and the runbook says how.
- The two PostgreSQL role Secrets carry `cnpg.io/reload: "true"` (the generator adds it to existing ones, which needs `patch` on those two names), so CloudNativePG watches them. The documented effect is that password changes are applied promptly.

Ordering: what is enforced, and what is not

- **Sync waves order resources inside one Application. Between Applications they do not enforce anything.** The `apps/` directory holds ApplicationSets, so a wave on one orders only when the ApplicationSet objects are created; Argo CD does not wait for the Applications they generate. Argo CD removed its built-in health assessment of `Application` resources in 1.8, and without it an app-of-apps wave does not wait for a child to become healthy either (restoring it is an `argocd-cm` customization the platform does not make). ApplicationSet progressive syncs (`RollingSync`) are beta in the pinned 3.x line, are disabled unless the controller is configured, apply within a single ApplicationSet only, and turn automated sync off for the Applications they manage; the data layer is eight ApplicationSets, so that would not order them and would cost automated sync.
- The waves in `platform/argocd/apps` are kept as the order of intent (secrets 6, then PostgreSQL, Valkey and RabbitMQ 7, the credential copy 8) and the files say so, but **each consumer waits for what it needs**, so the order holds whatever Argo CD does:
  - **PostgreSQL:** a PreSync gate Job in the `data-postgres` chart waits until `pg-orders` and `pg-payments` exist before the `Cluster` or the `Database` resources are applied. Tested: with no Secrets the sync stayed in PreSync with no `Cluster`; when `data-secrets` created them the gate released and the `Cluster` was applied with its roles reconciled and both databases applied. If the Secrets never appear the gate fails after 15 minutes, the sync stops without touching anything, and Argo CD retries with backoff. It needs a Role that can only `get` the named Secrets, which exists only during the sync.
  - **Valkey:** the chart's pod waits in `Init` for `valkey-auth` and starts when it appears (observed in the real run); it self-heals.
  - **RabbitMQ credential copy:** the Job waits inside the process (up to 25 minutes, polling every 10 seconds) for the operator to create `platform-mq-default-user`, so the wait does not use up the Job's retries.
  - **Services:** their pods stay in `CreateContainerConfigError` until the Secrets exist and the kubelet retries; their migration Jobs wait for the database (below).
- Guarantee: the `Cluster` is never applied before its role Secrets exist, and no consumer starts working with a missing credential. Not guaranteed: that the generators run before the consumers' Applications are *created*, that an unrelated Application is healthy before another syncs, or that anything is recreated when a Secret is deleted by hand without a sync.

PostgreSQL managed roles and late Secrets

- **In the real run the managed roles stayed `pending-reconciliation` for about 17 minutes after the Secrets appeared and needed a manual nudge. My local tests could not reproduce that.** On a local cluster with CloudNativePG 1.30.1, a `Cluster` applied before its role Secrets left the roles `pending-reconciliation` with "failed to get password secret", exactly as in the real run, but once the Secrets were created the roles became `reconciled` without any nudge within about two minutes, whether the Secret carried the `cnpg.io/reload` label or not; a second experiment (a new role whose Secret appeared after a two and a half minute wait) behaved the same. So the operator retries pending roles on a period of about two minutes locally. Why the real cluster took far longer is not established; I did not find the cause, and I have not shown that the `cnpg.io/reload` label changes the timing.
- **The PreSync gate is therefore the primary fix, and the nudge is only a fallback.** The gate keeps the `Cluster` from being applied until the Secrets exist, so the roles never start out pending, whatever the operator's retry timing is. The gate was tested (see Verification). The annotation `platform.example/reconcile-nudge` on the `Cluster` makes the operator look at its roles immediately; it is documented in the runbook for a cluster that is already in the bad state. It is safe: Argo CD ignores extra annotations (the Application stayed Synced and Healthy) and it changes nothing else. It is not part of any automated path.
- The role Secrets carry `cnpg.io/reload: "true"`, the documented way to make the operator watch a Secret, as a precaution.

Migrations wait for the database

- `python -m orders.migrate` and `java -jar payments.jar migrate` accept `MIGRATE_WAIT_SECONDS` (default 0, so a local run still fails fast) and `MIGRATE_RETRY_INTERVAL_SECONDS` (default 5). When the failure means "not ready" (connection refused, timeout, unknown host, SQLSTATE `28P01` bad password, `28000` role missing, `3D000` database missing, `57P03` starting up, `53300` too many connections, any `08xxx`), they log `database not ready` with the attempt and the time waited, sleep, and try again until the wait is spent; other errors (a bad migration, a checksum mismatch) fail at once. The chart sets 780 seconds, below the Job's 900-second deadline.
- The waiting happens inside the pod, so an early failure does not consume the Job's `backoffLimit` (the earlier behaviour: the pod exited, Kubernetes restarted it with a growing backoff, and a database that took a few minutes used the budget up). Flyway's own connection retries are turned off while waiting so they do not stretch each attempt.

Teardown

- The labels `platform.example/apps` and `platform.example/data` on the cluster Secret select clusters; deleting an Application by hand is undone by the ApplicationSet. Teardown therefore starts by **deleting the two label keys** (`kubectl label secret cluster-in-cluster platform.example/apps- platform.example/data-`), then waits for the Applications to disappear. Setting the labels to `false` also works: the selectors in `platform/argocd/apps` are `matchLabels` equal to `"true"`, and this was verified on a throwaway cluster with the pinned ApplicationSet controller (`apps=false` removed the generated Application within seconds, as did deleting the key; deleting the Application by hand while the label was `true` made it come back). One earlier attempt with `false` had not converged after a minute and the next converged in four seconds, so the script waits with a timeout instead of assuming a speed. Removing the keys is what the runbooks and the script do; re-running the bootstrap script writes `false` again, which is equivalent.
- Resources marked `Prune=false,Delete=false` stay by design. The order that follows from the real run: wait for the `shop` namespace to empty; delete the CloudNativePG `Cluster` (this removes its pod and claim) and the `RabbitmqCluster`, then the RabbitMQ StatefulSet if its pod survives (it does); delete the remaining claims, including `platform-valkey`; confirm `kubectl get pv` is empty; confirm with the AWS CLI that no volume tagged `kubernetes.io/created-for/pvc/name` remains, so only node root volumes are left; check for load balancers and for security groups created by the AWS Load Balancer Controller (both tagged `elbv2.k8s.aws/cluster`); then `terraform destroy`.
- `scripts/teardown-prep.sh --context CTX` runs these steps in that order, with waits and a timeout per step, and stops at the first step that does not finish. It deletes only named resources in the `argocd`, `shop` and `data` namespaces, never forces a deletion, and has a `--dry-run`. It is tested against a fake `kubectl` and `aws` (`scripts/test-scripts.sh`); it has not been run against a real cluster.

Checks that would have caught these problems

- `scripts/chart-contract-check.py`, run from `make data-check-manifests`, `make deploy-check` and `make argocd-check`, fails when a chart under `platform/data` renders only hook resources, when a Job that creates Secrets is a Helm hook (an Argo CD hook is allowed), when the PostgreSQL chart has no PreSync gate for its role Secrets, and when the sync-wave order of the data ApplicationSets differs from the documented one (secrets before PostgreSQL, Valkey and RabbitMQ; the credential copy after RabbitMQ; the table in `platform/argocd/README.md` equal to the annotations). Each check was shown to fail on a deliberately broken copy of the repository.

Verification

On a throwaway kind cluster, without Argo CD for the Jobs (rendered manifests applied directly, namespaces enforcing the `restricted` Pod Security profile): the generator, the credential copy and the PostgreSQL gate Jobs were all admitted without warnings; the six generated Secrets were created once and were byte-identical after the Job was deleted and applied again; a deleted `orders-db` was recreated with the password of `pg-orders`; the credential copy waited for the operator's Secret, created `rabbitmq-auth`, and a second run with an unchanged source left it untouched (it follows the source if the operator changes it, because the operator owns that credential); the gate waited while `pg-payments` was missing and released when it appeared; the Roles allow only the verbs listed in the charts. The earlier checks with Argo CD (a hooks-only chart never syncing, a plain Job with a TTL flapping, the hook design staying Synced) are described above. Not verified: anything on a real cluster, a full CloudNativePG and RabbitMQ stack together with the services, and whether the cause of the 17-minute delay is fixed beyond the gate preventing the situation.

## Consequences

- A fresh cluster reaches a working data layer without manual syncs, as long as the first sync of each Application runs (which an ordinary resource now guarantees).
- Secrets deleted by hand are not recreated until the next sync. That is the price of a hook that is stable under Argo CD.
- The `data-postgres` Application has a PreSync gate: the first sync takes as long as `data-secrets` needs, and a failure there blocks the `Cluster` instead of creating a broken one.
- Cross-Application ordering is not enforced by Argo CD and is documented as such, so nobody builds on it.

## Alternatives considered

- Restore the `Application` health check and make an app-of-apps of Applications with waves: enforces ordering at the cost of replacing the ApplicationSets with a rendered set of Applications per cluster and a cluster-wide `argocd-cm` change.
- ApplicationSet progressive syncs: single-ApplicationSet scope and no automated sync.
- Merging the data layer into one chart so waves apply: loses the operator/custom-resource separation of [ADR-0014](0014-data-layer.md).
- A plain Job with a TTL, or a reconciler Deployment: see above.
- Fixing only the Cluster side with the annotation: it treats a symptom and still lets the `Database` resources and the migrations fail first.
