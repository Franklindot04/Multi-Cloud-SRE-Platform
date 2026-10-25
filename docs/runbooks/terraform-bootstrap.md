# Terraform bootstrap

Creates, migrates and (if ever needed) removes the remote state buckets. Run once per cloud by a maintainer.

## Cost

The state buckets cost pennies per month: state files are a few kilobytes, and lifecycle rules cap the number of retained versions. No other cloud resources are created by this runbook. The Kubernetes clusters, which carry real cost, come in later changes.

## Prerequisites

- Terraform 1.11 or later
- AWS: credentials for the target account (for example through `aws sso login`), region `eu-north-1`
- GCP: an existing project with billing enabled, and `gcloud auth application-default login`
- A clean checkout of the repository

## AWS

1. Confirm the identity: `aws sts get-caller-identity`.
2. Apply the stack:

   ```bash
   cd infra/terraform/bootstrap/aws
   terraform init
   terraform plan -out=tfplan
   terraform apply tfplan
   ```

3. Record the bucket name: `terraform output state_bucket_name`.
4. Migrate state: create `backend.tf` as described in the [stack README](../../infra/terraform/bootstrap/aws/README.md#migrate-to-the-remote-backend), then run `terraform init -migrate-state`.
5. Verify with `terraform state list`, then remove the local `terraform.tfstate*` files.

## GCP

1. Confirm the identity and project: `gcloud auth list` and `gcloud config get-value project`.
2. Apply the stack:

   ```bash
   cd infra/terraform/bootstrap/gcp
   terraform init
   terraform plan -var project_id=<PROJECT_ID> -out=tfplan
   terraform apply tfplan
   ```

3. Record the bucket name: `terraform output state_bucket_name`.
4. Migrate state: create `backend.tf` as described in the [stack README](../../infra/terraform/bootstrap/gcp/README.md#migrate-to-the-remote-backend), then run `terraform init -migrate-state`.
5. Verify with `terraform state list`, then remove the local `terraform.tfstate*` files.

## Point the environment stacks at the buckets

In `infra/terraform/environments/<cloud>`, copy the tracked `backend.hcl.example` to `backend.<environment>.hcl`, replace the placeholders with the bucket name and environment, then run `terraform init -backend-config=backend.<environment>.hcl`. The real backend file is local only and ignored by Git; only the example is tracked.

## Verification

- The bucket exists with versioning enabled and public access blocked.
- A `terraform plan` in the bootstrap directory shows no changes after migration.
- Initialising an environment stack succeeds and creates a state object under the expected key.

## Teardown

Only tear down the buckets after every stack that stores state in them has been destroyed.

1. Destroy the environment stacks first (`terraform destroy` in each).
2. In the bootstrap stack, allow the bucket to be removed with its contents and apply that setting:

   ```bash
   terraform apply -var force_destroy=true
   ```

3. Migrate state back to local so the bucket is not holding its own state: remove `backend.tf`, run `terraform init -migrate-state`, and answer `yes`.
4. Run `terraform destroy -var force_destroy=true` (plus `-var project_id=<PROJECT_ID>` on GCP).
5. Confirm the bucket is gone in the cloud console or CLI.

## Troubleshooting

- **Bucket name already taken:** bucket names are global. Set `state_bucket_name` to a different value.
- **State lock error on AWS:** a `.tflock` object remains from an interrupted run. Confirm nobody else is running Terraform, then use `terraform force-unlock <LOCK_ID>`.
- **Access denied on init:** the identity needs read and write on the bucket, including the lock object on AWS.
