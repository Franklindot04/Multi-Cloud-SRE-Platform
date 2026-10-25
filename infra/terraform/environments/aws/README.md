# AWS environments

Root Terraform stacks for the AWS side of the platform (VPC, EKS, IAM, supporting services). Each environment (for example `dev`, `prod`) gets its own subdirectory, backend configuration and state.

Environments compose modules from [`../../modules`](../../modules) and contain no resource logic of their own beyond wiring.
