output "vpc_id" {
  value = aws_vpc.this.id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "endpoints_security_group_id" {
  value = aws_security_group.endpoints.id
}

output "aoss_vpce_id" {
  value = var.enable_aoss_endpoint ? aws_opensearchserverless_vpc_endpoint.aoss[0].id : ""
}

output "bedrock_runtime_endpoint_dns" {
  description = "Set as the VPC endpoint URL in Cline when engineers are on the VPN."
  value       = try("https://${aws_vpc_endpoint.interface["bedrock-runtime"].dns_entry[0].dns_name}", "")
}

output "client_vpn_endpoint_id" {
  value = var.enable_client_vpn ? aws_ec2_client_vpn_endpoint.this[0].id : ""
}
