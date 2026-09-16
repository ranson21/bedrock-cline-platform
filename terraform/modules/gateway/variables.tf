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

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "profile_index" {
  description = "profile ARN -> metadata from bedrock-core; every profile becomes a LiteLLM model alias <owner>/<tier>"
  type        = map(any)
}

variable "model_tiers" {
  type = map(object({
    model_id     = string
    cross_region = bool
  }))
}

variable "guardrail_id" {
  type    = string
  default = ""
}

variable "guardrail_version" {
  type    = string
  default = ""
}

variable "image" {
  description = "LiteLLM container image. Mirror ghcr.io/berriai/litellm:main-stable into ECR for GovCloud."
  type        = string
}

variable "acm_certificate_arn" {
  description = "ACM cert for the internal HTTPS listener. Empty = HTTP listener on 4000 (dev only)."
  type        = string
  default     = ""
}

variable "desired_count" {
  type    = number
  default = 2
}

variable "cpu" {
  type    = number
  default = 1024
}

variable "memory" {
  type    = number
  default = 2048
}

variable "enable_database" {
  description = "Provision RDS Postgres so LiteLLM can issue virtual keys with per-key budgets and rate limits."
  type        = bool
  default     = false
}

variable "allowed_ingress_cidrs" {
  description = "CIDRs allowed to reach the gateway (VPN client CIDR, office ranges)."
  type        = list(string)
  default     = ["10.0.0.0/8"]
}
