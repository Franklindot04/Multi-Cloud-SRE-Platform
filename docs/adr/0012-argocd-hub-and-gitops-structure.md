# ADR-0012: Argo CD hub and GitOps structure

- Status: Accepted
- Date: 2026-10-26

## Context

[ADR-0003](0003-gitops-with-argo-cd.md) chose Argo CD as the GitOps engine and [ADR-0011](0011-cluster-baseline-addons.md) defined the add-ons it deploys. This decision covers how Argo CD itself is deployed and structured. Only the EKS cluster exists today and GKE will be added later, the repository is public, and identifiers such as account IDs, VPC IDs, role ARNs and project IDs must not be committed.

## Decision

Single hub

- One Argo CD instance runs on the EKS cluster and manages every cluster, rather than one instance per cluster. It gives one place to see and compare both clouds, and one set of definitions to maintain. The trade-off is that the hub is a critical dependency with credentials to the other clusters: if the hub is down, running workloads are unaffected but deployments pause. The HA values profile (`values-ha.yaml`) is ready for when that matters, and a per-cluster instance remains an option for stricter isolation.
- The hub is small by default: one replica of each component, resource requests and limits, no Dex, no notifications. Argo CD manages its own upgrades through an Application, so after the first install a version bump is a pull request.

App-of-apps plus ApplicationSets

- A root Application (`platform-root`) points at `platform/argocd/apps`. That directory holds the Application for Argo CD itself and one ApplicationSet per add-on.
- ApplicationSets use the cluster generator with a label selector. A new cluster that carries the right labels receives its add-ons automatically, with no change to the repository. The root Application only needs to know about ApplicationSets, not about individual clusters or add-ons, so the app-of-apps stays small and stable.
- Where an add-on differs per cloud (identity annotations, role names), there is one ApplicationSet per cloud with static parameter names instead of conditionals in templates. The cloud overlay values file (`values-aws.yaml` or `values-gcp.yaml`) is chosen from the cluster's `cloud` label.

Keeping identifiers out of Git

- The add-on values files hold no account IDs, VPC IDs, role ARNs, project IDs or domains. Those live as annotations on the Argo CD cluster Secret and are passed to the charts as Helm parameters by the ApplicationSets. Labels on the same Secret decide which optional add-ons run (external-dns, DNS-01 issuers), defaulting to off.
- The Secret is created by the bootstrap script from Terraform outputs, so Terraform remains the source of truth for identifiers and nothing has to be edited by hand. The Secret contains no credentials for the in-cluster case; registering a remote cluster adds its connection credentials to the same kind of Secret.
- CI uses fixture values in each add-on's `ci/` directory, and a render test confirms that every templated parameter takes effect, so a misspelt parameter name fails a pull request.

Sync waves and ordering

- The ApplicationSets carry sync waves (priority classes, cert-manager, issuers, metrics-server and load balancer controller, external-dns). Waves order the creation of the ApplicationSets; each Application then syncs independently.
- The one hard dependency, issuers after cert-manager's CRDs and webhook, is enforced by a PreSync hook in the issuers chart, backed by retries with backoff and `SkipDryRunOnMissingResource`, rather than by relying on waves across Applications.
- Add-ons sync automatically with prune and self-heal, with server-side apply for CRD-heavy charts. `ignoreDifferences` is limited to fields that something else writes (webhook CA bundles, generated certificates, Argo CD's own secrets).

Project restrictions

- Two AppProjects: `platform-system` for Argo CD and the GitOps definitions (only the `argocd` namespace on the hub) and `platform-addons` for the add-ons. Both allow only this repository as a source. `platform-addons` allows only the namespaces the add-ons use and an explicit allowlist of cluster-scoped kinds (CRDs, RBAC, webhooks, API services, priority classes, ingress classes, cluster issuers). Orphaned-resource monitoring warns about unmanaged resources in those namespaces.

Why bootstrap is a script, not Terraform

- Terraform owns cloud resources; cluster contents belong to Git (ADR-0003). Installing Argo CD from Terraform would tie a Helm release to Terraform state and need Kubernetes and Helm providers authenticated to a cluster that Terraform has just created, which is a well-known source of ordering and credential problems.
- The bootstrap is a one-time, human-supervised step that needs a deliberate kubectl context. A script can require that context explicitly, check that it points at the intended cluster and account, support a dry run, and print the access instructions. After it runs, Git takes over, including Argo CD's own upgrades.

Security posture

- No ingress and no public exposure. The server runs in plain HTTP mode inside the pod because it is reachable only through `kubectl port-forward`, which the Kubernetes API already authenticates and encrypts. This setting is removed when an ingress with TLS is added.
- The default RBAC policy is read-only. The built-in admin account is kept only for bootstrap, with a documented step to rotate the password and delete the initial secret; SSO replaces it later.
- The chart's default network policies are on. The bootstrap script never writes secrets to disk or prints them.

## Consequences

- One pane of glass for both clouds, at the cost of the hub being a critical dependency that needs its own backup and recovery plan (its definitions are in Git, so it can be rebuilt by re-running the bootstrap).
- Adding GKE means registering a cluster Secret; the repository does not change.
- A first install needs two applies in order: Terraform, then the bootstrap script. The root Application reads Git, so the GitOps definitions must be on `main` before the bootstrap.
- Cluster identifiers exist only in cluster Secrets and Terraform state, so they must be recreated if a cluster is rebuilt; the bootstrap script does this from Terraform outputs.
- Per-cloud ApplicationSets mean a few more files than a single templated set, in exchange for plain, testable templates.

## Alternatives considered

- One Argo CD per cluster: better isolation and no cross-cluster credentials, but duplicated management and no single view.
- Terraform-managed Argo CD (Helm provider): one tool, but couples cluster contents to Terraform state and provider authentication.
- Storing identifiers in values files in Git: simplest, but puts account IDs and ARNs in a public repository.
- A single ApplicationSet with conditionals for every cloud difference: fewer files, but templates that are harder to read and test.
- Multi-source Applications with a separate values repository: flexible, but unnecessary here and adds a second source to keep consistent.
- Waves alone for CRD ordering: they do not order generated Applications relative to each other, so a hook is used for the one dependency that matters.
