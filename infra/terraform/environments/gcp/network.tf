# Network resources are named <project>-<environment>, matching the AWS stack. The module appends the
# environment itself, so it is given the project name only.
module "network" {
  source = "../../modules/gcp-network"

  project_id        = var.project_id
  region            = var.region
  name              = var.project
  environment       = var.environment
  vpc_cidr          = var.vpc_cidr
  nat_mode          = var.nat_mode
  flow_log_sampling = var.flow_log_sampling
}
