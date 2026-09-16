output "table_name" {
  value = aws_dynamodb_table.this.name
}

output "table_arn" {
  value = aws_dynamodb_table.this.arn
}

output "config_parameter_name" {
  value = aws_ssm_parameter.config.name
}

output "config_parameter_arn" {
  value = aws_ssm_parameter.config.arn
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "meter_function_name" {
  value = aws_lambda_function.meter.function_name
}

output "admin_function_name" {
  value = aws_lambda_function.admin.function_name
}
