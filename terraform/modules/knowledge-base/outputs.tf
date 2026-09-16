output "knowledge_base_id" {
  value = aws_bedrockagent_knowledge_base.this.id
}

output "knowledge_base_arn" {
  value = aws_bedrockagent_knowledge_base.this.arn
}

output "data_source_id" {
  value = aws_bedrockagent_data_source.docs.data_source_id
}

output "docs_bucket_name" {
  value = aws_s3_bucket.docs.id
}

output "docs_bucket_arn" {
  value = aws_s3_bucket.docs.arn
}

output "collection_endpoint" {
  value = aws_opensearchserverless_collection.kb.collection_endpoint
}

output "collection_arn" {
  value = aws_opensearchserverless_collection.kb.arn
}

output "dashboard_endpoint" {
  value = aws_opensearchserverless_collection.kb.dashboard_endpoint
}
