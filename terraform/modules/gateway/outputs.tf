output "endpoint" {
  description = "Base URL engineers use as an OpenAI-compatible endpoint (Cline: OpenAI Compatible provider)."
  value       = var.acm_certificate_arn != "" ? "https://${aws_lb.this.dns_name}" : "http://${aws_lb.this.dns_name}:4000"
}

output "master_key_secret_arn" {
  value = aws_secretsmanager_secret.master.arn
}

output "config_parameter_name" {
  value = aws_ssm_parameter.config.name
}
