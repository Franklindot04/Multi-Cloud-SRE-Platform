# ADR-0027: External secrets management

- Status: Accepted
- Date: 2026-11-02

## Context

The passwords of the platform are made inside the cluster. A Job run by Argo CD during a sync generates each one with random characters and creates the Secret if it does not exist ([ADR-0018](0018-secret-generation-and-ordering.md)); the RabbitMQ Cluster Operator generates the broker's user, and a second Job copies it into `shop`. That was the interim choice of [ADR-0014](0014-data-layer.md), and it has five limits:

- **The values exist only in the cluster.** When the cluster is rebuilt, every password is new. There is no copy anywhere else.
- **There is no external source of truth.** Nobody can say what a password should be, or check that the cluster has it.
- **The Jobs need rights to create Secrets.** Their service accounts can create Secrets in `data`, `shop` and `observability`, and the copy Job can create any Secret in `shop`.
- **The copy Job runs a public `curl` image.** It would fail the registry, digest and signature policies of [ADR-0025](0025-admission-policies.md), so it carries the label `platform.example/policy-exempt`, which every policy honours and nothing protects.
- **Rotation is by hand.** The generator never overwrites a Secret.

The platform needs the values to live outside the cluster, to outlive it, and to arrive as the same Secrets the consumers already read. This change defines that and checks it without a cluster. **Nothing in it has run on a cluster.** The one thing that ran on real AWS is the seed script (see the end).

## Decision

Passwords are stored in AWS Systems Manager Parameter Store and delivered by the External Secrets Operator, on clusters that opt in. The in-cluster generator stays, as the default.

### The store

Parameter Store, standard tier, SecureString, encrypted with the AWS-managed key `alias/aws/ssm`. Two reasons.

- **It is free.** Secrets Manager charges for each secret every month. Six parameters in the standard tier cost nothing.
- **The key outlives the cluster.** The Terraform KMS key of the cluster is destroyed and recreated with every cluster. Parameters encrypted with it would be unreadable after a rebuild. The AWS-managed key stays. A production setup would use a customer-managed key with its own lifecycle, created outside the cluster stack (the module takes its ARN in `kms_key_arn`).

The names are `/<prefix>/<environment>/<component>/<name>`; the prefix is the Terraform variable `secrets_parameter_prefix` (default `multi-cloud-sre`). Six parameters under `/multi-cloud-sre/dev`: `postgres/orders-password`, `postgres/payments-password`, `valkey/default-password`, `rabbitmq/default-username`, `rabbitmq/default-password` and `grafana/admin-password`. They are listed, with their length, character set and consumers, in [`scripts/secrets/manifest.yaml`](../../scripts/secrets/manifest.yaml), which is the single source.

### The values never go through Terraform, Git or state

Terraform creates no parameter. `scripts/seed-secrets.sh` generates each value on the machine of the person who runs it (32 characters from `A-Za-z0-9`; the RabbitMQ user name is `mq` plus 14) and writes it with `--no-overwrite`, so a value that exists is never changed. `--check` lists which parameters exist and which are missing. `--purge` deletes everything under the path after the environment name is typed. The parameters persist across cluster rebuilds on purpose.

The script never prints a value, never puts one on a command line and never reads one back. It hands each value to the AWS CLI in a private file, because the CLI does not accept the JSON from a pipe (`--cli-input-json file:///dev/stdin` fails with "Invalid JSON received" on version 2.33.27, which was seen on real AWS). The file is in a directory of mode 0700, is itself mode 0600, and is removed straight after each call and on every way out of the script. **The value exists on disk for a moment, in a directory only the owner can read.** The file is deleted, not shredded: on a modern SSD overwriting a file does not erase it.

### The role

The operator signs in to AWS with an IAM role for its service account (module `aws-external-secrets-iam`). The role trusts only `system:serviceaccount:external-secrets:external-secrets`. Its policy allows `ssm:GetParameter` and `ssm:GetParameters` on `/<prefix>/<environment>/*` and nothing else in Systems Manager, and `kms:Decrypt` on the keys of the account in the region with the condition `kms:ViaService = ssm.<region>.amazonaws.com`. No write action, no wildcard action. The AWS-managed key only exists after the first SecureString is written, so Terraform cannot look it up; the policy names the account's keys, and `kms_key_arn` pins it to one key once it exists. The outputs are `external_secrets_role_arn` and `secrets_parameter_prefix`.

