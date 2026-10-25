# ADR-0004: Terraform module and state conventions

- Status: Accepted
- Date: 2026-10-25

## Context

Infrastructure for two clouds and multiple environments will be authored by several contributors over time. Without conventions, state handling, module boundaries and versioning will diverge and make changes risky.

## Decision

Layout

- `infra/terraform/bootstrap`: one-time stacks for state backends and CI identity.
- `infra/terraform/modules`: reusable modules, one responsibility each, with typed and documented variables, explicit outputs, and a `versions.tf` pinning required providers.
- `infra/terraform/environments/<cloud>/<env>`: root stacks that wire modules together.

State

- Remote state only, one state per environment and cloud, to keep the blast radius small.
- AWS state in S3 with native locking or DynamoDB locking; GCP state in GCS. Buckets are versioned and encrypted, with restricted access.
- No secrets in variables files or state outputs where avoidable; sensitive values are marked `sensitive`.

Practices

- Pin Terraform and provider versions; commit `.terraform.lock.hcl`.
- Modules contain no provider or backend configuration.
- Naming and tagging/labelling follow a common scheme (project, environment, owner, managed-by).
- `terraform fmt`, `validate` and a static analysis tool run in CI; plans run on pull requests and applies run only from the main branch through an approved workflow.
- CI authenticates through OIDC federation, not stored keys.

## Consequences

- Smaller, safer changes and clear ownership of state.
- More directories and some duplication between environments in exchange for isolation.
- A one-time manual bootstrap step is required and documented.

## Alternatives considered

- Workspaces for environments: share backend configuration and make accidental cross-environment changes easier.
- Terragrunt: reduces duplication but adds a tool; may be adopted later if duplication becomes costly.
- Single monolithic state: simplest, but unacceptable blast radius.
