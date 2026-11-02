# ADR-0025: Admission policies

- Status: Accepted
- Date: 2026-11-02

## Context

Nothing in the cluster checks what is deployed. [ADR-0019](0019-image-supply-chain.md) signs every image, attaches an SBOM and the build provenance, and gives a script that verifies them, but it says in plain words that nothing in the clusters checks any of it: an unsigned image, an image from another registry, a tag that moves, a container with no resource requests or no probe is accepted like any other. The Pod Security levels on the namespaces ([ADR-0014](0014-data-layer.md), [ADR-0016](0016-service-deployment-model.md)) stop privileged and host-level settings, and the network policies of [ADR-0024](0024-network-policies.md) decide who can connect. Neither looks at the image or at the shape of the workload.

The platform needs a policy engine that can check these things at admission, report on what already runs, and be tested without a cluster. It has to be safe to try: a policy engine is a webhook in the path of every request, and a dead one must not be able to stop the cluster. Nothing in this change has run on a cluster.

## Decision

Kyverno, installed by Argo CD behind its own cluster Secret label, with six admission policies for the `shop` namespace that report and block nothing until someone decides otherwise.

The install

- **Chart and version.** The official chart `kyverno` **3.9.2**, Kyverno **v1.19.2**, wrapped and pinned like the other third-party charts ([`platform/security/kyverno`](../../platform/security/kyverno)). The project documents Kubernetes 1.33 to 1.35 for this release and says other versions may work but are not tested. The chart's own `kubeVersion` is `>=1.25.0-0`, which does not exclude the 1.37 of the EKS cluster. **Compatibility with 1.37 is not confirmed.** 3.9.2 is the newest chart that does not exclude it.
- **Opt-in.** The cluster Secret label `platform.example/policy` (`scripts/bootstrap-argocd.sh --enable-policy`), off by default, like `data` and `observability`. Three ApplicationSets: `policy-kyverno` (wave 18, after the observability stack and before the services), `policy-network-policies` (wave 19, EKS only) and `policy-policies` (wave 20, with the services). They belong to the existing `platform-addons` AppProject, which got the `kyverno` namespace and the two policy kinds in use, and nothing wider.
- **The controllers.** One replica each of the admission, background, cleanup and reports controllers, requesting 225m CPU and 320Mi of memory in all, sized for the three-node Spot cluster that already runs the data layer and the observability stack. A higher availability profile (`values-ha.yaml`: three admission replicas and a PodDisruptionBudget, 425m and 576Mi) is written and is not used by default.
- **The CRDs.** The chart installs 22 CRDs and the largest is about 675 KB, more than client-side apply can store in an annotation, so the Application syncs with ServerSideApply. A check measures the CRDs and fails if the Application does not.
- **Metrics.** Port 8000 of every controller, scraped through a ServiceMonitor in the monitors chart, like the services and the data layer.

A dead Kyverno must not block the cluster

- **The webhooks fail open.** `features.forceFailurePolicyIgnore` makes every webhook that Kyverno creates answer Ignore, and each policy says `failurePolicy: Ignore` too. A request that Kyverno cannot answer is allowed. Failing closed is a later decision, made per policy with the high availability profile.
- **The webhooks skip `kube-system`, `kube-node-lease`, `argocd` and `kyverno`.** Kyverno cannot block the system, Argo CD, or itself. The chart renders no webhook configuration: Kyverno creates its own at run time, so Argo CD does not manage them and `scripts/teardown-prep.sh` removes them.
- **Argo CD does not run the chart's Helm pre-delete hook** (two Jobs that remove the webhooks and scale the controllers), so it is switched off and the teardown script does the job.

The network policies of the `kyverno` namespace

- A default deny with explicit allows, in the style of the other namespaces ([ADR-0024](0024-network-policies.md)): DNS, and the API server through the Service range on 443, because the policy agent matches egress against Service addresses; Prometheus on the metrics port; and the webhook port 9443 of the admission and cleanup controllers.
- **The API server calls the webhook from its own network interfaces, which are in the VPC subnets, straight to the pod.** The source is therefore the VPC range, which is the one place where that peer is right, next to the Service range for everything that goes through a Service.
- **The admission controller alone may reach the internet on TCP 443**, for every address except the VPC and Service ranges. Image signature checks need a registry and, for keyless verification, the Sigstore services (Fulcio, Rekor, the TUF root). They are public addresses that a pod selector cannot name. The policy that says so carries an annotation with the reason, and the contract check accepts a `/0` range only with it and only on TCP 443. A private GHCR package would also need a pull secret; none is set up.

The policy types

