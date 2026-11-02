# Secrets from Parameter Store

Puts the platform's passwords in AWS Systems Manager Parameter Store, delivers them with the External Secrets Operator, checks them, reads their errors, rotates them and takes them away. What it is and why is in [ADR-0027](../adr/0027-external-secrets.md); the charts are described in the READMEs of [`external-secrets`](../../platform/security/external-secrets), [`external-secrets-store`](../../platform/security/external-secrets-store), [`secrets`](../../platform/data/secrets), [`rabbitmq`](../../platform/data/rabbitmq), [`rabbitmq-credentials`](../../platform/data/rabbitmq-credentials) and [`observability/secrets`](../../platform/observability/secrets).

**Only the seed script has been run against real AWS** (on 2026-11-02: it created the six parameters, a second run found them all, and `--check` reported none missing). **Nothing else in this runbook has been run on a cluster.** The commands are written from the manifests and from the documentation of the components. Every check below is marked "not run" until someone runs it and writes down what differs; no output is shown, because none has been seen. A difference is a finding.

External mode is off unless the cluster Secret carries the label `platform.example/external-secrets=true`. Without it the in-cluster generator makes the passwords, as before.

## First-time setup

The parameters cost nothing and survive a cluster rebuild, so this is done once for each environment.

1. **Sign in to AWS** with the profile you use for the account (the region is the one of the cluster, `eu-north-1` in the examples):

   ```bash
   aws sso login --profile <PROFILE>
   ```

2. **Write the parameters.** Read what it would do, then run it. It generates each value on your machine and writes it with `--no-overwrite`, so a value that exists is never changed and running it twice is safe:

   ```bash
   ./scripts/seed-secrets.sh --region eu-north-1 --profile <PROFILE> --dry-run
   ./scripts/seed-secrets.sh --region eu-north-1 --profile <PROFILE>
   ./scripts/seed-secrets.sh --region eu-north-1 --profile <PROFILE> --check
   ```

   `--check` exits 1 if a parameter is missing. The path is `/multi-cloud-sre/dev` by default; `--environment` and `--prefix` change it, and the prefix has to match the Terraform variable `secrets_parameter_prefix`. The script never prints a value. It holds each one in a private file (directory mode 0700, file 0600) for the moment of the call and deletes it straight after; the file is deleted, not shredded.
3. **Apply Terraform.** The role of the operator is created by default (`enable_external_secrets = true`); the outputs `external_secrets_role_arn` and `secrets_parameter_prefix` are what the bootstrap script reads. The seed can come before or after this step, but must come before the first sync of the Applications that read the parameters.
4. **Bootstrap with the flag and the flags you already use.** The script writes every label on each run, so repeat the others or they are switched off:

   ```bash
   ./scripts/bootstrap-argocd.sh --context <EKS_CONTEXT> --dry-run --enable-external-secrets --enable-policy --enable-data --enable-observability --enable-apps --apps-profile data
   ```

   Read the printed cluster Secret: it must carry the label `platform.example/external-secrets` set to `true` and the annotations `platform.example/external-secrets-role-arn` and `platform.example/secrets-prefix`. Then run it without `--dry-run`. The script refuses an empty role or prefix.
5. **Argo CD syncs in waves.** The operator is wave 3, the store and the network policies wave 4, then `data-namespaces` and `data-secrets` (5), the data layer (6 and 7), the observability secrets (10) and the services (20). Waves only order how the ApplicationSets are created; the consumers wait for their Secrets.
6. **Check, in this order** (below).

## Check after an apply

All of these are **not run**. In every command `<EKS_CONTEXT>` is the context of the cluster. None of them prints a value: the Secrets are listed by key name only.

1. **The Applications.** `eso-operator-*`, `eso-store-*`, `eso-network-policies-*`, `data-secrets-*`, `data-rabbitmq-*`, `data-rabbitmq-credentials-*` and `observability-secrets-*` should be Synced and Healthy. Not run.

   ```bash
   kubectl --context <EKS_CONTEXT> -n argocd get applications | grep -E 'eso-|data-secrets|data-rabbitmq|observability-secrets'
   ```

