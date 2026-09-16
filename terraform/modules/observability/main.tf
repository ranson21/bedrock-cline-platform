# Dashboards, alarms and an optional OpenSearch analytics collection.

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id
  collection = substr("${var.name_prefix}-usage", 0, 32)
  lg         = var.invocation_log_group_name

  # Logs Insights queries used by the dashboard.
  q_tokens_by_user = <<-EOQ
    fields @timestamp, identity.arn as who, input.inputTokenCount as inp, output.outputTokenCount as out, input.cacheReadInputTokenCount as cr, input.cacheWriteInputTokenCount as cw
    | filter schemaType = "ModelInvocationLog"
    | parse who /\/(?<user>[^\/]+)$/
    | stats sum(inp) as input_tokens, sum(cr) as cache_read, sum(cw) as cache_write, sum(out) as output_tokens, count() as requests by user
    | sort input_tokens desc
  EOQ
  q_cache_rate     = <<-EOQ
    fields identity.arn as who, input.inputTokenCount as inp, input.cacheReadInputTokenCount as cr
    | filter schemaType = "ModelInvocationLog"
    | parse who /\/(?<user>[^\/]+)$/
    | stats sum(cr) / (sum(inp) + sum(cr)) * 100 as cache_hit_pct by user
    | sort cache_hit_pct asc
  EOQ
  q_by_model       = <<-EOQ
    fields modelId, input.inputTokenCount as inp, output.outputTokenCount as out
    | filter schemaType = "ModelInvocationLog"
    | stats sum(inp) as input_tokens, sum(out) as output_tokens, count() as requests by modelId
    | sort requests desc
  EOQ
  q_hourly         = <<-EOQ
    fields input.inputTokenCount as inp, output.outputTokenCount as out, input.cacheReadInputTokenCount as cr
    | filter schemaType = "ModelInvocationLog"
    | stats sum(inp) as input_tokens, sum(cr) as cache_read, sum(out) as output_tokens by bin(1h)
  EOQ
}

resource "aws_cloudwatch_dashboard" "usage" {
  dashboard_name = "${var.name_prefix}-bedrock-usage"
  dashboard_body = jsonencode({
    widgets = [
      {
        type       = "log", x = 0, y = 0, width = 12, height = 8
        properties = { title = "Tokens by engineer (period)", region = local.region, view = "table", query = "SOURCE '${local.lg}' | ${local.q_tokens_by_user}" }
      },
      {
        type       = "log", x = 12, y = 0, width = 12, height = 8
        properties = { title = "Prompt-cache hit rate by engineer (lowest first)", region = local.region, view = "table", query = "SOURCE '${local.lg}' | ${local.q_cache_rate}" }
      },
      {
        type       = "log", x = 0, y = 8, width = 12, height = 8
        properties = { title = "Requests by model / profile", region = local.region, view = "table", query = "SOURCE '${local.lg}' | ${local.q_by_model}" }
      },
      {
        type       = "log", x = 12, y = 8, width = 12, height = 8
        properties = { title = "Hourly token volume", region = local.region, view = "timeSeries", query = "SOURCE '${local.lg}' | ${local.q_hourly}" }
      },
      {
        type = "metric", x = 0, y = 16, width = 12, height = 6
        properties = {
          title  = "Bedrock invocations / throttles / errors"
          region = local.region
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/Bedrock", "Invocations"],
            [".", "InvocationThrottles"],
            [".", "InvocationClientErrors"],
            [".", "InvocationServerErrors"],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 16, width = 12, height = 6
        properties = {
          title   = "Latency p50 / p90"
          region  = local.region
          period  = 300
          metrics = [["AWS/Bedrock", "InvocationLatency", { stat = "p50" }], ["...", { stat = "p90" }]]
        }
      },
    ]
  })
}

# ---------- Alarms ----------
resource "aws_sns_topic" "ops" {
  name = "${var.name_prefix}-ops-alarms"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "ops" {
  for_each  = toset(var.alarm_email_addresses)
  topic_arn = aws_sns_topic.ops.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_cloudwatch_metric_alarm" "throttles" {
  alarm_name          = "${var.name_prefix}-bedrock-throttles"
  alarm_description   = "Bedrock is throttling requests; request a TPM/RPM quota increase (docs/runbooks/raise-quotas.md)"
  namespace           = "AWS/Bedrock"
  metric_name         = "InvocationThrottles"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.throttle_alarm_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.ops.arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "server_errors" {
  alarm_name          = "${var.name_prefix}-bedrock-server-errors"
  namespace           = "AWS/Bedrock"
  metric_name         = "InvocationServerErrors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 3
  threshold           = 10
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.ops.arn]
  tags                = var.tags
}

# ---------- Optional analytics collection ----------
resource "aws_opensearchserverless_security_policy" "enc" {
  count = var.enable_analytics_collection ? 1 : 0
  name  = "${local.collection}-enc"
  type  = "encryption"
  policy = jsonencode({
    Rules       = [{ ResourceType = "collection", Resource = ["collection/${local.collection}"] }]
    AWSOwnedKey = true
  })
}

resource "aws_opensearchserverless_security_policy" "net" {
  count = var.enable_analytics_collection ? 1 : 0
  name  = "${local.collection}-net"
  type  = "network"
  policy = jsonencode([{
    Rules = [
      { ResourceType = "collection", Resource = ["collection/${local.collection}"] },
      { ResourceType = "dashboard", Resource = ["collection/${local.collection}"] },
    ]
    AllowFromPublic = true
  }])
}

resource "aws_opensearchserverless_collection" "usage" {
  count            = var.enable_analytics_collection ? 1 : 0
  name             = local.collection
  type             = "SEARCH"
  standby_replicas = var.standby_replicas
  tags             = var.tags
  depends_on       = [aws_opensearchserverless_security_policy.enc, aws_opensearchserverless_security_policy.net]
}

resource "aws_opensearchserverless_access_policy" "usage" {
  count = var.enable_analytics_collection ? 1 : 0
  name  = "${local.collection}-data"
  type  = "data"
  policy = jsonencode([{
    Rules = [
      {
        ResourceType = "index"
        Resource     = ["index/${local.collection}/*"]
        Permission   = ["aoss:CreateIndex", "aoss:UpdateIndex", "aoss:DescribeIndex", "aoss:ReadDocument", "aoss:WriteDocument"]
      },
      {
        ResourceType = "collection"
        Resource     = ["collection/${local.collection}"]
        Permission   = ["aoss:CreateCollectionItems", "aoss:DescribeCollectionItems", "aoss:UpdateCollectionItems"]
      },
    ]
    Principal = distinct(concat(
      [
        "arn:${local.partition}:iam::${local.account_id}:role/${var.name_prefix}-budget-guard",
        data.aws_caller_identity.current.arn,
      ],
      var.analytics_writer_role_arns,
    ))
  }])
}