- **`ValidatingPolicy` for five policies and `ImageValidatingPolicy` for the signatures, both `policies.kyverno.io/v1`.** In the CRDs of the pinned chart the classic `ClusterPolicy` and `Policy` of `kyverno.io/v1` are marked deprecated, with a warning that they will be removed. The CEL-based kinds are served at `v1` without a warning and are what the project is moving to. `ImageValidatingPolicy` is the exception to one family, because a `ValidatingPolicy` cannot verify a signature. The AppProject does not allow `ClusterPolicy`, so it cannot be deployed by mistake.
- The policies are cluster-scoped objects, so the scope is a `namespaceSelector` on `shop`. The system and platform namespaces (`kube-system`, `kube-node-lease`, `argocd`, `kyverno`, `data`, `observability`) are not selected.
- **Autogen is on** for Deployments, StatefulSets, DaemonSets, Jobs and CronJobs, so a controller is checked and not only the pods it makes. The probe policy matches the controllers themselves, so the pods of a Job are not checked.

The policies

| Policy | What it checks | Default | `values-enforce.yaml` |
| --- | --- | --- | --- |
| `require-image-digest` | A digest on every container and init container; no `latest`, no tagless image | Audit | Enforce |
| `restrict-image-registries` | Images from `ghcr.io/franklindot04`, the registry of `deploy/helm/values/images.yaml` | Audit | Enforce |
| `verify-image-signatures` | Keyless signature by the images workflow on `main`, the transparency log entry, the SBOM and the build provenance, as `scripts/verify-image.sh` checks them | Audit | Audit |
| `require-resources` | CPU and memory requests and a memory limit | Audit | Enforce |
| `require-probes` | Readiness and liveness probes on Deployments, StatefulSets and DaemonSets; Jobs are exempt | Audit | Enforce |
| `require-app-name-label` | The label `app.kubernetes.io/name`, which the service chart sets | Audit | Enforce |

- **Audit by default.** One value (`action`) sets all policies and `policies.<name>.action` one policy. Audit records the result in the policy reports and blocks nothing. Nothing is Enforce in the default values. `values-enforce.yaml` turns five of the six on and is not used by default. The signature policy stays Audit even there, because its check needs the internet and has not run on a cluster.
- **The signature policy asks for what `verify-image.sh` asks for and not less:** the GitHub Actions OIDC issuer, the identity of `images.yml` on `main` of this repository, a transparency log entry, the SBOM and the provenance, and one identity only. The registry and the identity are copied into the chart's values, and a contract check compares them with `images.yaml` and the script, so they cannot drift.
- **The policies do not repeat Pod Security.** The levels on the namespaces already stop privileged containers, host namespaces and ports, added capabilities and running as root, and two places that say the same thing drift apart.
- **The debug container of the runbook keeps working.** [The network policy runbook](../runbooks/network-policies.md) starts a busybox ephemeral container from `docker.io` in `shop`. Ephemeral containers are added through the subresource `pods/ephemeralcontainers`. The policies match `pods` and no subresource, and look at `containers` and `initContainers` only, never at `ephemeralContainers`. A contract check refuses a policy that does otherwise.

A known weak spot: the exemption

- The Job that copies the RabbitMQ credentials into `shop` runs a public `curl` image. It would fail the registry, digest and signature policies, so it carries the label `platform.example/policy-exempt: "true"` and every policy skips a workload that has it. Since [ADR-0027](0027-external-secrets.md) the Job exists only in generated mode (the default); on a cluster in external mode an ExternalSecret replaces it and the label is not rendered.
- **The label is not protected.** Anyone who can create a workload in `shop` can copy it, and the policies then skip that workload. It is a `matchCondition` and not an `objectSelector`, because Kyverno does not generate the rules for pod controllers when a policy has an `objectSelector`, and nothing stops the label from spreading. The fix is to run that Job from a pinned image of ours, which does not need the exemption. Until then it is a hole, written down here so that it is not forgotten.

Teardown

- A Kyverno policy or webhook configuration left behind, with no controller to answer, can block the deletions that follow. `scripts/teardown-prep.sh` has a step that deletes the policies (all four kinds) and the validating and mutating webhook configurations whose names start with `kyverno`, and only those, before anything else is deleted: 15 steps, 12 with `--skip-aws`. `scripts/teardown-argocd.sh` refuses to start while any is left: 10 steps. Both are tested against a fake `kubectl`.

## Alternatives considered

