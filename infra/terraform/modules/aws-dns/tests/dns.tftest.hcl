# Plan-only tests using a mocked AWS provider: no credentials or network access required.

mock_provider "aws" {}

variables {
  name        = "test"
  environment = "dev"
}

run "disabled_by_default" {
  command = plan

  assert {
    condition     = length(aws_route53_zone.this) == 0 && length(aws_route53_record.delegation) == 0 && length(aws_route53_record.app) == 0 && length(aws_route53_health_check.this) == 0
    error_message = "An empty domain_name must create nothing."
  }

  assert {
    condition     = output.zone_id == null && output.app_fqdn == null && length(output.name_servers) == 0 && length(output.health_check_ids) == 0
    error_message = "Outputs should be empty when no domain is set."
  }
}

run "no_resources_without_domain_even_with_endpoints" {
  command = plan

  variables {
    endpoints = {
      aws = { fqdn = "alb.example.net" }
      gcp = { fqdn = "lb.example.org" }
    }
    delegated_subdomains = { gke = ["ns-cloud-a1.googledomains.com."] }
  }

  assert {
    condition     = length(aws_route53_zone.this) == 0 && length(aws_route53_record.app) == 0 && length(aws_route53_health_check.this) == 0 && length(aws_route53_record.delegation) == 0
    error_message = "Endpoints and delegations must be ignored while domain_name is empty."
  }
}

run "zone_only" {
  command = plan

  variables {
    domain_name = "example.com"
  }

  assert {
    condition     = length(aws_route53_zone.this) == 1 && aws_route53_zone.this[0].name == "example.com"
    error_message = "A hosted zone for the domain is expected."
  }

  assert {
    condition     = length(aws_route53_record.app) == 0 && length(aws_route53_health_check.this) == 0
    error_message = "No records or health checks are expected without endpoints."
  }

  assert {
    condition     = output.app_fqdn == "app.example.com"
    error_message = "app_fqdn should combine app_hostname and domain_name."
  }
}

run "weighted_cname_records" {
  command = plan

  variables {
    domain_name = "example.com"
    endpoints = {
      aws = { fqdn = "alb.eu-north-1.example.net" }
      gcp = { fqdn = "lb.gke.example.com" }
    }
  }

  assert {
    condition     = length(aws_route53_record.app) == 2 && aws_route53_record.app["aws"].type == "CNAME" && aws_route53_record.app["gcp"].type == "CNAME"
    error_message = "fqdn endpoints should create CNAME records."
  }

  assert {
    condition     = aws_route53_record.app["aws"].weighted_routing_policy[0].weight == 50 && aws_route53_record.app["gcp"].weighted_routing_policy[0].weight == 50
    error_message = "Weights should default to 50/50."
  }

  assert {
    condition     = length(aws_route53_record.app["aws"].failover_routing_policy) == 0
    error_message = "The weighted policy must not set a failover policy."
  }

  assert {
    condition     = aws_route53_record.app["aws"].ttl == 60 && aws_route53_record.app["aws"].set_identifier == "aws" && aws_route53_record.app["aws"].name == "app.example.com"
    error_message = "Records should use a 60 second TTL, a set identifier and the app name."
  }
}

run "custom_weights" {
  command = plan

  variables {
    domain_name = "example.com"
    weights     = { aws = 90, gcp = 10 }
    endpoints = {
      aws = { fqdn = "alb.example.net" }
      gcp = { fqdn = "lb.example.org" }
    }
  }

  assert {
    condition     = aws_route53_record.app["aws"].weighted_routing_policy[0].weight == 90 && aws_route53_record.app["gcp"].weighted_routing_policy[0].weight == 10
    error_message = "Custom weights should be applied."
  }
}

run "failover_default_primary_aws" {
  command = plan

  variables {
    domain_name    = "example.com"
    routing_policy = "failover"
    endpoints = {
      aws = { fqdn = "alb.example.net" }
      gcp = { fqdn = "lb.example.org" }
    }
  }

  assert {
    condition     = aws_route53_record.app["aws"].failover_routing_policy[0].type == "PRIMARY" && aws_route53_record.app["gcp"].failover_routing_policy[0].type == "SECONDARY"
    error_message = "aws should be primary and gcp secondary by default."
  }

  assert {
    condition     = length(aws_route53_record.app["aws"].weighted_routing_policy) == 0
    error_message = "The failover policy must not set a weighted policy."
  }
}