2. **The operator's pods are ready.** Three Deployments: `external-secrets`, `external-secrets-webhook` and `external-secrets-cert-controller`, one pod each. Not run.

   ```bash
   kubectl --context <EKS_CONTEXT> -n external-secrets get deployments,pods
   kubectl --context <EKS_CONTEXT> get validatingwebhookconfigurations secretstore-validate externalsecret-validate
   ```

   Both webhook configurations should have `failurePolicy: Ignore`. The service account of the controller carries the role; check that the annotation is not empty:

   ```bash
   kubectl --context <EKS_CONTEXT> -n external-secrets get serviceaccount external-secrets -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'; echo
   ```

3. **The ClusterSecretStore is ready.** Not run.

   ```bash
   kubectl --context <EKS_CONTEXT> get clustersecretstore aws-parameter-store
   kubectl --context <EKS_CONTEXT> get clustersecretstore aws-parameter-store -o jsonpath='{.status.conditions}'; echo
   ```

   A store that is not valid cannot sign in to AWS: go to [reading an error](#read-an-externalsecret-error).
4. **Each ExternalSecret is ready.** Nine are expected: `pg-orders`, `pg-payments`, `valkey-auth`, `platform-mq-default-user` in `data`; `orders-db`, `payments-db`, `cache-auth`, `rabbitmq-auth` in `shop`; `grafana-admin` in `observability`. Argo CD's health check for an ExternalSecret (read from the source of v3.5.6) marks it Healthy when its Ready condition is true, Degraded when false and Progressing when there is none. Not run.

   ```bash
   kubectl --context <EKS_CONTEXT> get externalsecrets -A
   ```

5. **The Secrets exist, with the expected key names, type and owner.** Keys only, never the data. The expected keys are in [`scripts/secrets/contract.yaml`](../../scripts/secrets/contract.yaml). Not run.

   ```bash
   for s in data/pg-orders data/pg-payments data/valkey-auth data/platform-mq-default-user shop/orders-db shop/payments-db shop/cache-auth shop/rabbitmq-auth observability/grafana-admin; do
     ns="${s%%/*}"; name="${s##*/}"
     echo "== $s"
     kubectl --context <EKS_CONTEXT> -n "$ns" get secret "$name" -o json | jq -r '[.type, (.data | keys | join(" ")), (.metadata.ownerReferences[0].kind // "no owner")] | join(" | ")'
   done
   ```

   Each line should end in `ExternalSecret`. The `pg-` Secrets should be `kubernetes.io/basic-auth` with `password username`, and carry the label `cnpg.io/reload` (`kubectl -n data get secret pg-orders --show-labels`).
6. **No generator is left.** In external mode no Job makes a Secret and the exempt label is not rendered. Not run.

   ```bash
   kubectl --context <EKS_CONTEXT> -n data get jobs
   kubectl --context <EKS_CONTEXT> -n shop get jobs
   kubectl --context <EKS_CONTEXT> -n observability get jobs
   ```

   Only the migration Jobs of the services and the PostgreSQL gate (a PreSync hook, removed after a sync) may appear.
7. **The consumers start.** Valkey, Grafana and the services use a `secretKeyRef` or a Secret volume that is not optional, so a pod whose Secret is missing stays in `CreateContainerConfigError` or `ContainerCreating` and retries; that is read from the templates, not seen. Not run.

   ```bash
   kubectl --context <EKS_CONTEXT> -n data get pods
   kubectl --context <EKS_CONTEXT> -n shop get pods
   kubectl --context <EKS_CONTEXT> -n observability get pods
   ```

8. **The PostgreSQL roles.** The gate Job polls for the role Secrets for up to 900 seconds before the Cluster is applied. Not run.

   ```bash
   kubectl --context <EKS_CONTEXT> -n data get cluster.postgresql.cnpg.io platform-pg
   kubectl --context <EKS_CONTEXT> -n data get cluster.postgresql.cnpg.io platform-pg -o jsonpath='{.status.managedRolesStatus}'; echo
   ```

   A role in `cannotReconcile` or `pending-reconciliation` names the Secret it is waiting for.
9. **RabbitMQ.** The cluster takes its default user from the Secret (`spec.secretBackend.externalSecret.name`). The operator's README says the StatefulSet waits until the Secret exists. It is **not known** whether the broker accepts `default_user.conf` as built; that is the first thing to look at. Not run.

   ```bash
   kubectl --context <EKS_CONTEXT> -n data get rabbitmqcluster platform-mq
   kubectl --context <EKS_CONTEXT> -n data get rabbitmqcluster platform-mq -o jsonpath='{.spec.secretBackend}'; echo
   kubectl --context <EKS_CONTEXT> -n data get pods -l app.kubernetes.io/name=platform-mq
   kubectl --context <EKS_CONTEXT> -n data logs platform-mq-server-0 --tail=50
   ```

   Then check that the services connect: `kubectl -n shop logs deployment/notifier --tail=50` should not show an authentication error.

## Read an ExternalSecret error

Start with the object:

```bash
kubectl --context <EKS_CONTEXT> -n <NAMESPACE> describe externalsecret <NAME>
kubectl --context <EKS_CONTEXT> -n external-secrets logs deployment/external-secrets --tail=100
```

The Ready condition and the events name the failure. In the order of how often they are likely to be the cause (none of these has been seen):

- **The role annotation.** The service account `external-secrets` has no `eks.amazonaws.com/role-arn`, or it names another role. An empty value fails the sync of the operator Application with a message that names the annotation `platform.example/external-secrets-role-arn`. Look at the cluster Secret (`kubectl -n argocd get secret cluster-in-cluster -o jsonpath='{.metadata.annotations}'`) and at the Terraform output.
- **The trust policy.** The role trusts only `system:serviceaccount:external-secrets:external-secrets` with the audience `sts.amazonaws.com`, on the OIDC provider of this cluster. A different namespace or service account name, or a role from an earlier cluster (the provider changes with each cluster), gives an `AccessDenied` or `InvalidIdentityToken` error from STS. Apply Terraform again and run the bootstrap script again so the annotation matches.
- **The policy path.** The role reads `/<prefix>/<environment>/*` only. A prefix in the cluster annotation that differs from the one the parameters were written under gives `AccessDenied` or `ParameterNotFound`. Compare `kubectl -n external-secrets get clustersecretstore aws-parameter-store -o jsonpath='{.metadata.annotations}'` with `./scripts/seed-secrets.sh --region <REGION> --check`.
- **The parameter is missing.** `ParameterNotFound` for one key: run the seed script. The ExternalSecret recovers at its next refresh, or force one (below).
- **The key.** A `kms:Decrypt` error means the policy's condition did not match: the key is used through Systems Manager in the region of the policy (`kms:ViaService`). A parameter encrypted with another key (a customer-managed one) needs that key's ARN in `kms_key_arn` and a key policy that allows the role.
- **Egress on 443.** The controller reaches STS and Systems Manager through the NAT gateway on TCP 443; no other pod of the namespace may. A timeout, not an `AccessDenied`, points at the network: see [the network policy runbook](network-policies.md#see-what-is-being-dropped), the policy `controller-allow-internet-https` and the annotation `platform.example/vpc-cidr`.
- **The store.** A store that is not valid blocks every ExternalSecret: `kubectl get clustersecretstore aws-parameter-store -o yaml` shows its conditions. The store names the region and the service account, nothing else.
- **The webhook.** The validating webhooks fail open, so a failing webhook does not block an apply. If an ExternalSecret was accepted that the controller rejects, the error is on the object.

## Rotation

**Not run.** The steps below are written from the documentation and have not been exercised.

1. **Write the new value** with the same private-file approach as the seed script, never with a value on a command line. The example below is for one parameter; the new value is in a shell variable and a private file for the moment of the call:

   ```bash
   umask 077
   dir="$(mktemp -d)"
   trap 'rm -rf "$dir"' EXIT
   value="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)"
   printf '{"Value":"%s"}' "$value" > "$dir/parameter.json"
   aws ssm put-parameter --region eu-north-1 --name /multi-cloud-sre/dev/grafana/admin-password --type SecureString --tier Standard --key-id alias/aws/ssm --overwrite --cli-input-json "file://$dir/parameter.json"
   unset value
   ```

   `seed-secrets.sh` does not overwrite on purpose.
2. **Wait for the refresh, or force it.** The refresh interval is an hour. The documentation of ESO (the latest, not a page of the pinned 2.14.0) says an annotation with a changing value forces a refresh:

   ```bash
   kubectl --context <EKS_CONTEXT> -n observability annotate externalsecret grafana-admin force-sync="$(date +%s)" --overwrite
   ```

3. **Restart the consumers.** A pod does not reload a changed Secret by itself: restart Grafana (`kubectl -n observability rollout restart deployment/kube-prometheus-stack-grafana`), the services (`kubectl -n shop rollout restart deployment/orders deployment/payments deployment/notifier`) and so on. A password used by two Secrets (`postgres/orders-password` feeds `pg-orders` and `orders-db`) changes in both.
4. **PostgreSQL.** CloudNativePG reloads the role passwords through the label `cnpg.io/reload` on the `pg-` Secrets.
5. **RabbitMQ: take care.** The operator's documentation (the page read for the pinned version) says nothing about changing the default user when it comes from an external Secret; it only says that Vault-supplied admin credentials can rotate without a restart. RabbitMQ applies `default_user` when a node first initialises its data directory, which is its general behaviour and was not checked here. So changing `rabbitmq/default-username` or `rabbitmq/default-password` on a broker with data can leave the broker with the old user while `rabbitmq-auth` carries the new one, and the services cannot sign in. Try it on a throwaway cluster first.

## Switch a cluster between modes

**Not run.** What changes, from the charts:

- **Generated to external.** Run the bootstrap script again with `--enable-external-secrets`. The generator Jobs, their service accounts and roles, and the RabbitMQ copy Job disappear from the Applications; ExternalSecrets take their place; the exempt label is no longer rendered. **The passwords change**, because the Secrets are now made from the parameters. It is **not known** whether ESO takes over a Secret that already exists without an owner; plan to delete the generated Secrets first (running pods keep the credentials they have). CloudNativePG reloads the role passwords through the label; the services and Grafana need a restart. A RabbitMQ broker that already has data keeps its old user (see the note on rotation), so do this on a fresh cluster.
- **External to generated.** Remove the label (`kubectl -n argocd label secret cluster-in-cluster platform.example/external-secrets-`, or run the bootstrap script without the flag). The ExternalSecrets go, the Secrets they own are garbage-collected with them, and the generators make new random passwords at the next sync. Again the passwords change.

## The parameters between sessions

The six parameters are free and are **not** removed by `scripts/teardown-prep.sh`, `scripts/teardown-argocd.sh` or `terraform destroy`. That is on purpose: the next cluster reads the same values. To see them:

```bash
aws ssm describe-parameters --region eu-north-1 --parameter-filters 'Key=Path,Option=Recursive,Values=/multi-cloud-sre/dev' --query 'Parameters[].[Name,Type,Tier]' --output table
```

To remove them, when the environment is finished with, run the purge. It asks you to type the environment name, and there is no `--yes`:

```bash
./scripts/seed-secrets.sh --region eu-north-1 --profile <PROFILE> --purge
```

A purged environment needs the seed again before the next sync.

## Teardown

Nothing new has to be done by hand. `scripts/teardown-prep.sh` (16 steps, 13 with `--skip-aws`) removes the cluster Secret label in the first step, waits for the `eso-*` Applications, and then deletes every ExternalSecret, ClusterExternalSecret, SecretStore and ClusterSecretStore and the two webhook configurations `secretstore-validate` and `externalsecret-validate` (step 4). `scripts/teardown-argocd.sh` (11 steps) refuses to start while any of them is left. See the [data layer teardown](data-layer.md#teardown).

- **Order.** The ExternalSecrets go before the data layer is removed (steps 8 to 10). A Secret an ExternalSecret owns is garbage-collected with it. A running pod keeps the credentials it already has, because deleting a Secret does not change a running container. CloudNativePG may log role errors for the `pg-` Secrets; the database is removed in a later step.
- **Finalizers.** It is **not known** whether ESO puts finalizers on its objects. If it does, and the operator is already gone, a deletion could hang. The scripts wait, time out and say what is left; they do not clear a finalizer that is not ours. Find it with `kubectl get <kind> <name> -o jsonpath='{.metadata.finalizers}'` and decide.
- **The parameters stay** (see above).

## What has not been run

- ESO running with IAM roles for service accounts on this CNI, and a real ExternalSecret sync from Parameter Store.
- CloudNativePG, Valkey, RabbitMQ and Grafana starting from synced Secrets, and whether the RabbitMQ broker accepts `default_user.conf` as built. The operator's README does not list required keys; the Secret is built from its example (v2.23.1) and its code.
- The `ignoreDifferences` for the webhook CA bundle and the data of the Secret `external-secrets-webhook`.
- ESO finalizers and the teardown order.
- The size of the ESO CRDs (the 740 KB is measured from a YAML dump).
- Argo CD's health check for an ExternalSecret and the waiting of the consumers: both read from the source and the templates.
- Rotation, a forced refresh, and switching a live cluster between modes.
- Everything that needs AWS roles: the trust policy and the policy have only been tested with a mocked provider.
