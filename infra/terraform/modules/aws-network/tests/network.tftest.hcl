# Plan-only tests using a mocked AWS provider: no credentials or network access required.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["eu-north-1a", "eu-north-1b", "eu-north-1c"]
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "eu-north-1"
    }
  }
}

variables {
  name        = "test"
  environment = "dev"
  vpc_cidr    = "10.10.0.0/16"
}

run "defaults_use_single_nat" {
  command = plan

  assert {
    condition     = length(aws_subnet.public) == 3 && length(aws_subnet.private) == 3
    error_message = "Expected three public and three private subnets."
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 1 && length(aws_eip.nat) == 1
    error_message = "The default nat_mode must create exactly one NAT gateway."
  }

  assert {
    condition     = length(aws_route.private_nat) == 3
    error_message = "Every private route table must have a default route through the NAT gateway."
  }
}

run "subnet_cidrs_are_computed_from_vpc_cidr" {
  command = plan

  assert {
    condition     = aws_subnet.public["eu-north-1a"].cidr_block == "10.10.0.0/24"
    error_message = "First public subnet should be 10.10.0.0/24."
  }

  assert {
    condition     = aws_subnet.private["eu-north-1a"].cidr_block == "10.10.32.0/19" && aws_subnet.private["eu-north-1c"].cidr_block == "10.10.96.0/19"
    error_message = "Private subnets should be /19 blocks starting at 10.10.32.0."
  }
}

run "per_az_nat" {
  command = plan

  variables {
    nat_mode = "per_az"
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 3 && length(aws_eip.nat) == 3
    error_message = "per_az must create one NAT gateway per availability zone."
  }

  assert {
    condition     = length(aws_route.private_nat) == 3
    error_message = "per_az must route every private route table through a NAT gateway."
  }
}

run "no_nat" {
  command = plan

  variables {
    nat_mode = "none"
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 0 && length(aws_eip.nat) == 0
    error_message = "none must not create NAT gateways or addresses."
  }

  assert {
    condition     = length(aws_route.private_nat) == 0
    error_message = "none must not create private default routes."
  }

  assert {
    condition     = length(aws_subnet.public) == 3 && length(aws_subnet.private) == 3
    error_message = "Subnets are created regardless of nat_mode."
  }
}

run "kubernetes_tags_without_cluster_name" {
  command = plan

  assert {
    condition     = aws_subnet.public["eu-north-1a"].tags["kubernetes.io/role/elb"] == "1" && aws_subnet.private["eu-north-1a"].tags["kubernetes.io/role/internal-elb"] == "1"
    error_message = "Subnets must carry the Kubernetes load balancer role tags."
  }

  assert {
    condition     = !contains(keys(aws_subnet.private["eu-north-1a"].tags), "kubernetes.io/cluster/demo")
    error_message = "The cluster tag must be absent when cluster_name is not set."
  }
}

run "kubernetes_cluster_tag" {
  command = plan

  variables {
    cluster_name = "demo"
  }

  assert {
    condition     = aws_subnet.public["eu-north-1b"].tags["kubernetes.io/cluster/demo"] == "shared" && aws_subnet.private["eu-north-1b"].tags["kubernetes.io/cluster/demo"] == "shared"
    error_message = "Subnets must carry the shared cluster tag when cluster_name is set."
  }
}

run "flow_log_retention_default" {
  command = plan

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs.retention_in_days == 14
    error_message = "Flow log retention should default to 14 days."
  }
}

run "rejects_invalid_nat_mode" {
  command = plan

  variables {
    nat_mode = "dual"
  }

  expect_failures = [var.nat_mode]
}

run "rejects_invalid_cidr" {
  command = plan

  variables {
    vpc_cidr = "not-a-cidr"
  }

  expect_failures = [var.vpc_cidr]
}

run "rejects_public_cidr" {
  command = plan

  variables {
    vpc_cidr = "8.8.0.0/16"
  }

  expect_failures = [var.vpc_cidr]
}

run "rejects_cidr_prefix_out_of_range" {
  command = plan

  variables {
    vpc_cidr = "10.10.0.0/24"
  }

  expect_failures = [var.vpc_cidr]
}

run "rejects_unsupported_retention" {
  command = plan

  variables {
    flow_log_retention_days = 10
  }

  expect_failures = [var.flow_log_retention_days]
}

run "rejects_invalid_cluster_name" {
  command = plan

  variables {
    cluster_name = "bad name!"
  }

  expect_failures = [var.cluster_name]
}
