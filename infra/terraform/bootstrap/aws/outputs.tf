output "state_bucket_name" {
  description = "Name of the Terraform state bucket."
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "ARN of the Terraform state bucket."
  value       = aws_s3_bucket.state.arn
}

output "region" {
  description = "Region the state bucket lives in."
  value       = var.region
}

output "backend_config" {
  description = "Values to pass to the S3 backend of the AWS environment stacks."
  value = {
    bucket       = aws_s3_bucket.state.id
    region       = var.region
    use_lockfile = true
    encrypt      = true
  }
}
