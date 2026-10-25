# Partial configuration: bucket and key are supplied at init time.
#   terraform init -backend-config=backend.<environment>.hcl
# See backend.hcl.example and the README for the placeholders.
terraform {
  backend "s3" {
    region       = "eu-north-1"
    encrypt      = true
    use_lockfile = true
  }
}
