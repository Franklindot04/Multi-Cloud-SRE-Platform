# Partial configuration: bucket and prefix are supplied at init time.
#   terraform init -backend-config=backend.<environment>.hcl
# See backend.hcl.example and the README for the placeholders.
terraform {
  backend "gcs" {}
}
