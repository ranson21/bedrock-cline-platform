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

variable "invocation_log_group_name" {
  type = string
}

variable "enable_analytics_collection" {
  description = "Create an OpenSearch Serverless SEARCH collection that the budget guard indexes usage into."
  type        = bool
  default     = true
}

variable "standby_replicas" {
  type    = string
  default = "DISABLED"
}

variable "analytics_writer_role_arns" {
  description = "Extra principals allowed to write/read the analytics collection (budget-guard role is granted by name pattern)."
  type        = list(string)
  default     = []
}

variable "alarm_email_addresses" {
  type    = list(string)
  default = []
}

variable "throttle_alarm_threshold" {
  description = "InvocationThrottles per 5 minutes that triggers an alarm (raise Bedrock quotas when this fires)."
  type        = number
  default     = 20
}
