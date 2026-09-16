output "dashboard_name" {
  value = aws_cloudwatch_dashboard.usage.dashboard_name
}

output "ops_topic_arn" {
  value = aws_sns_topic.ops.arn
}

output "analytics_collection_endpoint" {
  value = var.enable_analytics_collection ? aws_opensearchserverless_collection.usage[0].collection_endpoint : ""
}

output "analytics_collection_arn" {
  value = var.enable_analytics_collection ? aws_opensearchserverless_collection.usage[0].arn : ""
}

output "analytics_dashboard_endpoint" {
  value = var.enable_analytics_collection ? aws_opensearchserverless_collection.usage[0].dashboard_endpoint : ""
}
