variable "name_prefix" {
  description = "Short lowercase prefix used in all resource names."
  type        = string
}

variable "account_id" {
  description = "Target account id; the state bucket name embeds it so it is globally unique."
  type        = string
}

variable "region" {
  description = "Region for the state bucket and lock table."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