### The operator and the store

ESO chart 2.14.0 (application v2.14.0, released 2026-10-16), installed by Argo CD behind the cluster label `platform.example/external-secrets` (`scripts/bootstrap-argocd.sh --enable-external-secrets`, which also writes the annotations `platform.example/external-secrets-role-arn` and `platform.example/secrets-prefix` from the Terraform outputs). The project's support table lists Kubernetes 1.37 for it. It runs three pods (the controller, the webhook and the certificate controller) in the namespace `external-secrets`, at the `restricted` Pod Security level, with the priority class `platform-addons-critical` and requests of 100m CPU and 228Mi of memory in all. Both validating webhook configurations fail open, so a dead operator cannot block the cluster. The service account carries the role; an empty role ARN fails the sync, so the operator never starts without it.

The waves are 3 for the operator and 4 for the store and the network policies, before `data-namespaces` and `data-secrets` (5), the observability secrets (10) and the services (20). The ClusterSecretStore `aws-parameter-store` (`external-secrets.io/v1`) names Parameter Store, the region and the web identity of the operator's service account (jwt). **The chart holds no credential of any kind.**

The network policies of the namespace allow DNS, the API server through the Service range, the API server calling the webhook (port 10250, from the VPC range), Prometheus on 8080, and, for the controller alone, TCP 443 to the internet (STS and Systems Manager, through the NAT gateway), with the reason on the policy. The webhook port is also the kubelet port, so Prometheus can reach the webhook through the VPC-range rule. That is recorded in the flow matrix as an allowed flow with a note.

### Two modes per cluster

The ApplicationSets of the credential charts pass `externalSecrets.enabled` from the cluster label (off when the label is absent) and `externalSecrets.prefix` from the annotation.

- **Generated (the default).** The in-cluster generator Jobs, as before. A local cluster without AWS works unchanged. The exempt label stays, for the copy Job.
- **External.** ExternalSecrets (refresh interval 1h, creationPolicy `Owner`) make the same Secrets: same names, namespaces, types, keys and the label `cnpg.io/reload`. The generator Jobs, their service accounts and roles, and the RabbitMQ copy Job are not rendered, so the exempt label is not needed in this mode. [`scripts/secrets/contract.yaml`](../../scripts/secrets/contract.yaml) lists each Secret and how it is built, and `scripts/chart-contract-check.py` compares both modes with it.

RabbitMQ in external mode: the RabbitmqCluster takes its default user from the Secret `platform-mq-default-user` (`secretBackend.externalSecret.name`), which holds `default_user.conf`, `username` and `password`. `host`, `port`, `provider` and `type` were dropped because nothing in the operator reads them. The operator's README does not list required keys, so this comes from its example (v2.23.1) and its code, not from a cluster. A second ExternalSecret makes `rabbitmq-auth` in `shop` from the same two parameters.

Consumers wait for their Secrets. Valkey, Grafana and the services use `secretKeyRef` or a Secret volume that is not optional, so a pod stays in `CreateContainerConfigError` or `ContainerCreating` and retries. The PostgreSQL gate Job polls for the role Secrets for up to 900 seconds. The RabbitMQ wait is from the operator's README only. Argo CD v3.5.6 has a built-in health check for an ExternalSecret (Ready true is healthy, false is degraded, none is progressing), so the Application waits for it. These come from the templates and the source, not from a cluster.

## Alternatives considered

