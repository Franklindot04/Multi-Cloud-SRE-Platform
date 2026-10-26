output "cluster_name" {
  description = "Name of the GKE cluster."
  value       = google_container_cluster.this.name
}

output "cluster_endpoint" {
  description = "Control plane endpoint (IP address)."
  value       = google_container_cluster.this.endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded public certificate of the cluster's certificate authority."
  value       = one(google_container_cluster.this.master_auth[*].cluster_ca_certificate)
}

output "location" {
  description = "Zone or region of the cluster."
  value       = google_container_cluster.this.location
}

output "workload_pool" {
  description = "Workload Identity pool of the cluster (PROJECT.svc.id.goog)."
  value       = local.workload_pool
}

output "node_service_account_email" {
  description = "Email of the dedicated node service account."
  value       = google_service_account.nodes.email
}

output "kms_key_id" {
  description = "ID of the Cloud KMS key encrypting Kubernetes secrets (null when encryption is disabled)."
  value       = one(google_kms_crypto_key.secrets[*].id)
}

output "get_credentials_command" {
  description = "Command that writes this cluster's credentials into your kubeconfig."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.this.name} --location ${var.location} --project ${var.project_id}"
}
