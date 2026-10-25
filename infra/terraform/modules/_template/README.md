# Module template

Starting point for new modules. Copy this directory to `../<module-name>` (prefix with `aws-` or `gcp-` for cloud-specific modules), then:

1. Replace this README with the module's purpose, usage example, inputs and outputs.
2. Declare required providers in `versions.tf`.
3. Add resources to `main.tf` and expose only what callers need in `outputs.tf`.
4. Review the checklist in [../README.md](../README.md).

## Usage

```hcl
module "example" {
  source = "../../modules/<module-name>"

  name        = "platform"
  environment = "dev"
  tags        = { owner = "platform-team" }
}
```
