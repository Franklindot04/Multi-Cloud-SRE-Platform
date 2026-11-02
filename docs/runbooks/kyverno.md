# Kyverno and the admission policies

Turns on the Kyverno policy engine and the admission policies for the `shop` namespace, checks them, reads their reports, moves a policy from Audit to Enforce, and takes them away. What they are and why is in [ADR-0025](../adr/0025-admission-policies.md); the chart READMEs are [`platform/security/kyverno`](../../platform/security/kyverno/README.md), [`platform/security/policies`](../../platform/security/policies/README.md) and [`platform/security/network-policies`](../../platform/security/network-policies/README.md).

**Nothing in this runbook has been run on a cluster.** Kyverno has not been applied to one, and the project documents Kubernetes 1.33 to 1.35 for this release while the cluster runs 1.37, so **compatibility is unconfirmed**. The commands are written from the charts and the Kubernetes and Kyverno APIs. Every check below is marked "not run" until someone runs it and writes down what differs; the output is not shown on purpose, because none has been seen. A difference is a finding.

Everything is off unless the cluster Secret carries the label `platform.example/policy=true`. All six policies are in **Audit**: they record results and block nothing.

## Apply

1. **Terraform first,** as for the network policies: `terraform apply` in `infra/terraform/environments/aws` gives the outputs `vpc_cidr_block` and `service_cidr_block`, which the network policies of the `kyverno` namespace need ([network policy runbook](network-policies.md#apply)). Skip it only if the cluster already has them and the bootstrap script has run since.
2. **The bootstrap script, with the flag and the flags you already use.** The script writes every label on each run, so repeat the others or they are switched off:

   ```bash
   ./scripts/bootstrap-argocd.sh --context <EKS_CONTEXT> --dry-run --enable-policy --enable-data --enable-observability --enable-apps --apps-profile data
   ```

   Check that the printed cluster Secret has `"platform.example/policy": "true"` and the labels you expect, then run it without `--dry-run`. The script prints what the flag asks for: 225m CPU and 320Mi of memory.
3. **Argo CD syncs three Applications, in waves.** They need the `main` branch on GitHub to have the files:

   | Application | Wave | What |
   | --- | --- | --- |
   | `policy-kyverno-*` | 18 | Kyverno: the four controllers and the CRDs, synced server-side |
   | `policy-network-policies-*` | 19 | Default deny and the allow rules of the `kyverno` namespace (EKS only) |
   | `policy-policies-*` | 20 | The six policies, in Audit |

   The network policies Application fails to sync, on purpose, until the cluster Secret has the annotations `platform.example/service-cidr` and `platform.example/vpc-cidr`. The policies Application skips the dry run while the Kyverno CRDs are missing and retries, so the order inside a first sync heals itself.
4. **Check, in this order** (below). Stop at the first check that fails.

## Check after an apply

All of these are **not run**. In every command, `<EKS_CONTEXT>` is the context of the cluster.

1. **The Applications are Synced and Healthy.** Not run.

   ```bash
   kubectl --context <EKS_CONTEXT> -n argocd get applications | grep policy-
   ```

2. **The Kyverno pods become ready.** Four Deployments are expected: `kyverno-admission-controller`, `kyverno-background-controller`, `kyverno-cleanup-controller` and `kyverno-reports-controller`, one pod each, under the restricted Pod Security level with no admission warning. Not run.

   ```bash
   kubectl --context <EKS_CONTEXT> -n kyverno get deployments,pods
   kubectl --context <EKS_CONTEXT> -n kyverno get events --sort-by=.lastTimestamp | tail -20
   ```

3. **The webhook configurations are registered.** Kyverno creates them itself once the admission controller is ready; their names start with `kyverno`. Not run.

   ```bash
   kubectl --context <EKS_CONTEXT> get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -E '^[^/]+/kyverno'
   kubectl --context <EKS_CONTEXT> get validatingwebhookconfigurations,mutatingwebhookconfigurations -o yaml | grep -E 'failurePolicy|kubernetes.io/metadata.name' | sort | uniq -c
   ```

   The second command should show only `failurePolicy: Ignore`, and the namespaces `kube-system`, `kube-node-lease`, `argocd` and `kyverno` in the exclusions. If a `Fail` is listed, stop and look at the policy that makes it: a dead Kyverno could then block requests.
4. **The admission controller log has no errors.** Not run.

   ```bash
   kubectl --context <EKS_CONTEXT> -n kyverno logs deployment/kyverno-admission-controller --tail=200
   kubectl --context <EKS_CONTEXT> -n kyverno logs deployment/kyverno-background-controller --tail=100
   ```

   Look for lines at level error. A request that cannot reach the Kubernetes API or the webhook port is a network policy problem (see [the flows](#network-flows)).
5. **The CRDs and the policies are there.** The six policies are `require-image-digest`, `restrict-image-registries`, `require-resources`, `require-probes` and `require-app-name-label` (`ValidatingPolicy`) and `verify-image-signatures` (`ImageValidatingPolicy`). Not run.

   ```bash
   kubectl --context <EKS_CONTEXT> get crd | grep -E 'kyverno.io|wgpolicyk8s.io'
   kubectl --context <EKS_CONTEXT> get validatingpolicies.policies.kyverno.io,imagevalidatingpolicies.policies.kyverno.io
   kubectl --context <EKS_CONTEXT> get validatingpolicies.policies.kyverno.io require-image-digest -o yaml
   ```

   In the last one look at the status conditions and at `spec.validationActions`, which must say `Audit`.
6. **Prometheus scrapes Kyverno.** The ServiceMonitor `kyverno` in the `observability` namespace selects the metrics Services; four targets are expected, one per controller. Not run. Open Prometheus as in the [observability runbook](observability.md#reach-grafana-and-prometheus) and run `up{namespace="kyverno"}`.
7. **A policy report appears for `shop`.** Not run. See [reading a report](#read-a-policy-report). With the services deployed, the first background scan should list them; an empty report after a few minutes is worth a look at the background controller log.
8. **The debug container still starts** (see [the busybox probe](#the-busybox-probe)). Not run.

## Read a policy report

Kyverno writes the results of Audit policies into policy reports (`policyreports.wgpolicyk8s.io` for a namespace, `clusterpolicyreports.wgpolicyk8s.io` for cluster-scoped objects). The field names below are those of the PolicyReport API; they have not been seen on this cluster. Not run.

```bash
kubectl --context <EKS_CONTEXT> -n shop get policyreports.wgpolicyk8s.io
kubectl --context <EKS_CONTEXT> -n shop get policyreports.wgpolicyk8s.io -o json \
  | jq -r '.items[].results[] | select(.result == "fail") | [.policy, (.resources[0].kind + "/" + .resources[0].name), .message] | @tsv'
```

- Each failing line names the **policy**, the **workload** (a Pod, or the controller that autogen checked) and the **message** of the policy, for example that a container needs a digest.
- A pod made by a Deployment shows the pod name. Find its owner with `kubectl -n shop get pod <name> -o jsonpath='{.metadata.ownerReferences[0].name}'` and fix the Deployment, not the pod.
- Count the failures for one policy by grepping its name. Sort the policies by how many workloads fail: the cheapest to fix is the first to enforce.
- Pass results are in the same report; `select(.result == "pass")` shows what a policy has checked.

## Move a policy from Audit to Enforce

One policy at a time, in Git, and not before the report is clean.

1. **Read the report for a clean period.** The policy has no `fail` for any workload in `shop`, across at least one deployment of each service and one run of every Job. A policy with open failures is fixed first (the workload, or the chart).
2. **Start with the cheapest to fix.** Probably `require-app-name-label`, then `require-resources`, `require-probes`, `require-image-digest` and `restrict-image-registries`. `verify-image-signatures` last, and only after a real verification has been seen to work (see [signatures](#signatures)): it is not turned on by `values-enforce.yaml`.
3. **Change the value for that policy only,** in `platform/security/policies/values.yaml`:

   ```yaml
   policies:
     requireAppNameLabel:
       action: Enforce
   ```

   `values-enforce.yaml` turns five on at once (everything but the signature policy) and is for when all five are clean. It is added after `values.yaml` in the `valueFiles` of `platform/argocd/apps/86-policy-policies.yaml`.
4. **Merge, let Argo CD sync, and check** that `spec.validationActions` of the policy now says `Deny`.
5. **Watch the next deploy.** If it is blocked, see below. If a policy blocks something that must go through, set it back to Audit in Git; the break-glass routes are below.

## A deploy is blocked

Only a policy in Enforce blocks; with Audit nothing does. The webhooks fail open, so a block means Kyverno answered "no", not that it is down.

1. **Read the message.** The error of `kubectl apply`, or the sync error of the Argo CD Application, names the policy and its message (for example that a container needs a digest). The report shows the same.
2. **Fix the workload.** A digest, an image from the platform registry, requests and a memory limit, probes, the label `app.kubernetes.io/name`. The service chart does all of this already; a failure of a service chart is a finding about the chart or the values file, not a reason to turn the policy off.
3. **Do not copy the exempt label.** The label `platform.example/policy-exempt: "true"` makes every policy skip a workload. It exists for one Job (the RabbitMQ credentials copy, which runs a public `curl` image, and which is rendered only in generated mode, the default; in external mode an ExternalSecret replaces it and the label is not used) and it is **not protected**: anyone can add it to a workload. Putting it on a workload to get a deploy through is a security decision and not a fix. The way to remove the weak spot is to run that Job from a pinned image of ours ([ADR-0025](../adr/0025-admission-policies.md)).
4. **Break-glass, in order of speed.**
   - **Set the policy back to Audit in Git** (`policies.<name>.action: Audit`, or `action: Audit` for all) and let Argo CD sync. This is the normal way.
   - **In an emergency, delete Kyverno's webhook configurations.** The webhooks fail open and Kyverno recreates them, so this is safe: requests pass until Kyverno is back. Not run.

     ```bash
     kubectl --context <EKS_CONTEXT> get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -E '^[^/]+/kyverno'
     kubectl --context <EKS_CONTEXT> delete <each name from the list>
     ```

     Delete only the names that start with `kyverno`: the configurations of cert-manager and the load balancer controller are not Kyverno's.
   - **Turn the Application off** by removing the label (`platform.example/policy-`) from the cluster Secret, as the teardown does; the policies, Kyverno and their network policies are then removed.

## The busybox probe

[The network policy runbook](network-policies.md#check-after-an-apply) starts a busybox ephemeral container from `docker.io` in the `shop` namespace. It should keep working under the policies, because:

- an ephemeral container is added through the subresource `pods/ephemeralcontainers`, and the policies match `pods` and no subresource;
- the policies look at `containers` and `initContainers`, never at `ephemeralContainers`.

This was checked on the policy expressions and in the Kyverno CLI tests. **Admission through the real webhook has not been tried.** To check it, define the `probe` function and `DEBUG_IMAGE` as in that runbook, then run it once the policies are applied (in Audit and, later, in Enforce):

```bash
probe shop app.kubernetes.io/name=orders nslookup kubernetes.default.svc.cluster.local
```

The ephemeral container must start as it did before. If it is refused, the message names the policy: stop, read the message, and tell the owner of the policies, because it means the webhook matches more than the chart says. As a stop-gap set that policy back to Audit. A pod that gets a debug container should not appear in the report as a failure because of it. Not run.

## Network flows

The network policies of the `kyverno` namespace allow: DNS, the Kubernetes API through the Service range on 443 (each controller), the webhook port **9443** of the admission and cleanup controllers from the **VPC range**, Prometheus on **8000**, and TCP **443** to every address except the VPC and Service ranges for the admission controller only. Not run on a cluster; the flows are checked offline by `scripts/network-policies-check.sh`.

**The admission controller is unreachable from the API server.** The webhooks fail open, so requests still pass but each one waits for the webhook timeout, and Kyverno applies nothing. Look at:

```bash
kubectl --context <EKS_CONTEXT> -n kyverno get networkpolicy
kubectl --context <EKS_CONTEXT> -n argocd get secret cluster-in-cluster -o jsonpath='{.metadata.annotations.platform\.example/vpc-cidr}'; echo
```

- The annotation `platform.example/vpc-cidr` must be the VPC range, because the API server calls the webhook from its own network interfaces in the VPC. A wrong range blocks the call on port 9443.
- Policies must be programmed on the node: see the [network policy runbook](network-policies.md#see-what-is-being-dropped) for the agent logs.

**Kyverno cannot reach the API server.** The controllers log errors about the API and do not become ready. The rules are `allow-kube-api-*` on the Service range, port 443, and the annotation `platform.example/service-cidr`. See the [network policy runbook](network-policies.md#check-after-an-apply) (DNS first).

**The admission controller cannot verify signatures** (the signature policy logs an error about the registry or about Sigstore). The rule is `admission-allow-internet-https`: TCP 443 to every address except the VPC and Service ranges, for the admission controller only. What it covers: a registry and the Sigstore services. A private GHCR package would also need a pull secret for the admission controller, which is not set up.

## Signatures

The signature policy loads (its CEL compiles) and has been compared with `scripts/verify-image.sh` for the issuer, the identity, the transparency log entry, the SBOM and the provenance, but **it has never verified a real image**. The SBOM and provenance predicate types are the ones cosign maps for `spdxjson` and `slsaprovenance1`; they have not been seen in our attestations. Before enforcing it:

1. Run `scripts/verify-image.sh all` and confirm that the three checks pass for the digests in `deploy/helm/values/images.yaml`.
2. Read the report for `verify-image-signatures` on a cluster, in Audit: every image of the services must pass. A failure with all three checks passing in the script means the policy and the attestations disagree (the predicate types first).
3. Only then decide whether to enforce it, with the registry and the Sigstore services reachable from the admission controller.

## Teardown

Kyverno's webhook configurations and its policies must go before the namespaces and Argo CD, or a webhook with no controller behind it can block the deletions that follow. The scripts do it ([data layer teardown](data-layer.md#teardown), [Argo CD teardown](argocd.md#teardown)):

- `scripts/teardown-prep.sh` has 16 steps (13 with `--skip-aws`). It removes the label `platform.example/policy` with the others, waits for the `policy-*` Applications, then deletes every `ClusterPolicy`, `Policy`, `ValidatingPolicy` and `ImageValidatingPolicy`, then the validating and mutating webhook configurations whose names start with `kyverno` and only those, and waits for them to be gone.
- `scripts/teardown-argocd.sh` has 11 steps and refuses to start while a Kyverno policy or webhook configuration is left.
- Both are tested against a fake `kubectl` and not against a cluster. Run `--dry-run` first and read the output.

## What has not been run

- Kyverno on a cluster, and compatibility with Kubernetes 1.37 (the project documents 1.33 to 1.35).
- A real signature verification, and the predicate types of our attestations.
- Admission of an ephemeral container through the real webhook.
- Autogen on the cluster (the Kyverno CLI applies it in `kyverno test`, not in `kyverno apply`).
- Egress for the signature checks, and a pull secret for a private package.
- The high availability profile (`values-ha.yaml`) on three nodes.
- The teardown steps against a real cluster.
