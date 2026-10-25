provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = {
    project      = var.project
    environment  = var.environment
    "managed-by" = "terraform"
    owner        = var.owner
  }
}
