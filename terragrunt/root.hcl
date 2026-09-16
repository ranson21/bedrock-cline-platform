# Root Terragrunt configuration. Every unit under live/<env>/ includes this file.
# Account-specific values live only in live/<env>/account.hcl and engineers.yaml.

locals {
  account_file = find_in_parent_folders("account.hcl")
  account      = read_terragrunt_config(local.account_file).locals
  engineers    = yamldecode(file("${dirname(local.account_file)}/engineers.yaml"))

  name_prefix = local.account.name_prefix
  common_tags = merge(
    {
      Project     = "bedrock-cline-platform"
      Environment = local.account.environment
      ManagedBy   = "terragrunt"
    },
    try(local.account.extra_tags, {})
  )
}

remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket         = "${local.name_prefix}-tfstate-${local.account.account_id}-${local.account.region}"
    key            = "${path_relative_to_include()}/terraform.tfstate"
    region         = local.account.region
    encrypt        = true
    dynamodb_table = "${local.name_prefix}-tflock"
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<PROVIDER
provider "aws" {
  region              = "${local.account.region}"
  allowed_account_ids = ["${local.account.account_id}"]
  %{if try(local.account.deploy_role_arn, "") != ""}
  assume_role {
    role_arn     = "${local.account.deploy_role_arn}"
    session_name = "terragrunt-bedrock-cline-platform"
  }
  %{endif}
  default_tags {
    tags = ${jsonencode(local.common_tags)}
  }
}
PROVIDER
}

terraform {
  extra_arguments "common" {
    commands = get_terraform_commands_that_need_vars()
  }
}

inputs = {
  name_prefix = local.name_prefix
  environment = local.account.environment
  region      = local.account.region
  account_id  = local.account.account_id
  tags        = local.common_tags
}
