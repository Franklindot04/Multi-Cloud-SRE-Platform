# GCP environments

Root Terraform stacks for the GCP side of the platform (VPC, GKE, IAM, supporting services). Each environment (for example `dev`, `prod`) gets its own subdirectory, backend configuration and state.

Environments compose modules from [`../../modules`](../../modules) and contain no resource logic of their own beyond wiring.
