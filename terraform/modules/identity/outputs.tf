output "engineer_permission_set_arn" {
  value = aws_ssoadmin_permission_set.engineer.arn
}

output "engineer_permission_set_name" {
  value = aws_ssoadmin_permission_set.engineer.name
}

output "admin_permission_set_arn" {
  value = aws_ssoadmin_permission_set.admin.arn
}

output "sso_start_url_hint" {
  description = "Engineers log in via the Identity Center access portal; find the URL in the Identity Center console."
  value       = "https://<your-identity-center-portal>/start"
}
