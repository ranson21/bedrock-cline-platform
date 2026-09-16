variable "name_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "region" {
  type = string
}

variable "account_id" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "az_count" {
  type    = number
  default = 2
}

variable "enable_nat" {
  description = "NAT gateway for egress from private subnets (needed if the gateway pulls images from outside ECR)."
  type        = bool
  default     = false
}

variable "interface_endpoints" {
  description = "Service short names for interface endpoints."
  type        = list(string)
  default     = ["bedrock-runtime", "bedrock", "bedrock-agent-runtime", "logs", "sts", "kms", "ssm", "secretsmanager", "ecr.api", "ecr.dkr"]
}

variable "enable_aoss_endpoint" {
  description = "OpenSearch Serverless VPC endpoint (pass its id to knowledge-base.vpce_ids)."
  type        = bool
  default     = true
}

variable "enable_client_vpn" {
  type    = bool
  default = false
}

variable "client_vpn_cidr" {
  type    = string
  default = "10.43.0.0/22"
}

variable "client_vpn_server_cert_arn" {
  type    = string
  default = ""
}

variable "client_vpn_saml_provider_arn" {
  description = "IAM SAML provider ARN for federated Client VPN auth. Empty = certificate auth with the server cert as CA."
  type        = string
  default     = ""
}
