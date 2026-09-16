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

variable "engineers" {
  description = "engineers list from engineers.yaml"
  type        = any
}

variable "teams" {
  description = "teams map from engineers.yaml"
  type        = any
  default     = {}
}

variable "defaults" {
  description = "defaults block from engineers.yaml"
  type        = any
}

variable "prices" {
  description = "USD per 1M tokens keyed by model id substring"
  type        = map(map(number))
}

variable "invocation_log_group_name" {
  type = string
}

variable "invocation_log_group_arn" {
  type = string
}

variable "profile_index" {
  description = "profile ARN -> metadata, from bedrock-core"
  type        = map(any)
}

variable "analytics_collection_endpoint" {
  description = "OpenSearch Serverless endpoint for usage analytics; empty disables indexing"
  type        = string
  default     = ""
}

variable "analytics_collection_arn" {
  type    = string
  default = ""
}

variable "alert_email_addresses" {
  type    = list(string)
  default = []
}

variable "enable_team_budgets" {
  description = "Create an AWS Budget per team filtered on the team cost-allocation tag"
  type        = bool
  default     = true
}

variable "lambda_log_retention_days" {
  type    = number
  default = 30
}

variable "dedupe_ttl_days" {
  type    = number
  default = 3
}
