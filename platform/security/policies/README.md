# policies

Kyverno admission policies for the `shop` namespace: where images come from, that they are pinned and signed, and that workloads have resources, probes and a name label. They run in **Audit** by default: a workload that breaks one is recorded in the policy reports and nothing is blocked. Argo CD deploys them with Kyverno, to clusters labelled `platform.example/policy=true` (off by default; `scripts/bootstrap-argocd.sh --enable-policy`). **They have not run on a cluster.** Everything here is checked offline (see [Checks](#checks)).

## Policy types

All the policies are of the CEL-based family of `policies.kyverno.io/v1`: five `ValidatingPolicy` and one `ImageValidatingPolicy`.

- **Why not `ClusterPolicy`.** In the CRDs of the pinned chart (Kyverno v1.19.2) the classic `ClusterPolicy` and `Policy` of `kyverno.io/v1` are marked deprecated, with a deprecation warning that says they will be removed in a future release. `ValidatingPolicy` and `ImageValidatingPolicy` are served at `v1` without a warning, and are what the project is moving to. They are cluster-scoped, so the scope is a `namespaceSelector`.
- **`ImageValidatingPolicy` for the signatures.** Verifying a signature needs it: a `ValidatingPolicy` cannot call cosign. It is the only exception to "one policy family", and it is also of `policies.kyverno.io/v1`.
- **The `ClusterPolicy` kind is not in the AppProject** (`platform-addons`), so it cannot be deployed by mistake; a test checks that.

## The policies

| Policy | What it checks | Default | With `values-enforce.yaml` |
| --- | --- | --- | --- |
| `require-image-digest` | Every container and init container uses an image with a digest. The tag `latest`, even with a digest, and a tagless image are refused. | Audit | Enforce |
| `restrict-image-registries` | Every container and init container uses an image from `registry` (`ghcr.io/franklindot04`, the value of `image.registry` in `deploy/helm/values/images.yaml`). | Audit | Enforce |
| `verify-image-signatures` | The images from that registry are signed, keyless, by the images workflow of this repository on `main` (the issuer and identity of `scripts/verify-image.sh`), with a transparency log entry, and carry the SBOM attestation and the build provenance that the script checks. | Audit | Audit |
| `require-resources` | Every container and init container has CPU and memory requests and a memory limit. | Audit | Enforce |
| `require-probes` | Every container of a Deployment, StatefulSet or DaemonSet has a readiness and a liveness probe. Jobs and CronJobs are not checked. | Audit | Enforce |
| `require-app-name-label` | Every pod has the label `app.kubernetes.io/name`, which the service chart sets. | Audit | Enforce |

The action is `Audit` or `Enforce` (Kyverno's `Deny`), set by `action` in `values.yaml` for all policies and by `policies.<name>.action` for one. Nothing is `Enforce` by default. `values-enforce.yaml` is not used by default; it turns the enforceable policies on and leaves the signature policy in Audit, because it needs the registry and the Sigstore services and has not run on a cluster.

## Scope

- **Only `shop`** (`scope.namespaces`). The policies are selected by namespace, so `kube-system`, `kube-node-lease`, `argocd`, `kyverno`, `data` and `observability` are not touched. The webhooks of Kyverno itself skip the first four as well.
- **Pod controllers.** The policies on pods have autogen on for Deployments, StatefulSets, DaemonSets, Jobs and CronJobs, so a controller is checked and not only the pods it makes. The probe policy matches the controllers directly, and not the pods, so the pods of a Job are not checked.
- **One exemption.** A workload with the label `platform.example/policy-exempt: "true"` is left out of every policy. Only the Job that copies the RabbitMQ credentials into `shop` ([`platform/data/rabbitmq-credentials`](../../data/rabbitmq-credentials)) has it: it runs a public `curl` image and belongs to the data layer. It is a `matchCondition` and not an `objectSelector`, because Kyverno does not generate the rules for pod controllers when a policy has an `objectSelector`.
- **Fail open.** Every policy has `failurePolicy: Ignore`, and Kyverno forces it too, so a dead Kyverno cannot block the cluster.

## What is not here, on purpose

The namespaces enforce the Pod Security levels already (`restricted` in `shop`, `baseline` in `data`). **Do not add the same rules here**: privileged containers, host namespaces and ports, host paths, added capabilities, running as root, privilege escalation, seccomp. Two places that say the same thing drift apart.

## The debug container of the runbook

[The network policy runbook](../../../docs/runbooks/network-policies.md) starts a busybox ephemeral container from `docker.io` in `shop`. It keeps working, for two reasons:

- an ephemeral container is added through the subresource `pods/ephemeralcontainers`, and the policies match `pods` only, not their subresources (a check refuses a rule that lists a subresource);
- the policies look at `containers` and `initContainers`, never at `ephemeralContainers`, so a later update of the same pod is not stopped by the debug container either.

The tests include a pod with a `docker.io` busybox ephemeral container, with and without a digest, that must pass every policy. The webhook itself has not been tried on a cluster.

## Checks

`make policy-check` (`scripts/policy-check.sh`):

- **The contract** (`scripts/chart-contract-check.py policies`): the types, the scope, autogen, the matching of pods and no subresource, the exempt label, Audit by default and Deny with `values-enforce.yaml`, the registry of `images.yaml`, and the signature policy against `scripts/verify-image.sh`: the same issuer and identity, a transparency log entry, the SBOM and the provenance, one identity and no key.
- **`kyverno test`** with the CLI of Kyverno v1.19.2 (the image the chart's own hook Job uses, pinned by digest in the script, run with Docker): [`tests`](tests) has a resource that passes and one for each way to fail, for every policy but the signature one. The script also changes the registry policy to allow everything and checks that the tests notice.
- **The reality check:** the service chart under every profile and cloud and the RabbitMQ credentials chart are rendered and must pass the policies that apply to them.
- **The signature policy** is loaded by the CLI (its CEL compiles) against a pod that it does not match. The check of a real signature needs the internet and has **not** been run.
- The CLI's `apply` does not apply autogen to a Deployment; `test` does. The checks use `test`, with expected results for the Deployments and Jobs, not only for pods.

The CLI needs Docker. Without it the script says so and skips those steps; CI runs them ([`policy.yml`](../../../.github/workflows/policy.yml)).
