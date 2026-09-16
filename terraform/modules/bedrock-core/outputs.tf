output "invocation_log_group_name" {
  value = aws_cloudwatch_log_group.invocations.name
}

output "invocation_log_group_arn" {
  value = aws_cloudwatch_log_group.invocations.arn
}

output "logs_bucket_arn" {
  value = aws_s3_bucket.logs.arn
}

output "logs_bucket_name" {
  value = aws_s3_bucket.logs.id
}

output "logs_kms_key_arn" {
  value = aws_kms_key.logs.arn
}

output "engineer_profiles" {
  description = "username -> { tier -> application inference profile ARN }"
  value = {
    for u in distinct([for s in local.profile_specs : s.username]) :
    u => { for k, s in local.profile_specs : s.tier => aws_bedrock_inference_profile.engineer[k].arn if s.username == u }
  }
}

output "profile_index" {
  description = "profile ARN -> metadata; consumed by budget-guard, observability and gateway"
  value = {
    for k, s in local.profile_specs :
    aws_bedrock_inference_profile.engineer[k].arn => {
      owner        = s.username
      email        = s.email
      team         = s.team
      tier         = s.tier
      base_model   = s.model.model_id
      cross_region = s.model.cross_region
      name         = s.name
    }
  }
}

output "guardrail_id" {
  value = var.enable_guardrail ? aws_bedrock_guardrail.this[0].guardrail_id : ""
}

output "guardrail_version" {
  value = var.enable_guardrail ? aws_bedrock_guardrail_version.this[0].version : ""
}

output "geo_prefix" {
  value = local.geo_prefix
}
