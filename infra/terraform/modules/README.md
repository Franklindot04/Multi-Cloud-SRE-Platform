# Terraform modules

Reusable building blocks consumed by the environment stacks. Start new modules from [`_template`](_template). Conventions follow [ADR-0004](../../../docs/adr/0004-terraform-module-and-state-conventions.md).

Modules require Terraform 1.11 or later (`required_version = ">= 1.11"`).

## File layout

| File | Contents |
| --- | --- |
| `main.tf` | Resources, data sources and locals |
| `variables.tf` | Input variables |
| `outputs.tf` | Outputs |
| `versions.tf` | `required_version` and `required_providers` |
| `README.md` | Purpose, usage example, inputs and outputs |

Split `main.tf` by concern (for example `iam.tf`) once it grows past a few hundred lines.

## Standards

- **One responsibility per module.** Compose larger systems in the environment stacks.
- **No provider or backend configuration.** Modules declare required providers with minimum versions only.
- **Naming.** Directories are lowercase kebab-case; cloud-specific modules are prefixed `aws-` or `gcp-`. Resources are named `<name>-<environment>-<purpose>`; the Terraform resource label describes the role (`this` for a single primary resource).
- **Tagging.** Stacks set `project`, `environment`, `managed-by` and `owner` through provider default tags or labels. Modules accept a `tags` map, merge it with their own, and apply it to anything that supports tags or labels.
- **Input validation.** Every variable has a type and description. Constrain values with `validation` blocks where a bad value would otherwise fail late or silently (names, enums, CIDR ranges, numeric bounds).
- **No hardcoded regions, account IDs or project IDs.** Take them from variables, provider configuration or data sources (`aws_region`, `aws_caller_identity`, `google_project`).
- **Sensitive values.** Mark secrets `sensitive` and avoid outputting them.
- **Outputs.** Expose only what callers need, each with a description.

## Versioning

Modules are versioned with [semantic versioning](https://semver.org/) using per-module Git tags of the form `<module-name>/vMAJOR.MINOR.PATCH`.

- **Major:** breaking change to inputs, outputs or resource addresses (including anything that forces replacement).
- **Minor:** backwards-compatible addition.
- **Patch:** backwards-compatible fix.

Environment stacks currently reference modules by relative path. If modules move to separate repositories or a registry, callers pin an exact tag or version.

## Checklist

- [ ] `terraform fmt` and `terraform validate` pass
- [ ] `tflint` passes
- [ ] Variables and outputs have descriptions
- [ ] Inputs are validated
- [ ] No hardcoded regions or IDs
- [ ] README documents usage
