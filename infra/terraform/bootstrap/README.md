# Terraform bootstrap

One-time stacks that create what everything else depends on:

- Remote state backends (S3 + DynamoDB lock on AWS, GCS on GCP)
- CI/CD identity federation (GitHub OIDC to AWS IAM and GCP Workload Identity)
- Baseline accounts, projects and budget alerts

Bootstrap stacks are applied manually by a maintainer, rarely, and use local state that is migrated to the remote backend after creation. See [ADR-0004](../../../docs/adr/0004-terraform-module-and-state-conventions.md).
