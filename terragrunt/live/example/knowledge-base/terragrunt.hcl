include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${get_repo_root()}/terraform/modules/knowledge-base"
}

inputs = {
  embedding_model_id       = "amazon.titan-embed-text-v2:0"
  embedding_dimensions     = 1024
  standby_replicas         = "DISABLED" # ENABLED doubles OCU cost; use for prod
  collection_public_access = true       # set false and pass vpce_ids when using the network module
  vpce_ids                 = []
  ingestion_schedule       = "rate(1 day)"
  # Principals allowed to query the KB (the engineer permission set role pattern is added automatically by identity)
  additional_reader_role_arns = []
}
