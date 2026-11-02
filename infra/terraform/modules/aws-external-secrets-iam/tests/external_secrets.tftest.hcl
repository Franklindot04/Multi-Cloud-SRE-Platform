# Plan-only tests using a mocked AWS provider: no credentials or network access required.

mock_provider "aws" {
  # The account, region and partition are fixed so that the ARNs can be compared. The account number is a made-up value.
  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "000000000000"
    }
  }

  override_data {
    target = data.aws_region.current
    values = {
      region = "eu-north-1"
    }
  }

  override_data {
    target = data.aws_partition.current
    values = {
      partition = "aws"
    }
  }
}

variables {
  role_name         = "test-dev-external-secrets"
  environment       = "dev"
  oidc_provider_arn = "arn:aws:iam::000000000000:oidc-provider/oidc.eks.eu-north-1.amazonaws.com/id/EXAMPLE0123456789"
  oidc_issuer_host  = "oidc.eks.eu-north-1.amazonaws.com/id/EXAMPLE0123456789"
}

run "trust_policy_names_the_operator_service_account" {
  command = plan

  assert {
    condition     = jsondecode(output.trust_policy_json).Statement[0].Condition.StringEquals["oidc.eks.eu-north-1.amazonaws.com/id/EXAMPLE0123456789:sub"] == "system:serviceaccount:external-secrets:external-secrets"
    error_message = "The subject must be the external-secrets service account in the external-secrets namespace, with no wildcard."
  }

  assert {
    condition     = jsondecode(output.trust_policy_json).Statement[0].Condition.StringEquals["oidc.eks.eu-north-1.amazonaws.com/id/EXAMPLE0123456789:aud"] == "sts.amazonaws.com"
    error_message = "The audience must be sts.amazonaws.com."
  }

  assert {
    condition     = jsondecode(output.trust_policy_json).Statement[0].Action == "sts:AssumeRoleWithWebIdentity" && length(jsondecode(output.trust_policy_json).Statement) == 1
    error_message = "The role must be assumed with web identity, in one statement."
  }

  assert {
    condition     = output.service_account_subject == "system:serviceaccount:external-secrets:external-secrets"
    error_message = "The subject output is wrong."
  }
}

run "the_service_account_can_be_renamed" {
  command = plan

  variables {
    namespace            = "secrets-system"
    service_account_name = "eso"
  }

  assert {
    condition     = jsondecode(output.trust_policy_json).Statement[0].Condition.StringEquals["oidc.eks.eu-north-1.amazonaws.com/id/EXAMPLE0123456789:sub"] == "system:serviceaccount:secrets-system:eso"
    error_message = "The namespace and service account must come from the variables."
  }
}

run "policy_reads_only_below_the_prefix" {
  command = plan

  assert {
    condition     = jsonencode(jsondecode(output.policy_json).Statement[0].Action) == jsonencode(["ssm:GetParameter", "ssm:GetParameters"])
    error_message = "The parameter statement must allow ssm:GetParameter and ssm:GetParameters and nothing else."
  }

  assert {
    condition     = jsonencode(jsondecode(output.policy_json).Statement[0].Resource) == jsonencode(["arn:aws:ssm:eu-north-1:000000000000:parameter/multi-cloud-sre/dev/*"])
    error_message = "The parameters must be limited to /<prefix>/<environment>/*."
  }

  assert {
    condition     = output.parameter_prefix == "/multi-cloud-sre/dev"
    error_message = "The parameter_prefix output must be /<prefix>/<environment>."
  }
}

run "prefix_and_environment_are_variables" {
  command = plan

  variables {
    environment      = "staging"
    parameter_prefix = "shop"
  }

  assert {
    condition     = jsonencode(jsondecode(output.policy_json).Statement[0].Resource) == jsonencode(["arn:aws:ssm:eu-north-1:000000000000:parameter/shop/staging/*"]) && output.parameter_prefix == "/shop/staging"
    error_message = "The path must follow the prefix and environment variables."
  }
}

run "decrypt_is_limited_to_use_through_ssm_in_this_region" {
  command = plan

  assert {
    condition     = jsonencode(jsondecode(output.policy_json).Statement[1].Action) == jsonencode(["kms:Decrypt"])
    error_message = "The only key action is kms:Decrypt."
  }

  assert {
    condition     = jsondecode(output.policy_json).Statement[1].Condition.StringEquals["kms:ViaService"] == "ssm.eu-north-1.amazonaws.com"
    error_message = "Decrypt must be limited to use through SSM in this region."
  }

  assert {
    condition     = jsonencode(jsondecode(output.policy_json).Statement[1].Resource) == jsonencode(["arn:aws:kms:eu-north-1:000000000000:key/*"])
    error_message = "Without a pinned key, the keys of this account and region are the resource."
  }
}

run "decrypt_can_be_pinned_to_one_key" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:eu-north-1:000000000000:key/00000000-0000-0000-0000-000000000000"
  }

  assert {
    condition     = jsonencode(jsondecode(output.policy_json).Statement[1].Resource) == jsonencode(["arn:aws:kms:eu-north-1:000000000000:key/00000000-0000-0000-0000-000000000000"])
    error_message = "A given key ARN must replace the wildcard."
  }
}

run "policy_has_no_write_or_wildcard_actions" {
  command = plan

  assert {
    condition = length(flatten([for s in jsondecode(output.policy_json).Statement : s.Action])) == 3 && alltrue([
      for a in flatten([for s in jsondecode(output.policy_json).Statement : s.Action]) :
      contains(["ssm:GetParameter", "ssm:GetParameters", "kms:Decrypt"], a)
    ])
    error_message = "The policy allows exactly ssm:GetParameter, ssm:GetParameters and kms:Decrypt: no write action and no wildcard."
  }

  assert {
    condition     = alltrue([for s in jsondecode(output.policy_json).Statement : s.Effect == "Allow" && !contains(flatten([s.Resource]), "*")])
    error_message = "Every statement is an Allow, and none has a bare wildcard resource."
  }
}

run "rejects_a_prefix_with_a_slash" {
  command = plan

  variables {
    parameter_prefix = "a/b"
  }

  expect_failures = [var.parameter_prefix]
}

run "rejects_an_upper_case_prefix" {
  command = plan

  variables {
    parameter_prefix = "Shop"
  }

  expect_failures = [var.parameter_prefix]
}

run "rejects_an_unknown_environment" {
  command = plan

  variables {
    environment = "test"
  }

  expect_failures = [var.environment]
}

run "rejects_a_malformed_key_arn" {
  command = plan

  variables {
    kms_key_arn = "alias/aws/ssm"
  }

  expect_failures = [var.kms_key_arn]
}
