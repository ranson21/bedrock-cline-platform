# OPTIONAL. Deploy only if you need PrivateLink endpoints for Bedrock / OpenSearch,
# a Client VPN for engineers, or the gateway module.
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${get_repo_root()}/terraform/modules/network"
}

inputs = {
  vpc_cidr                     = "10.42.0.0/16"
  az_count                     = 2
  enable_nat                   = false # gateway module needs egress to pull images unless you use ECR + endpoints
  enable_client_vpn            = false
  client_vpn_server_cert_arn   = ""
  client_vpn_saml_provider_arn = ""
  interface_endpoints          = ["bedrock-runtime", "bedrock", "bedrock-agent-runtime", "logs", "sts", "kms", "ssm", "secretsmanager", "ecr.api", "ecr.dkr"]
}
