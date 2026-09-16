# Refuses to plan against the wrong account or region. Terragrunt passes these from
# live/<env>/account.hcl; the provider's allowed_account_ids is the second line of defense.
check "account_context" {
  assert {
    condition     = var.account_id == data.aws_caller_identity.current.account_id && var.region == data.aws_region.current.region
    error_message = "Environment '${var.environment}' expects account ${var.account_id} in ${var.region}, but credentials resolve to ${data.aws_caller_identity.current.account_id} in ${data.aws_region.current.region}."
  }
}
