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

variable "engineers_group_name" {
  description = "Identity Center group whose members get the engineer permission set."
  type        = string
}

variable "admins_group_name" {
  description = "Identity Center group whose members get the admin permission set."
  type        = string
}

variable "engineers" {
  description = "Engineers list from engineers.yaml; used only when manage_identity_store = true."
  type = list(object({
    username = string
    email    = string
    team     = string
  }))
  default = []
}

variable "manage_identity_store" {
  description = "Create users and groups in the Identity Center store. Only valid when Identity Center is the identity source (no external IdP/SCIM)."
  type        = bool
  default     = false
}

variable "manage_abac_attributes" {
  description = "Set the instance access-control attribute mapping (owner -> userName). Disable if your org already manages this."
  type        = bool
  default     = true
}

variable "session_duration" {
  type    = string
  default = "PT8H"
}

variable "invocation_log_group_arn" {
  type = string
}

variable "logs_bucket_arn" {
  type = string
}

variable "logs_kms_key_arn" {
  type = string
}

variable "knowledge_base_arn" {
  description = "Bedrock Knowledge Base ARN engineers may query. Empty disables the statement."
  type        = string
  default     = ""
}

variable "budget_table_arn" {
  type    = string
  default = ""
}

variable "budget_config_parameter_arn" {
  type    = string
  default = ""
}
