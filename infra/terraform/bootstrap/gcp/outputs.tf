output "state_bucket_name" {
  description = "Name of the Terraform state bucket."
  value       = google_storage_bucket.state.name
}

output "state_bucket_url" {
  description = "gs:// URL of the Terraform state bucket."
  value       = google_storage_bucket.state.url
}

output "backend_config" {
  description = "Values to pass to the GCS backend of the GCP environment stacks."
  value = {
    bucket = google_storage_bucket.state.name
  }
}
