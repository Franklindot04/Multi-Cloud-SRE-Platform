# Plan-only tests using a mocked AWS provider: no credentials or network access required.

mock_provider "aws" {}

variables {
  role_name            = "test-dev-external-dns"
  environment          = "dev"
  oidc_provider_arn    = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.eu-north-1.amazonaws.com/id/EXAMPLE0123456789"
  oidc_issuer_host     = "oidc.eks.eu-north-1.amazonaws.com/id/EXAMPLE0123456789"
  namespace            = "external-dns"
  service_account_name = "external-dns"
  policy_json          = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"route53:ListHostedZones\",\"Resource\":\"*\"}]}"
}

run "creates_role_and_inline_policy" {
  command = plan

  assert {
    condition     = aws_iam_role.this.name == "test-dev-external-dns" && aws_iam_role_policy.this.name == "permissions"
    error_message = "A role and an inline policy named permissions are expected."
  }

  assert {
    condition     = aws_iam_role_policy.this.policy == var.policy_json
    error_message = "The inline policy must be the supplied JSON."
  }
}

run "trust_policy_is_scoped_to_one_service_account" {
  command = plan

  assert {
    condition     = jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Action == "sts:AssumeRoleWithWebIdentity"
    error_message = "The role must be assumed with web identity."
  }

  assert {
    condition     = jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Principal.Federated == var.oidc_provider_arn
    error_message = "The trust policy must name the cluster's OIDC provider."
  }

  assert {
    condition     = jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.eu-north-1.amazonaws.com/id/EXAMPLE0123456789:sub"] == "system:serviceaccount:external-dns:external-dns"
    error_message = "The subject must be the namespace and service account, with no wildcard."
  }

  assert {
    condition     = jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.eu-north-1.amazonaws.com/id/EXAMPLE0123456789:aud"] == "sts.amazonaws.com"
    error_message = "The audience must be sts.amazonaws.com."
  }
}

run "outputs" {
  command = plan

  assert {
    condition     = output.service_account_subject == "system:serviceaccount:external-dns:external-dns"
    error_message = "The subject output is wrong."
  }

  assert {
    condition     = contains(keys(output.service_account_annotations), "eks.amazonaws.com/role-arn")
    error_message = "The annotation output must carry the role ARN key."
  }
}

run "tags_are_merged" {
  command = plan

  variables {
    tags = { owner = "platform-team" }
  }

  assert {
    condition     = aws_iam_role.this.tags["owner"] == "platform-team" && aws_iam_role.this.tags["environment"] == "dev" && aws_iam_role.this.tags["managed-by"] == "terraform"
    error_message = "Caller and module tags should both be applied."
  }
}

run "custom_policy_name" {
  command = plan

  variables {
    policy_name = "dns-write"
  }

  assert {
    condition     = aws_iam_role_policy.this.name == "dns-write"
    error_message = "policy_name should be passed through."
  }
}

run "rejects_invalid_role_name" {
  command = plan

  variables {
    role_name = "bad role name!"
  }

  expect_failures = [var.role_name]
}

run "rejects_overlong_role_name" {
  command = plan

  variables {
    role_name = "this-role-name-is-much-too-long-to-be-valid-because-it-exceeds-sixty-four-chars"
  }

  expect_failures = [var.role_name]
}

run "rejects_invalid_oidc_provider_arn" {
  command = plan

  variables {
    oidc_provider_arn = "arn:aws:iam::123456789012:role/not-a-provider"
  }

  expect_failures = [var.oidc_provider_arn]
}

run "rejects_issuer_with_scheme" {
  command = plan

  variables {
    oidc_issuer_host = "https://oidc.eks.eu-north-1.amazonaws.com/id/EXAMPLE0123456789"
  }

  expect_failures = [var.oidc_issuer_host]
}

run "rejects_invalid_namespace" {
  command = plan

  variables {
    namespace = "Bad_Namespace"
  }

  expect_failures = [var.namespace]
}

run "rejects_wildcard_service_account" {
  command = plan

  variables {
    service_account_name = "*"
  }

  expect_failures = [var.service_account_name]
}

run "rejects_invalid_json_policy" {
  command = plan

  variables {
    policy_json = "not json"
  }

  expect_failures = [var.policy_json]
}

run "rejects_policy_without_statement" {
  command = plan

  variables {
    policy_json = "{\"Version\":\"2012-10-17\"}"
  }

  expect_failures = [var.policy_json]
}

run "rejects_invalid_environment" {
  command = plan

  variables {
    environment = "test"
  }

  expect_failures = [var.environment]
}
