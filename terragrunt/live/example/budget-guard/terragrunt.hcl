include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${get_repo_root()}/terraform/modules/budget-guard"
}

dependency "bedrock_core" {
  config_path = "../bedrock-core"
  mock_outputs = {
    invocation_log_group_name = "mock"
    invocation_log_group_arn  = "arn:aws:logs:us-east-1:000000000000:log-group:mock"
    engineer_profiles         = {}
    profile_index             = {}
    logs_kms_key_arn          = "arn:aws:kms:us-east-1:000000000000:key/mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init"]
}

dependency "observability" {
  config_path  = "../observability"
  skip_outputs = false
  mock_outputs = {
    analytics_collection_endpoint = ""
    analytics_collection_arn      = ""
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init"]
}

inputs = {
  engineers                     = include.root.locals.engineers.engineers
  teams                         = include.root.locals.engineers.teams
  defaults                      = include.root.locals.engineers.defaults
  prices                        = include.root.locals.engineers.prices
  invocation_log_group_name     = dependency.bedrock_core.outputs.invocation_log_group_name
  invocation_log_group_arn      = dependency.bedrock_core.outputs.invocation_log_group_arn
  profile_index                 = dependency.bedrock_core.outputs.profile_index
  analytics_collection_endpoint = dependency.observability.outputs.analytics_collection_endpoint
  analytics_collection_arn      = dependency.observability.outputs.analytics_collection_arn
  alert_email_addresses         = ["platform-team@agency.example.gov"]
}