- **OPA Gatekeeper.** A mature, widely used engine, with policies in Rego and a constraint framework that is well suited to a library of reusable templates. It has no built-in verification of keyless signatures; that would be a second component or custom Rego with an external data provider. It audits existing objects and records the violations in the status of each constraint, not as the policy reports of the Kubernetes policy working group that Kyverno writes. Its policies are tested with `opa test` and not against Kubernetes resources and the engine's own semantics. A good choice for a team that already writes Rego; this project does not.
- **The built-in `ValidatingAdmissionPolicy` of Kubernetes.** The best choice for rules that are pure CEL over one object: it runs in the API server, with no webhook to keep alive and no extra controller, so it cannot be down. It cannot verify an image signature, which needs a call to a registry and the Sigstore services, and it has no reports of results for existing objects. Kyverno's `ValidatingPolicy` uses the same CEL, so the rules here could be moved to it later; and Kyverno can generate in-tree policies from its own (the chart enables that flag in the admission controller by default).
- **Kyverno `ClusterPolicy`.** The older, YAML-pattern policy type, with the most examples. Deprecated in this version's CRDs, so a new policy written in it would be written to be replaced.
- **Enforce from the start.** Faster to a closed door, and the usual way to a blocked deployment on the first apply. The policies run in Audit until a clean report says they can be enforced.
- **Kyverno, and why.** Image verification with keyless signatures, which is the reason for the whole change; policy reports for what already runs, so a policy can be judged before it blocks; and tests with the Kyverno CLI, with expected results for each policy, which run offline and in CI. That is a choice for this project, not a verdict on the others.

## Consequences

- **A webhook in the path of the API.** Kyverno adds latency to admission of pods and controllers in `shop` and one more thing that can fail. It fails open, so the cost of its failing is that policies stop being applied, not that the cluster stops.
- **Audit gives information and no protection.** Nothing is blocked until a policy is moved to Enforce. The report is where that decision is made, one policy at a time ([the runbook](../runbooks/kyverno.md)).
- **The policies and the charts have to agree.** A workload chart that drops a probe, or an image from another registry, shows up in the report. The check that renders the service chart under every profile and runs the policies over it keeps our own workloads from failing them.
- **Failing closed is not decided.** It needs the high availability profile on three nodes and a decision per policy.
- **The exemption is a hole** (above).
- **Another namespace is another change.** `data` and `observability` are not covered, by choice: the operators create pods there that the service chart's conventions do not describe.
- **Resources.** The controllers request 225m CPU and 320Mi of memory (425m and 576Mi in the high availability profile), on top of what the data layer and the observability stack already request on the same nodes.

## What is proven offline and what is not

Proven offline, by `scripts/policy-check.sh` and `scripts/test-scripts.sh` (a workflow `policy.yml` runs the first in CI; it is new and not a required check):

- **`kyverno test`** with the Kyverno CLI v1.19.2: 350 test results over 44 resources, a resource that passes and one for each way to fail, for every policy but the signature one. The script also changes the registry policy to allow everything and requires the tests to notice.
- **The reality check:** the service chart under every profile and cloud and the RabbitMQ credentials chart, 13 workloads from 11 renders, run through the policies. All pass the policies that apply to them, with the credentials Job skipped by its label. Changing the registry makes it fail.
- **Contract checks:** the policy types, the scope, autogen, no subresource, Audit by default and Deny with `values-enforce.yaml`, the registry of `images.yaml`, and the signature policy against `verify-image.sh` for issuer, identity, transparency log, SBOM and provenance, with mutations that each make a check fail.
- **The Kyverno install:** requests and limits under 600m CPU and 1Gi of memory, webhooks that fail open and skip the four namespaces, ServerSideApply for the large CRDs, the fit with the AppProject (with a negative case), and the network policy flows of the `kyverno` namespace in the offline flow matrix.
- **The teardown steps,** against a fake `kubectl`, including that only Kyverno's webhook configurations are deleted.

Not proven:

- **Anything on a cluster.** Kyverno has not been applied, and compatibility with Kubernetes 1.37 is unconfirmed.
- **A real signature verification.** The signature policy loads (its CEL compiles) and is checked against the script, but it has not verified an image. The SBOM and provenance predicate types are the ones cosign maps for its `spdxjson` and `slsaprovenance1` types; they have not been seen in our attestations.
- **Admission of an ephemeral container through the real webhook.** The busybox probe of the runbook should stay allowed, because the policies do not look at ephemeral containers; it has been tested on the policy expressions only.
- **Autogen on the cluster.** The CLI applies it in `kyverno test`, not in `kyverno apply`; what the admission controller generates has not been seen.
- **Egress for the signature checks:** TCP 443 to every address except the VPC and Service ranges is what the policy allows; whether a registry or Sigstore service needs more has not been tried. A private GHCR package would need a pull secret.
- **The high availability profile on three nodes.**
