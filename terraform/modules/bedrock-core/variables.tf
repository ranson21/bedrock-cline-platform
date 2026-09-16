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
  description = "List of engineers from engineers.yaml."
  type = list(object({
    username             = string
    email                = string
    team                 = string
    models               = optional(list(string))
    monthly_usd_budget   = optional(number)
    monthly_token_budget = optional(number)
  }))
}

variable "defaults" {
  description = "defaults block from engineers.yaml."
  type        = any
}

variable "model_tiers" {
  description = "Tier name -> { model_id, cross_region }."
  type = map(object({
    model_id     = string
    cross_region = bool
  }))
}

variable "log_retention_days" {
  type    = number
  default = 90
}

variable "s3_log_expiration_days" {
  description = "Days to keep raw invocation logs in S3."
  type        = number
  default     = 365
}

variable "enable_guardrail" {
  type    = bool
  default = true
}

variable "guardrail_blocked_input_message" {
  type    = string
  default = "This request was blocked by agency policy."
}
