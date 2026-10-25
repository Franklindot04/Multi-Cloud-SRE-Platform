# ADR-0003: GitOps with Argo CD

- Status: Accepted
- Date: 2026-10-25

## Context

Both clusters need consistent, auditable and recoverable configuration for platform add-ons and applications. Manual `kubectl` or pipeline-driven pushes make drift likely and rollbacks inconsistent.

## Decision

- Git is the source of truth for everything that runs inside the clusters.
- Argo CD reconciles desired state onto the clusters, with automated sync, pruning and self-heal enabled for non-production and reviewed per application for production.
- A single Argo CD instance acts as a hub and manages both clusters, using the app-of-apps pattern (with ApplicationSets for per-cluster fan-out).
- Argo CD `AppProject`s separate platform components from workloads and restrict source repositories, destinations and resource kinds.
- Terraform bootstraps the clusters and installs Argo CD; after that, in-cluster changes flow only through Git.
- Secrets are never stored in plain text in Git; they are referenced through an external secrets mechanism.

## Consequences

- Changes are reviewed, versioned and revertible through pull requests.
- Drift is detected and corrected automatically.
- The hub is a critical dependency; its availability and its credentials for both clusters need explicit protection and a documented recovery path.
- Contributors must learn the Argo CD model and repository conventions.

## Alternatives considered

- Flux: capable and lightweight, but Argo CD's UI and ApplicationSet model suit multi-cluster demonstration.
- Push-based CI/CD (pipelines running `helm upgrade`): simpler initially, but weaker on drift detection and auditability.
- One Argo CD per cluster: better isolation, more to operate; may be revisited for production hardening.