run "failover_primary_gcp" {
  command = plan

  variables {
    domain_name    = "example.com"
    routing_policy = "failover"
    primary_cloud  = "gcp"
    endpoints = {
      aws = { fqdn = "alb.example.net" }
      gcp = { fqdn = "lb.example.org" }
    }
  }

  assert {
    condition     = aws_route53_record.app["gcp"].failover_routing_policy[0].type == "PRIMARY" && aws_route53_record.app["aws"].failover_routing_policy[0].type == "SECONDARY"
    error_message = "primary_cloud should select the primary record."
  }
}

run "health_checks_for_fqdn_endpoints" {
  command = plan

  variables {
    domain_name = "example.com"
    endpoints = {
      aws = { fqdn = "alb.example.net" }
      gcp = { fqdn = "lb.example.org", path = "/ready", failure_threshold = 5 }
    }
  }

  assert {
    condition     = length(aws_route53_health_check.this) == 2
    error_message = "One health check per endpoint is expected."
  }

  assert {
    condition     = aws_route53_health_check.this["aws"].type == "HTTPS" && aws_route53_health_check.this["aws"].port == 443 && aws_route53_health_check.this["aws"].resource_path == "/healthz" && aws_route53_health_check.this["aws"].failure_threshold == 3 && aws_route53_health_check.this["aws"].request_interval == 30
    error_message = "Health check defaults should be HTTPS on 443, /healthz, threshold 3, 30 second interval."
  }

  assert {
    condition     = aws_route53_health_check.this["gcp"].resource_path == "/ready" && aws_route53_health_check.this["gcp"].failure_threshold == 5 && aws_route53_health_check.this["gcp"].fqdn == "lb.example.org"
    error_message = "Custom health check settings should be applied."
  }
}

run "ip_endpoints_use_a_records" {
  command = plan

  variables {
    domain_name = "example.com"
    endpoints = {
      aws = { ip = "203.0.113.10" }
      gcp = { ip = "198.51.100.20", protocol = "TCP", port = 8443 }
    }
  }

  assert {
    condition     = aws_route53_record.app["aws"].type == "A" && contains(aws_route53_record.app["aws"].records, "203.0.113.10")
    error_message = "ip endpoints should create A records."
  }

  assert {
    condition     = aws_route53_health_check.this["aws"].ip_address == "203.0.113.10" && aws_route53_health_check.this["aws"].fqdn == "app.example.com"
    error_message = "IP health checks should send the application host name."
  }

  assert {
    condition     = aws_route53_health_check.this["gcp"].type == "TCP" && aws_route53_health_check.this["gcp"].port == 8443 && aws_route53_health_check.this["gcp"].resource_path == null
    error_message = "TCP health checks should not set a path."
  }
}

run "health_checks_disabled" {
  command = plan

  variables {
    domain_name          = "example.com"
    enable_health_checks = false
    endpoints = {
      aws = { fqdn = "alb.example.net" }
      gcp = { fqdn = "lb.example.org" }
    }
  }

  assert {
    condition     = length(aws_route53_health_check.this) == 0 && length(aws_route53_record.app) == 2
    error_message = "Records should be created without health checks when they are disabled."
  }

  assert {
    condition     = aws_route53_record.app["aws"].health_check_id == null
    error_message = "Records must not reference a health check when they are disabled."
  }
}

run "single_endpoint" {
  command = plan

  variables {
    domain_name = "example.com"
    endpoints = {
      aws = { fqdn = "alb.example.net" }
    }
  }

  assert {
    condition     = length(aws_route53_record.app) == 1 && length(aws_route53_health_check.this) == 1
    error_message = "A single endpoint should create one record and one health check."
  }
}

run "custom_ttl_and_hostname" {
  command = plan

  variables {
    domain_name  = "example.com"
    app_hostname = "shop"
    record_ttl   = 30
    endpoints = {
      aws = { fqdn = "alb.example.net" }
    }
  }

  assert {
    condition     = aws_route53_record.app["aws"].name == "shop.example.com" && aws_route53_record.app["aws"].ttl == 30
    error_message = "app_hostname and record_ttl should be applied."
  }
}

run "delegation_records" {
  command = plan

  variables {
    domain_name = "example.com"
    delegated_subdomains = {
      gke = ["ns-cloud-a1.googledomains.com.", "ns-cloud-a2.googledomains.com."]
    }
  }

  assert {
    condition     = length(aws_route53_record.delegation) == 1 && aws_route53_record.delegation["gke"].type == "NS" && aws_route53_record.delegation["gke"].name == "gke.example.com"
    error_message = "An NS record for gke.example.com is expected."
  }

  assert {
    condition     = length(aws_route53_record.delegation["gke"].records) == 2
    error_message = "Both name servers should be in the NS record."
  }
}

