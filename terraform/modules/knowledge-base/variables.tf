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

variable "embedding_model_id" {
  type    = string
  default = "amazon.titan-embed-text-v2:0"
}

variable "embedding_dimensions" {
  type    = number
  default = 1024
}

variable "standby_replicas" {
  description = "ENABLED (prod, 2x OCU) or DISABLED (dev)."
  type        = string
  default     = "DISABLED"
}

variable "collection_public_access" {
  description = "Allow the collection endpoint from the public AWS network path (still IAM + data-access-policy gated). Set false with vpce_ids for PrivateLink-only."
  type        = bool
  default     = true
}

variable "vpce_ids" {
  description = "OpenSearch Serverless VPC endpoint ids allowed when collection_public_access = false"
  type        = list(string)
  default     = []
}

variable "additional_reader_role_arns" {
  description = "Extra IAM principals granted read access to the collection (e.g. dashboards users)."
  type        = list(string)
  default     = []
}

variable "ingestion_schedule" {
  description = "EventBridge schedule for periodic ingestion (in addition to on-upload)."
  type        = string
  default     = "rate(1 day)"
}

variable "chunking_max_tokens" {
  type    = number
  default = 512
}

variable "chunking_overlap_percentage" {
  type    = number
  default = 15
}

variable "docs_expiration_days" {
  description = "Expire noncurrent doc versions after N days."
  type        = number
  default     = 90
}
