module "network" {
  source = "../../modules/aws-network"

  name                    = var.project
  environment             = var.environment
  vpc_cidr                = var.vpc_cidr
  nat_mode                = var.nat_mode
  flow_log_retention_days = var.flow_log_retention_days
  cluster_name            = var.cluster_name
}
