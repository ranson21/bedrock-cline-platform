include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${get_repo_root()}/terraform/modules/identity"
}

dependency "bedrock_core" {
  config_path = "../bedrock-core"
  mock_outputs = {
    invocation_log_group_arn = "arn:aws:logs:us-east-1:000000000000:log-group:mock:*"
    logs_bucket_arn          = "arn:aws:s3:::mock"
    logs_kms_key_arn         = "arn:aws:kms:us-east-1:000000000000:key/mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init"]
}

dependency "knowledge_base" {
  config_path = "../knowledge-base"
  mock_outputs = {
    knowledge_base_arn = "arn:aws:bedrock:us-east-1:000000000000:knowledge-base/mock"
    docs_bucket_arn    = "arn:aws:s3:::mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init"]
}

dependency "budget_guard" {
  config_path = "../budget-guard"
  mock_outputs = {
    table_arn            = "arn:aws:dynamodb:us-east-1:000000000000:table/mock"
    config_parameter_arn = "arn:aws:ssm:us-east-1:000000000000:parameter/mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init"]
}

inputs = {
  engineers_group_name   = include.root.locals.engineers.groups.engineers
  admins_group_name      = include.root.locals.engineers.groups.admins
  engineers              = include.root.locals.engineers.engineers
  manage_identity_store  = false # true only if Identity Center is its own identity source (no external IdP)
  manage_abac_attributes = true  # false if your org already manages ABAC attributes on the instance
  session_duration       = "PT8H"

  invocation_log_group_arn    = dependency.bedrock_core.outputs.invocation_log_group_arn
  logs_bucket_arn             = dependency.bedrock_core.outputs.logs_bucket_arn
  logs_kms_key_arn            = dependency.bedrock_core.outputs.logs_kms_key_arn
  knowledge_base_arn          = dependency.knowledge_base.outputs.knowledge_base_arn
  budget_table_arn            = dependency.budget_guard.outputs.table_arn
  budget_config_parameter_arn = dependency.budget_guard.outputs.config_parameter_arn
}
