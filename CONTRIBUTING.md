# Contributing

## Workflow

1. Create a branch from `main` using the naming convention below.
2. Make focused changes and keep pull requests small.
3. Run `make fmt lint validate docs` locally, and install the hooks with `pre-commit install`.
4. Open a pull request using the template. CI must pass and a code owner must approve.
5. Squash merge into `main`.

## Branch naming

Use `<type>/<short-kebab-description>`:

| Type | Use for |
| --- | --- |
| `feat` | New functionality |
| `fix` | Bug fixes |
| `chore` | Maintenance and tooling |
| `docs` | Documentation only |
| `refactor` | Restructuring without behaviour change |
| `ci` | CI/CD changes |
| `infra` | Infrastructure changes |

Examples: `feat/eks-cluster-module`, `docs/adr-gitops`, `fix/lint-workflow-path`.

## Commit messages

This project follows [Conventional Commits](https://www.conventionalcommits.org/):

```text
<type>(<optional scope>): <summary in imperative mood>

<optional body explaining what and why>
```

Types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `ci`, `build`, `perf`, `revert`.

Examples:

- `feat(terraform): add aws network module`
- `docs(adr): record observability stack decision`
- `fix(ci): correct yamllint config path`

Keep the summary under 72 characters. Mark breaking changes with `!` after the type or a `BREAKING CHANGE:` footer.

## Standards

- Significant decisions need an ADR (see [docs/adr](docs/adr)).
- Paging alerts need a runbook.
- Never commit secrets, state files or credentials.
- Terraform follows the conventions in [ADR-0004](docs/adr/0004-terraform-module-and-state-conventions.md).
