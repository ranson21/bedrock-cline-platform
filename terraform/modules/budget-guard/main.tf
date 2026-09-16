# Budget Guard: meters every Bedrock invocation from the invocation log stream,
# tracks per-engineer monthly spend, alerts, enforces caps by tagging the engineer's
# inference profiles, and resets on the first of the month.

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_kms_alias" "sns" {
  name = "alias/aws/sns"
}

locals {
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id

  engineers_by_name = { for e in var.engineers : e.username => e }

  config = {
    generated_at = "managed-by-terraform"
    defaults     = var.defaults
    teams        = var.teams
    prices       = var.prices
    engineers    = local.engineers_by_name
    profiles     = var.profile_index
  }
}

# ---------- State table ----------
resource "aws_dynamodb_table" "this" {
  name         = "${var.name_prefix}-budget-guard"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"
  tags         = var.tags

  attribute {
    name = "PK"
    type = "S"
  }
  attribute {
    name = "SK"
    type = "S"
  }

  # Lets the reporting tool list all users for a month without a full scan.
  global_secondary_index {
    name            = "SK-index"
    hash_key        = "SK"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }
}

# ---------- Config parameter ----------
resource "aws_ssm_parameter" "config" {
  name  = "/${var.name_prefix}/budget-guard/config"
  type  = "String"
  tier  = "Intelligent-Tiering"
  value = jsonencode(local.config)
  tags  = var.tags
}

# ---------- Alerts ----------
resource "aws_sns_topic" "alerts" {
  name              = "${var.name_prefix}-budget-alerts"
  kms_master_key_id = data.aws_kms_alias.sns.target_key_id
  tags              = var.tags
}

resource "aws_sns_topic_subscription" "email" {
  for_each  = toset(var.alert_email_addresses)
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# ---------- Lambda packaging ----------
data "archive_file" "meter" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/usage_meter"
  output_path = "${path.module}/build/usage_meter.zip"
  excludes    = ["__pycache__", "*.pyc"]
}

data "archive_file" "admin" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/monthly_reset"
  output_path = "${path.module}/build/monthly_reset.zip"
  excludes    = ["__pycache__", "*.pyc"]
}

