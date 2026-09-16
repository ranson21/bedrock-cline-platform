include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${get_repo_root()}/terraform/modules/observability"
}

dependency "bedrock_core" {
  config_path = "../bedrock-core"
  mock_outputs = {
    invocation_log_group_name = "mock"
    profile_index             = {}
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init"]
}

inputs = {
  invocation_log_group_name   = dependency.bedrock_core.outputs.invocation_log_group_name
  profile_index               = dependency.bedrock_core.outputs.profile_index
  enable_analytics_collection = true # OpenSearch Serverless SEARCH collection for usage analytics
  standby_replicas            = "DISABLED"
  alarm_email_addresses       = ["platform-team@agency.example.gov"]
}
