# ADR-0011: Cluster baseline add-ons

- Status: Accepted
- Date: 2026-10-26

## Context

Both clusters need the same baseline before applications arrive: a way to expose services, DNS automation, certificates and resource metrics. Per [ADR-0003](0003-gitops-with-argo-cd.md), everything inside the clusters is delivered by Argo CD from Git. The platform does not yet own a domain, and Argo CD arrives in the next change, so this decision defines what is deployed and what it is allowed to do, without installing anything.

## Decision

Ingress strategy per cloud

- **EKS:** the AWS Load Balancer Controller. It turns `Ingress` resources into ALBs and `Service` objects of type `LoadBalancer` into NLBs, integrates with the VPC subnet tags already set by the `aws-network` module, and is maintained by AWS.
- **GKE:** the built-in GKE Ingress (classes `gce` and `gce-internal`), with no controller installed. Google Cloud manages the load balancer integration. GKE Gateway API is the preferred longer-term model and will be adopted by enabling it on the cluster in a later change.
- **ingress-nginx is not used.** The Kubernetes project retired it, with no releases or security fixes after March 2026. Choosing the cloud-native integration on each side also avoids operating a proxy fleet of our own. Where portability between clouds matters, the Gateway API is the intended common interface.

external-dns

- Publishes `Ingress` and `Service` host names to Route 53 (EKS) and Cloud DNS (GKE). It runs with `upsert-only` so it never deletes records, a TXT registry with a per-cluster owner ID so the clusters cannot overwrite each other's records, and mandatory domain filters.
- It is **disabled by default** (a wrapper chart condition), because without a domain filter it would try to manage every zone it can see. It is switched on only when a domain and zone exist.

cert-manager

- Installed with its CRDs from the chart (kept on uninstall). Issuers are a separate chart that is deployed afterwards, because the issuer resources need the CRDs to exist first.
- A **self-signed ClusterIssuer and a CA-style issuer** work with no domain and are on by default. The CA issuer lets workloads trust one root instead of many self-signed certificates, and covers in-cluster and mTLS-style use until a public domain exists.
- **DNS-01 ClusterIssuers** (Let's Encrypt through Route 53 or Cloud DNS) are present as manifests but disabled and unreferenced. DNS-01 is preferred over HTTP-01 for this platform because it needs no inbound reachability, supports wildcard certificates, and works the same on both clouds. It needs a real domain, so it stays off until one exists. The issuers default to the Let's Encrypt staging server.

Least-privilege cloud access

- Add-ons authenticate with **IAM roles for service accounts** on EKS and **Workload Identity** on GKE, never with static keys. Each role trusts exactly one namespace and service account.
- AWS roles come from the generic `aws-irsa` module. The load balancer controller uses the controller project's official policy, vendored at the version matching the chart. The DNS roles are scoped to a single hosted zone ID. On GCP, `roles/dns.admin` is granted on the single managed zone, plus project-level `roles/dns.reader`, because listing zones is a project operation. Roles for the DNS add-ons are disabled by default.
- The load balancer controller needs the cluster name, region and VPC ID set explicitly, because node IMDSv2 is limited to one hop and pods cannot read instance metadata.

Definitions separate from installation

- Add-ons are defined as pinned wrapper charts in `platform/addons`, validated in CI (`helm lint`, `helm template`, `kubeconform` at the clusters' Kubernetes versions, `yamllint`) with no cluster. Terraform creates only the cloud permissions. Argo CD installs the charts. This keeps one source of truth for what runs, lets definitions be reviewed and tested before a cluster exists, and keeps cluster contents out of Terraform state.

Version pinning policy

- Exact chart versions in `Chart.yaml`, resolved digests in a committed `Chart.lock`, and the date and source of each check recorded in `platform/addons/README.md`. No ranges and no `latest`. Updates are pull requests that regenerate the lock and pass the checks. Versions are reviewed at least monthly and on upstream security fixes.

## Consequences

- Both clouds get a working, maintained ingress path without running a proxy of our own.
- The two clouds differ in ingress objects (`alb` versus `gce`), so manifests per cloud differ until the Gateway API is adopted.
- Definitions can be validated and reviewed before any cluster exists, at the cost of placeholder values that must be filled from Terraform outputs.
- Certificates work immediately through the self-signed and CA issuers; publicly trusted certificates wait for a domain.
- Chart upgrades are deliberate, which means keeping up with upstream, especially cert-manager CRD changes.

## Alternatives considered

- ingress-nginx or another self-run ingress controller on both clouds: portable, but retired, or additional software to run and patch.
- Installing add-ons from Terraform (Helm provider): simple, but ties cluster contents to Terraform state and bypasses GitOps review.
- Kustomize with `helmCharts`: workable, but needs plugin flags in Argo CD and has weaker dependency pinning than a locked wrapper chart.
- HTTP-01 challenges: simpler for a single host, but need inbound reachability and no wildcards.
- Static cloud credentials in secrets: rejected in favour of short-lived federated identity.
