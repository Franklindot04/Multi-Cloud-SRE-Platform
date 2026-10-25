# Terraform modules

Reusable, versionable building blocks consumed by the environment stacks.

Conventions:

- One responsibility per module (for example `network`, `cluster`, `iam`).
- Each module contains `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf` and a `README.md`.
- No provider configuration or backend blocks inside modules.
- Inputs are typed and documented; outputs expose only what callers need.
- Cloud-specific modules are prefixed `aws-` or `gcp-`; cloud-neutral modules are not.

See [ADR-0004](../../../docs/adr/0004-terraform-module-and-state-conventions.md).