run "rejects_uppercase_domain" {
  command = plan

  variables {
    domain_name = "Example.com"
  }

  expect_failures = [var.domain_name]
}

run "rejects_single_label_domain" {
  command = plan

  variables {
    domain_name = "localhost"
  }

  expect_failures = [var.domain_name]
}

run "rejects_trailing_dot_domain" {
  command = plan

  variables {
    domain_name = "example.com."
  }

  expect_failures = [var.domain_name]
}

run "rejects_invalid_routing_policy" {
  command = plan

  variables {
    routing_policy = "latency"
  }

  expect_failures = [var.routing_policy]
}

run "rejects_unknown_endpoint_key" {
  command = plan

  variables {
    endpoints = { azure = { fqdn = "lb.example.org" } }
  }

  expect_failures = [var.endpoints]
}

run "rejects_endpoint_with_fqdn_and_ip" {
  command = plan

  variables {
    endpoints = { aws = { fqdn = "alb.example.net", ip = "203.0.113.10" } }
  }

  expect_failures = [var.endpoints]
}

run "rejects_endpoint_without_target" {
  command = plan

  variables {
    endpoints = { aws = {} }
  }

  expect_failures = [var.endpoints]
}

run "rejects_mixed_endpoint_kinds" {
  command = plan

  variables {
    endpoints = {
      aws = { fqdn = "alb.example.net" }
      gcp = { ip = "198.51.100.20" }
    }
  }

  expect_failures = [var.endpoints]
}

run "rejects_invalid_endpoint_ip" {
  command = plan

  variables {
    endpoints = { aws = { ip = "999.1.1.1" } }
  }

  expect_failures = [var.endpoints]
}

run "rejects_invalid_port" {
  command = plan

  variables {
    endpoints = { aws = { fqdn = "alb.example.net", port = 70000 } }
  }

  expect_failures = [var.endpoints]
}

run "rejects_invalid_protocol" {
  command = plan

  variables {
    endpoints = { aws = { fqdn = "alb.example.net", protocol = "FTP" } }
  }

  expect_failures = [var.endpoints]
}

run "rejects_path_without_slash" {
  command = plan

  variables {
    endpoints = { aws = { fqdn = "alb.example.net", path = "healthz" } }
  }

  expect_failures = [var.endpoints]
}

run "rejects_failure_threshold_too_high" {
  command = plan

  variables {
    endpoints = { aws = { fqdn = "alb.example.net", failure_threshold = 11 } }
  }

  expect_failures = [var.endpoints]
}

run "rejects_failure_threshold_zero" {
  command = plan

  variables {
    endpoints = { aws = { fqdn = "alb.example.net", failure_threshold = 0 } }
  }

  expect_failures = [var.endpoints]
}

run "rejects_invalid_request_interval" {
  command = plan

  variables {
    endpoints = { aws = { fqdn = "alb.example.net", request_interval = 15 } }
  }

  expect_failures = [var.endpoints]
}

run "rejects_invalid_delegated_label" {
  command = plan

  variables {
    delegated_subdomains = { "Bad_Label" = ["ns1.example.net"] }
  }

  expect_failures = [var.delegated_subdomains]
}

run "rejects_empty_name_server_list" {
  command = plan

  variables {
    delegated_subdomains = { gke = [] }
  }

  expect_failures = [var.delegated_subdomains]
}

run "rejects_invalid_name_server" {
  command = plan

  variables {
    delegated_subdomains = { gke = ["not a host"] }
  }

  expect_failures = [var.delegated_subdomains]
}

run "rejects_negative_weight" {
  command = plan

  variables {
    weights = { aws = -1 }
  }

  expect_failures = [var.weights]
}

run "rejects_all_zero_weights" {
  command = plan

  variables {
    weights = { aws = 0, gcp = 0 }
  }

  expect_failures = [var.weights]
}

run "rejects_invalid_primary_cloud" {
  command = plan

  variables {
    primary_cloud = "azure"
  }

  expect_failures = [var.primary_cloud]
}

run "rejects_zero_ttl" {
  command = plan

  variables {
    record_ttl = 0
  }

  expect_failures = [var.record_ttl]
}

run "rejects_invalid_app_hostname" {
  command = plan

  variables {
    app_hostname = "App.Shop"
  }

  expect_failures = [var.app_hostname]
}

run "rejects_invalid_environment" {
  command = plan

  variables {
    environment = "test"
  }

  expect_failures = [var.environment]
}
