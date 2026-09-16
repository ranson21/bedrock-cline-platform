# OPTIONAL. LiteLLM proxy on Fargate. Adds: server-side cache_control injection,
# mandatory guardrails, per-user rate limits, OpenAI-compatible endpoint.
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${get_repo_root()}/terraform/modules/gateway"
}

dependency "network" {
  config_path = "../network"
  mock_outputs = {
    vpc_id                      = "vpc-mock"
    private_subnet_ids          = ["subnet-mock1", "subnet-mock2"]
    endpoints_security_group_id = "sg-mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init"]
}

dependency "bedrock_core" {
  config_path = "../bedrock-core"
  mock_outputs = {
    profile_index     = {}
    guardrail_id      = ""
    guardrail_version = ""
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init"]
}

inputs = {
  vpc_id              = dependency.network.outputs.vpc_id
  private_subnet_ids  = dependency.network.outputs.private_subnet_ids
  profile_index       = dependency.bedrock_core.outputs.profile_index
  model_tiers         = include.root.locals.engineers.model_tiers
  guardrail_id        = dependency.bedrock_core.outputs.guardrail_id
  guardrail_version   = dependency.bedrock_core.outputs.guardrail_version
  image               = ""    # e.g. <acct>.dkr.ecr.<region>.amazonaws.com/litellm:main-stable — mirror it into ECR
  acm_certificate_arn = ""    # internal ALB HTTPS cert
  enable_database     = false # true enables virtual keys + per-key budgets (RDS Postgres)
  desired_count       = 2
}
