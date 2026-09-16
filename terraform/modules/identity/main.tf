# IAM Identity Center permission sets with attribute-based access control.
#
# Engineers may invoke only application inference profiles tagged owner=<their userName>,
# and only while those profiles are not tagged budget_state=exhausted|cache_disabled.
# Bare foundation-model invocation and bearer tokens are denied.

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_ssoadmin_instances" "this" {}

locals {
  partition    = data.aws_partition.current.partition
  account_id   = data.aws_caller_identity.current.account_id
  instance_arn = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  store_id     = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]

  invoke_actions = [
    "bedrock:InvokeModel",
    "bedrock:InvokeModelWithResponseStream",
    "bedrock:Converse",
    "bedrock:ConverseStream",
  ]

  app_profile_arn_pattern = "arn:${local.partition}:bedrock:*:${local.account_id}:application-inference-profile/*"
}

# ---------- ABAC attribute mapping ----------
resource "aws_ssoadmin_instance_access_control_attributes" "this" {
  count        = var.manage_abac_attributes ? 1 : 0
  instance_arn = local.instance_arn

  attribute {
    key = "owner"
    value {
      source = ["$${path:userName}"]
    }
  }
}

# ---------- Groups / users ----------
data "aws_identitystore_group" "engineers" {
  count             = var.manage_identity_store ? 0 : 1
  identity_store_id = local.store_id
  alternate_identifier {
    unique_attribute {
      attribute_path  = "DisplayName"
      attribute_value = var.engineers_group_name
    }
  }
}

data "aws_identitystore_group" "admins" {
  count             = var.manage_identity_store ? 0 : 1
  identity_store_id = local.store_id
  alternate_identifier {
    unique_attribute {
      attribute_path  = "DisplayName"
      attribute_value = var.admins_group_name
    }
  }
}

resource "aws_identitystore_group" "engineers" {
  count             = var.manage_identity_store ? 1 : 0
  identity_store_id = local.store_id
  display_name      = var.engineers_group_name
  description       = "Engineers allowed to use Bedrock through Cline"
}

resource "aws_identitystore_group" "admins" {
  count             = var.manage_identity_store ? 1 : 0
  identity_store_id = local.store_id
  display_name      = var.admins_group_name
  description       = "Platform administrators for bedrock-cline-platform"
}

resource "aws_identitystore_user" "engineer" {
  for_each          = var.manage_identity_store ? { for e in var.engineers : e.username => e } : {}
  identity_store_id = local.store_id
  user_name         = each.value.username
  display_name      = each.value.username
  name {
    given_name  = split(".", each.value.username)[0]
    family_name = length(split(".", each.value.username)) > 1 ? split(".", each.value.username)[1] : each.value.username
  }
  emails {
    value   = each.value.email
    primary = true
  }
}

resource "aws_identitystore_group_membership" "engineer" {
  for_each          = aws_identitystore_user.engineer
  identity_store_id = local.store_id
  group_id          = aws_identitystore_group.engineers[0].group_id
  member_id         = each.value.user_id
}

locals {
  engineers_group_id = var.manage_identity_store ? aws_identitystore_group.engineers[0].group_id : data.aws_identitystore_group.engineers[0].group_id
  admins_group_id    = var.manage_identity_store ? aws_identitystore_group.admins[0].group_id : data.aws_identitystore_group.admins[0].group_id
}