# ---------- IAM ----------
data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "lambda" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${var.name_prefix}-budget-*"]
  }
  statement {
    sid       = "Table"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query", "dynamodb:Scan", "dynamodb:DeleteItem"]
    resources = [aws_dynamodb_table.this.arn, "${aws_dynamodb_table.this.arn}/index/*"]
  }
  statement {
    sid       = "Config"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.config.arn]
  }
  statement {
    sid       = "Publish"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }
  statement {
    sid       = "SnsKms"
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = [data.aws_kms_alias.sns.target_key_arn]
  }
  statement {
    sid       = "TagProfiles"
    actions   = ["bedrock:TagResource", "bedrock:UntagResource", "bedrock:ListTagsForResource", "bedrock:GetInferenceProfile", "bedrock:ListInferenceProfiles"]
    resources = ["arn:${local.partition}:bedrock:${local.region}:${local.account_id}:application-inference-profile/*"]
  }
  dynamic "statement" {
    for_each = var.analytics_collection_arn != "" ? [1] : []
    content {
      sid       = "Analytics"
      actions   = ["aoss:APIAccessAll"]
      resources = [var.analytics_collection_arn]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.name_prefix}-budget-guard"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "lambda" {
  name   = "budget-guard"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

# ---------- Usage meter ----------
resource "aws_cloudwatch_log_group" "meter" {
  name              = "/aws/lambda/${var.name_prefix}-budget-meter"
  retention_in_days = var.lambda_log_retention_days
  tags              = var.tags
}

resource "aws_lambda_function" "meter" {
  function_name    = "${var.name_prefix}-budget-meter"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.meter.output_path
  source_code_hash = data.archive_file.meter.output_base64sha256
  timeout          = 60
  memory_size      = 256
  architectures    = ["arm64"]
  tags             = var.tags

  environment {
    variables = {
      TABLE_NAME         = aws_dynamodb_table.this.name
      CONFIG_PARAM       = aws_ssm_parameter.config.name
      ALERT_TOPIC_ARN    = aws_sns_topic.alerts.arn
      ANALYTICS_ENDPOINT = var.analytics_collection_endpoint
      DEDUPE_TTL_DAYS    = tostring(var.dedupe_ttl_days)
      NAME_PREFIX        = var.name_prefix
    }
  }

  depends_on = [aws_cloudwatch_log_group.meter, aws_iam_role_policy.lambda]
}

resource "aws_lambda_permission" "logs" {
  statement_id   = "AllowCloudWatchLogs"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.meter.function_name
  principal      = "logs.${local.region}.amazonaws.com"
  source_arn     = "${var.invocation_log_group_arn}:*"
  source_account = local.account_id
}

resource "aws_cloudwatch_log_subscription_filter" "meter" {
  name            = "${var.name_prefix}-budget-meter"
  log_group_name  = var.invocation_log_group_name
  filter_pattern  = "{ $.schemaType = \"ModelInvocationLog\" }"
  destination_arn = aws_lambda_function.meter.arn
  depends_on      = [aws_lambda_permission.logs]
}

# ---------- Monthly reset + daily digest ----------
resource "aws_cloudwatch_log_group" "admin" {
  name              = "/aws/lambda/${var.name_prefix}-budget-admin"
  retention_in_days = var.lambda_log_retention_days
  tags              = var.tags
}

resource "aws_lambda_function" "admin" {
  function_name    = "${var.name_prefix}-budget-admin"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.admin.output_path
  source_code_hash = data.archive_file.admin.output_base64sha256
  timeout          = 120
  memory_size      = 256
  architectures    = ["arm64"]
  tags             = var.tags

  environment {
    variables = {
      TABLE_NAME      = aws_dynamodb_table.this.name
      CONFIG_PARAM    = aws_ssm_parameter.config.name
      ALERT_TOPIC_ARN = aws_sns_topic.alerts.arn
      NAME_PREFIX     = var.name_prefix
    }
  }

  depends_on = [aws_cloudwatch_log_group.admin, aws_iam_role_policy.lambda]
}

resource "aws_cloudwatch_event_rule" "monthly_reset" {
  name                = "${var.name_prefix}-budget-monthly-reset"
  description         = "Clear budget_state tags on the 1st of each month"
  schedule_expression = "cron(5 0 1 * ? *)"
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "monthly_reset" {
  rule  = aws_cloudwatch_event_rule.monthly_reset.name
  arn   = aws_lambda_function.admin.arn
  input = jsonencode({ action = "reset" })
}

resource "aws_cloudwatch_event_rule" "daily_digest" {
  name                = "${var.name_prefix}-budget-daily-digest"
  description         = "Daily spend digest to the alerts topic"
  schedule_expression = "cron(0 13 * * ? *)"
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "daily_digest" {
  rule  = aws_cloudwatch_event_rule.daily_digest.name
  arn   = aws_lambda_function.admin.arn
  input = jsonencode({ action = "digest" })
}

resource "aws_lambda_permission" "events_reset" {
  statement_id  = "AllowEventBridgeReset"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.admin.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.monthly_reset.arn
}

resource "aws_lambda_permission" "events_digest" {
  statement_id  = "AllowEventBridgeDigest"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.admin.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_digest.arn
}

# ---------- Team-level AWS Budgets (alerts only) ----------
resource "aws_budgets_budget" "team" {
  for_each = var.enable_team_budgets ? { for k, v in var.teams : k => v if try(v.monthly_usd_budget, null) != null } : {}

  name         = "${var.name_prefix}-team-${each.key}"
  budget_type  = "COST"
  limit_amount = tostring(each.value.monthly_usd_budget)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:team$${each.key}"]
  }

  dynamic "notification" {
    for_each = [50, 80, 100]
    content {
      comparison_operator       = "GREATER_THAN"
      threshold                 = notification.value
      threshold_type            = "PERCENTAGE"
      notification_type         = "ACTUAL"
      subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
    }
  }
}

# Budgets must be allowed to publish to the topic.
data "aws_iam_policy_document" "topic" {
  statement {
    sid     = "AllowBudgets"
    actions = ["sns:Publish"]
    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }
    resources = [aws_sns_topic.alerts.arn]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
  statement {
    sid     = "AllowAccount"
    actions = ["sns:Publish", "sns:Subscribe", "sns:GetTopicAttributes"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
    resources = [aws_sns_topic.alerts.arn]
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.topic.json
}
