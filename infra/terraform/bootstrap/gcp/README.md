# GCP state bootstrap

Creates the GCS bucket that holds Terraform state for the GCP environment stacks.

## What it creates

- GCS bucket in `europe-north1` (default name `<project id>-tfstate`)
- Object versioning enabled
- Uniform bucket-level access
- Public access prevention enforced
- Lifecycle rules: delete noncurrent versions beyond the newest 10, and any noncurrent version older than 90 days

GCS provides state locking natively.

## Requirements

- Terraform 1.11 or later
- An existing GCP project with billing enabled and the Cloud Storage API available
- Application default credentials (`gcloud auth application-default login`) for an identity that can create buckets in the project

## Run once

```bash
terraform init
terraform plan -var project_id=<PROJECT_ID> -out=tfplan
terraform apply tfplan
```

Other inputs: `region`, `project`, `owner`, `state_bucket_name`.

## Migrate to the remote backend

The stack starts on local state. After the apply, move its state into the new bucket:

1. Create `backend.tf` in this directory (local to the maintainer's checkout):

   ```hcl
   terraform {
     backend "gcs" {
       bucket = "<STATE_BUCKET_NAME>"
       prefix = "bootstrap/gcp"
     }
   }
   ```

2. Run `terraform init -migrate-state` and answer `yes`.
3. Confirm with `terraform state list`, then delete the local `terraform.tfstate*` files.

Get the bucket name with `terraform output state_bucket_name` before migrating.

## Teardown

See the [runbook](../../../../docs/runbooks/terraform-bootstrap.md#teardown). Destroy this stack only after every environment stack using the bucket has been destroyed.
