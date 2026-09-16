# Core Bedrock configuration: invocation logging, KMS, per-engineer application
# inference profiles (tagged for ABAC + cost allocation), and an optional guardrail.

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id
  # Geo prefix for cross-region (system-defined) inference profiles.
  geo_prefix = local.partition == "aws-us-gov" ? "us-gov" : "us"

  default_models = try(var.defaults.models, ["sonnet"])

  # One application inference profile per engineer per tier.
  profile_specs = {
    for pair in flatten([
      for e in var.engineers : [
        for tier in coalesce(e.models, local.default_models) : {
          key      = "${e.username}/${tier}"
          username = e.username
          email    = e.email
          team     = e.team
          tier     = tier
          model    = var.model_tiers[tier]
          # Inference profile names allow [A-Za-z0-9 _-] only; usernames may contain dots or @.
          name = substr(replace(lower("${var.name_prefix}-${e.username}-${tier}"), "/[^a-z0-9_-]/", "-"), 0, 64)
        }
      ]
    ]) : pair.key => pair
  }
}

# ---------- KMS ----------
data "aws_iam_policy_document" "kms" {
  statement {
    sid       = "EnableRoot"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }
  statement {
    sid       = "AllowCloudWatchLogs"
    actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${local.region}.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:*"]
    }
  }
  statement {
    sid       = "AllowBedrockLogging"
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt", "kms:Encrypt", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_kms_key" "logs" {
  description             = "${var.name_prefix} bedrock invocation logs"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms.json
  tags                    = var.tags
}

resource "aws_kms_alias" "logs" {
  name          = "alias/${var.name_prefix}-bedrock-logs"
  target_key_id = aws_kms_key.logs.key_id
}

# ---------- CloudWatch log group ----------
resource "aws_cloudwatch_log_group" "invocations" {
  name              = "/aws/bedrock/${var.name_prefix}/invocations"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.logs.arn
  tags              = var.tags
}

# ---------- S3 bucket for full-payload logs ----------
resource "aws_s3_bucket" "logs" {
  bucket = "${var.name_prefix}-bedrock-logs-${local.account_id}-${local.region}"
  tags   = var.tags
}

resource "aws_s3_bucket_versioning" "logs" {
  bucket = aws_s3_bucket.logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.logs.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = var.s3_log_expiration_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "logs_bucket" {
  statement {
    sid     = "AllowBedrockDelivery"
    actions = ["s3:PutObject"]
    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }
    resources = ["${aws_s3_bucket.logs.arn}/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:bedrock:${local.region}:${local.account_id}:*"]
    }
  }
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    resources = [aws_s3_bucket.logs.arn, "${aws_s3_bucket.logs.arn}/*"]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id
  policy = data.aws_iam_policy_document.logs_bucket.json
}

# ---------- Logging role ----------
data "aws_iam_policy_document" "logging_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:bedrock:${local.region}:${local.account_id}:*"]
    }
  }
}

data "aws_iam_policy_document" "logging" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.invocations.arn}:log-stream:*"]
  }
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/*"]
  }
  statement {
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = [aws_kms_key.logs.arn]
  }
}

resource "aws_iam_role" "logging" {
  name               = "${var.name_prefix}-bedrock-logging"
  assume_role_policy = data.aws_iam_policy_document.logging_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "logging" {
  name   = "logging"
  role   = aws_iam_role.logging.id
  policy = data.aws_iam_policy_document.logging.json
}

resource "aws_bedrock_model_invocation_logging_configuration" "this" {
  depends_on = [aws_iam_role_policy.logging, aws_s3_bucket_policy.logs]

  logging_config {
    embedding_data_delivery_enabled = false
    image_data_delivery_enabled     = false
    text_data_delivery_enabled      = true
    video_data_delivery_enabled     = false

    cloudwatch_config {
      log_group_name = aws_cloudwatch_log_group.invocations.name
      role_arn       = aws_iam_role.logging.arn
      large_data_delivery_s3_config {
        bucket_name = aws_s3_bucket.logs.id
        key_prefix  = "large-payloads/"
      }
    }

    s3_config {
      bucket_name = aws_s3_bucket.logs.id
      key_prefix  = "invocations/"
    }
  }
}

# ---------- Application inference profiles ----------
resource "aws_bedrock_inference_profile" "engineer" {
  for_each = local.profile_specs

  name        = each.value.name
  description = "${each.value.username} / ${each.value.tier} (${each.value.team})"

  model_source {
    copy_from = each.value.model.cross_region ? "arn:${local.partition}:bedrock:${local.region}:${local.account_id}:inference-profile/${local.geo_prefix}.${each.value.model.model_id}" : "arn:${local.partition}:bedrock:${local.region}::foundation-model/${each.value.model.model_id}"
  }

  tags = merge(var.tags, {
    owner        = each.value.username
    team         = each.value.team
    tier         = each.value.tier
    base_model   = each.value.model.model_id
    budget_state = "ok" # managed at runtime by budget-guard; ignored below
  })

  lifecycle {
    ignore_changes = [tags["budget_state"], tags_all["budget_state"]]
  }
}

# ---------- Guardrail (optional) ----------
resource "aws_bedrock_guardrail" "this" {
  count = var.enable_guardrail ? 1 : 0

  name                      = "${var.name_prefix}-engineering"
  description               = "Baseline guardrail for engineering assistants"
  blocked_input_messaging   = var.guardrail_blocked_input_message
  blocked_outputs_messaging = var.guardrail_blocked_input_message
  tags                      = var.tags

  content_policy_config {
    filters_config {
      type            = "HATE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "SEXUAL"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "VIOLENCE"
      input_strength  = "MEDIUM"
      output_strength = "MEDIUM"
    }
    filters_config {
      type            = "PROMPT_ATTACK"
      input_strength  = "MEDIUM"
      output_strength = "NONE"
    }
  }

  sensitive_information_policy_config {
    pii_entities_config {
      action = "ANONYMIZE"
      type   = "US_SOCIAL_SECURITY_NUMBER"
    }
    pii_entities_config {
      action = "ANONYMIZE"
      type   = "AWS_ACCESS_KEY"
    }
    pii_entities_config {
      action = "ANONYMIZE"
      type   = "AWS_SECRET_KEY"
    }
    pii_entities_config {
      action = "ANONYMIZE"
      type   = "PASSWORD"
    }
    pii_entities_config {
      action = "ANONYMIZE"
      type   = "CREDIT_DEBIT_CARD_NUMBER"
    }
  }
}

resource "aws_bedrock_guardrail_version" "this" {
  count         = var.enable_guardrail ? 1 : 0
  guardrail_arn = aws_bedrock_guardrail.this[0].guardrail_arn
  description   = "managed by terraform"
}
