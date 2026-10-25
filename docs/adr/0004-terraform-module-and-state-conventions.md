# ADR-0004: Terraform module and state conventions

- Status: Accepted
- Date: 2026-10-25
- Revised: 2026-10-25 (state locking, per-cloud root stacks, lint and lock file practice)

## Context

Infrastructure for two clouds and multiple environments will be authored by several contributors over time. Without conventions, state handling, module boundaries and versioning will diverge and make changes risky.

## Decision

Layout

- `infra/terraform/bootstrap/{aws,gcp}`: one-time stacks that create the state buckets. They use local state because they create the backend themselves, and are applied manually.
- `infra/terraform/modules`: reusable modules, one responsibility each, with typed and validated variables, documented outputs, and a `versions.tf` declaring minimum provider versions. New modules start from `_template`.
- `infra/terraform/environments/{aws,gcp}`: one root stack per cloud. The environment (`dev`, `staging`, `prod`) is an input variable, and each environment has its own state key selected at init time.

State

- Remote state only, one state per cloud and environment, to keep the blast radius small.
- AWS state lives in S3 with native state locking (`use_lockfile`, stable from Terraform 1.11); no DynamoDB table is used. GCP state lives in GCS, which locks natively.
- Buckets are versioned, encrypted, closed to public access and TLS-only, with lifecycle rules that expire old noncurrent versions.
- Backend blocks are partial configuration. Bucket and key (or prefix) are passed with `-backend-config` files named `backend.<environment>.hcl`. These files are local only and ignored by Git; each is created by copying the tracked `backend.hcl.example`.
- No secrets in variables files or outputs; sensitive values are marked `sensitive`.

Practices

- Require Terraform 1.11 or later (S3 native locking is stable from 1.11) and pin provider major versions with `~>` in root stacks. Modules declare minimum versions only.
- Commit `.terraform.lock.hcl` for root stacks and bootstrap stacks, with hashes for the Linux and macOS platforms in use (`terraform providers lock`). Modules do not commit lock files; they inherit provider versions from the stack that calls them.
- Modules contain no provider or backend configuration, and no hardcoded regions or account IDs.
- Naming and tagging/labelling follow a common scheme: `project`, `environment`, `managed-by`, `owner`, applied through provider default tags or labels.
- `terraform fmt -check`, `init -backend=false` plus `validate`, and `tflint` (core, AWS and GCP rulesets) run in CI on every pull request without cloud credentials. Modules also carry native `terraform test` suites under `tests/` that use mocked providers and `command = plan`, so they run in CI without credentials too. Plans run on pull requests and applies run only from the main branch through an approved workflow, both authenticated by OIDC federation, not stored keys.
- Modules are versioned with semantic versioning using per-module tags (`<module>/vX.Y.Z`).

## Consequences

- Smaller, safer changes and clear ownership of state.
- No lock table to provision or pay for on AWS.
- One stack per cloud keeps duplication low, at the cost of relying on discipline (the `environment` variable and the backend config) to avoid applying to the wrong environment.
- A one-time manual bootstrap step is required and documented in the [Terraform bootstrap runbook](../runbooks/terraform-bootstrap.md).

## Alternatives considered

- Workspaces for environments: share backend configuration and make accidental cross-environment changes easier.
- A directory per environment: stronger isolation, but duplicates wiring; may be adopted if environments diverge.
- DynamoDB locking: still supported but deprecated in favour of S3 native locking.
- Terragrunt: reduces duplication but adds a tool; may be adopted later if duplication becomes costly.
- Single monolithic state: simplest, but unacceptable blast radius.