# ---------- Engineer permission set ----------
data "aws_iam_policy_document" "engineer" {
  # Invoke only your own application inference profiles.
  statement {
    sid       = "InvokeOwnProfiles"
    actions   = local.invoke_actions
    resources = [local.app_profile_arn_pattern]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/owner"
      values   = ["$${aws:PrincipalTag/owner}"]
    }
  }

  # The underlying models are needed too, but only when reached through an application profile.
  statement {
    sid     = "InvokeUnderlyingModelsViaProfile"
    actions = local.invoke_actions
    resources = [
      "arn:${local.partition}:bedrock:*::foundation-model/anthropic.*",
      "arn:${local.partition}:bedrock:*:${local.account_id}:inference-profile/*",
    ]
    condition {
      test     = "ArnLike"
      variable = "bedrock:InferenceProfileArn"
      values   = [local.app_profile_arn_pattern]
    }
  }

  # Budget guard: deny when the profile has been marked exhausted or cache-noncompliant.
  statement {
    sid       = "DenyWhenBudgetExhausted"
    effect    = "Deny"
    actions   = local.invoke_actions
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/budget_state"
      values   = ["exhausted", "cache_disabled"]
    }
  }

  # No long-lived bearer tokens.
  statement {
    sid       = "DenyBearerTokens"
    effect    = "Deny"
    actions   = ["bedrock:CallWithBearerToken"]
    resources = ["*"]
  }

  # Discovery calls Cline makes.
  statement {
    sid = "Discover"
    actions = [
      "bedrock:ListFoundationModels",
      "bedrock:GetFoundationModel",
      "bedrock:ListInferenceProfiles",
      "bedrock:GetInferenceProfile",
      "bedrock:ListTagsForResource",
    ]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = var.knowledge_base_arn != "" ? [1] : []
    content {
      sid       = "QueryKnowledgeBase"
      actions   = ["bedrock:Retrieve"]
      resources = [var.knowledge_base_arn]
    }
  }

  statement {
    sid       = "WhoAmI"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_ssoadmin_permission_set" "engineer" {
  name             = "${var.name_prefix}-BedrockEngineer"
  description      = "Invoke own Bedrock inference profiles via Cline"
  instance_arn     = local.instance_arn
  session_duration = var.session_duration
  tags             = var.tags
}

resource "aws_ssoadmin_permission_set_inline_policy" "engineer" {
  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.engineer.arn
  inline_policy      = data.aws_iam_policy_document.engineer.json
}

resource "aws_ssoadmin_account_assignment" "engineer" {
  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.engineer.arn
  principal_id       = local.engineers_group_id
  principal_type     = "GROUP"
  target_id          = local.account_id
  target_type        = "AWS_ACCOUNT"
}

# ---------- Admin permission set ----------
data "aws_iam_policy_document" "admin" {
  statement {
    sid       = "BedrockAdmin"
    actions   = ["bedrock:*"]
    resources = ["*"]
  }
  statement {
    sid       = "DenyBearerTokens"
    effect    = "Deny"
    actions   = ["bedrock:CallWithBearerToken"]
    resources = ["*"]
  }
  statement {
    sid = "ReadInvocationLogs"
    actions = [
      "logs:DescribeLogGroups", "logs:DescribeLogStreams", "logs:GetLogEvents",
      "logs:FilterLogEvents", "logs:StartQuery", "logs:GetQueryResults", "logs:StopQuery",
    ]
    resources = [var.invocation_log_group_arn, "${var.invocation_log_group_arn}:*"]
  }
  statement {
    sid       = "ReadLogBucket"
    actions   = ["s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation"]
    resources = [var.logs_bucket_arn, "${var.logs_bucket_arn}/*"]
  }
  statement {
    sid       = "DecryptLogs"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [var.logs_kms_key_arn]
  }
  dynamic "statement" {
    for_each = var.budget_table_arn != "" ? [1] : []
    content {
      sid       = "BudgetTable"
      actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query", "dynamodb:Scan"]
      resources = [var.budget_table_arn, "${var.budget_table_arn}/index/*"]
    }
  }
  dynamic "statement" {
    for_each = var.budget_config_parameter_arn != "" ? [1] : []
    content {
      sid       = "BudgetConfig"
      actions   = ["ssm:GetParameter"]
      resources = [var.budget_config_parameter_arn]
    }
  }
  statement {
    sid       = "Dashboards"
    actions   = ["cloudwatch:GetDashboard", "cloudwatch:ListDashboards", "cloudwatch:GetMetricData", "cloudwatch:ListMetrics", "aoss:APIAccessAll", "aoss:DashboardsAccessAll", "ce:GetCostAndUsage", "budgets:ViewBudget", "lambda:InvokeFunction", "sns:Publish"]
    resources = ["*"]
  }
}

resource "aws_ssoadmin_permission_set" "admin" {
  name             = "${var.name_prefix}-BedrockAdmin"
  description      = "Operate bedrock-cline-platform"
  instance_arn     = local.instance_arn
  session_duration = "PT4H"
  tags             = var.tags
}

resource "aws_ssoadmin_permission_set_inline_policy" "admin" {
  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.admin.arn
  inline_policy      = data.aws_iam_policy_document.admin.json
}

resource "aws_ssoadmin_managed_policy_attachment" "admin_readonly" {
  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.admin.arn
  managed_policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_ssoadmin_account_assignment" "admin" {
  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.admin.arn
  principal_id       = local.admins_group_id
  principal_type     = "GROUP"
  target_id          = local.account_id
  target_type        = "AWS_ACCOUNT"
}
