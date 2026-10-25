# AWS state bootstrap

Creates the S3 bucket that holds Terraform state for the AWS environment stacks.

## What it creates

- S3 bucket (default name `<project>-tfstate-<account id>-<region>`) with ownership enforced
- Versioning enabled
- Server-side encryption (SSE-S3, bucket key enabled)
- Public access block on all four settings
- Bucket policy denying non-TLS requests
- Lifecycle rules: expire noncurrent versions after 90 days (keeping the newest 10), remove expired delete markers, abort incomplete multipart uploads after 7 days

State locking uses S3 native lock files (`use_lockfile`), so no DynamoDB table is created.

## Requirements

- Terraform 1.11 or later
- AWS credentials with permission to manage S3 buckets, policies and lifecycle configuration in the target account

## Run once

```bash
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Override defaults with `-var` or a local `terraform.tfvars` (ignored by Git). Useful inputs: `region`, `project`, `owner`, `state_bucket_name`.

## Migrate to the remote backend

The stack starts on local state. After the apply, move its state into the new bucket:

1. Create `backend.tf` in this directory (the file is local to the maintainer's checkout; do not commit it unless the team decides to):

   ```hcl
   terraform {
     backend "s3" {
       bucket       = "<STATE_BUCKET_NAME>"
       key          = "bootstrap/aws/terraform.tfstate"
       region       = "eu-north-1"
       encrypt      = true
       use_lockfile = true
     }
   }
   ```

2. Run `terraform init -migrate-state` and answer `yes`.
3. Confirm with `terraform state list`, then delete the local `terraform.tfstate*` files.

Get the bucket name with `terraform output state_bucket_name` before migrating.

## Teardown

See the [runbook](../../../../docs/runbooks/terraform-bootstrap.md#teardown). Destroy this stack only after every environment stack using the bucket has been destroyed.
