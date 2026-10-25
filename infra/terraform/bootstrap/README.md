# Terraform bootstrap

One-time stacks that create the remote state buckets everything else depends on. Each cloud has its own stack:

| Stack | Creates |
| --- | --- |
| [`aws/`](aws) | S3 state bucket in `eu-north-1` |
| [`gcp/`](gcp) | GCS state bucket in `europe-north1` |

Bootstrap stacks are applied manually by a maintainer, once, using local state. State is then migrated into the bucket each stack created. CI identity federation (GitHub OIDC) is added in a later change. Step-by-step instructions are in the [Terraform bootstrap runbook](../../../docs/runbooks/terraform-bootstrap.md); conventions are in [ADR-0004](../../../docs/adr/0004-terraform-module-and-state-conventions.md).
