provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project      = var.project
      environment  = var.environment
      "managed-by" = "terraform"
      owner        = var.owner
    }
  }
}
