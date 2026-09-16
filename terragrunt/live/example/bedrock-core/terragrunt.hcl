include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${get_repo_root()}/terraform/modules/bedrock-core"
}

inputs = {
  engineers          = include.root.locals.engineers.engineers
  defaults           = include.root.locals.engineers.defaults
  model_tiers        = include.root.locals.engineers.model_tiers
  log_retention_days = 90
  enable_guardrail   = true
}