- **AWS Secrets Manager.** Rotation, versioning and cross-account sharing are built in. It charges for each secret every month, and the key still has to be chosen. Six secrets are a small cost, but the point of this change is to keep the dev environment free between sessions. ESO reads it with the same store; the choice can change later without changing the consumers.
- **HashiCorp Vault.** The richest option: dynamic credentials, leases, audit. It is a service to run, to unseal, to back up and to secure, and for a cluster that is torn down every session that costs more than the passwords are worth. Not chosen for now; ESO has a Vault provider if it is wanted.
- **SOPS or sealed secrets in Git.** The values would be in Git, encrypted, with a review trail. The key that decrypts them then becomes the secret that has to be managed, and a rebuilt cluster needs it too. It also puts the ciphertext of every password in the history for good. Not chosen, because the aim is that no value is in Git at all.
- **Passwords generated by Terraform.** They would exist before the cluster. They would also be in the Terraform state in plain text, and in plans. That is the problem the design avoids.
- **The in-cluster generator as it was.** It works, needs no cloud, and stays as the default mode. It is not enough for the reasons in the context.

## Consequences

- **Costs nothing between sessions.** The six parameters are free and persist. They are not removed by the teardown scripts or `terraform destroy`; `scripts/seed-secrets.sh --purge` removes them.
- **A first sync needs the parameters.** Until the seed script has run, an ExternalSecret is degraded, its Application retries, and the consumers wait.
- **Passwords change when a cluster is switched to external mode.** The Secrets are made from the parameters, not from the old values. CloudNativePG reloads the role passwords through the label; the services need a restart.
- **Rotation is possible, and has not been exercised.** Change a parameter, wait for the refresh (an hour) or force it, and restart the consumers.
- **The exempt label is needed only in generated mode.** The weak spot of [ADR-0025](0025-admission-policies.md) goes away for a cluster in external mode; it stays for the others.
- **Teardown has one more thing to wait for.** If ESO puts finalizers on its objects, a deletion with no operator could hang. The script waits, times out and does not clear a finalizer that is not ours.
- **The webhook port overlaps with the kubelet port**, which is a known, recorded overlap.

## Threat model

- **No longer in Git, in Terraform or in its state:** the values of all six parameters. Git and the state hold names, paths and the role ARN.
- **What the operator can read:** the parameters under `/<prefix>/<environment>/*`, decrypted through Systems Manager, and nothing else in AWS. Its ClusterRole also lets it manage Kubernetes Secrets (from the chart; not checked verb by verb), so a compromised operator should be assumed to reach every Secret in the cluster. That is the cost of the design.
- **A compromised pod in `shop`:** it can read the Secrets its own service account and mounts give it (`orders-db`, `cache-auth` and so on), as before. It cannot reach the operator's ports (the network policies deny it), cannot assume the role (the trust is one service account), and has no AWS credential.
- **A person with the seed script's AWS rights** can write and delete the parameters, and read nothing back through the script. The AWS rights to read a SecureString with decryption are a separate matter of IAM.
- **The copy of a value on disk** during the seed: a moment, in a private directory, on one machine.

## What is proven and what is not

Proven offline: both modes of the four charts render and match the contract; every remote key resolves to an entry of the manifest and every entry is read; a Secret with a value, a leftover Job or the exempt label in external mode is refused; the role policy has no write or wildcard action (plan-only tests with a mocked provider); the network policies and the flow matrix; the Kyverno policies; the teardown scripts against a fake `kubectl`; the seed script against a fake `aws`, including the file modes and the cleanup after a failure or a signal.

Proven on real AWS on 2026-11-02, not on a cluster: the seed script created the six parameters, a second run found all six existing, and `--check` reported none missing. The same run found the pipe problem above.

**Not proven on a cluster:**

- ESO running with IAM roles for service accounts on this CNI, and a real ExternalSecret sync from Parameter Store.
- CloudNativePG, Valkey, RabbitMQ and Grafana starting from synced Secrets, and whether the RabbitMQ broker accepts `default_user.conf` as built.
- The `ignoreDifferences` for the webhook CA bundle and the webhook Secret data.
- ESO finalizers and the teardown order.
- The size of the ESO CRDs (measured from a YAML dump, not from raw bytes).
- Switching a live cluster from generated to external mode, and rotation.
- Argo CD's health check for an ExternalSecret, and the waiting of the consumers: both are read from the source and the templates.
