# Bedrock Knowledge Base backed by an OpenSearch Serverless vector collection.
# Engineers reach it from Cline through tools/mcp-kb-server (bedrock:Retrieve).

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id
  collection = substr("${var.name_prefix}-kb", 0, 32)
  index_name = "bedrock-kb-index"
  # The identity running Terraform must be allowed to create the index.
  deployer_arn = data.aws_caller_identity.current.arn
}

# ---------- KMS ----------
resource "aws_kms_key" "kb" {
  description             = "${var.name_prefix} knowledge base"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = var.tags
}

resource "aws_kms_alias" "kb" {
  name          = "alias/${var.name_prefix}-kb"
  target_key_id = aws_kms_key.kb.key_id
}

# ---------- Docs bucket ----------
resource "aws_s3_bucket" "docs" {
  bucket = "${var.name_prefix}-kb-docs-${local.account_id}-${local.region}"
  tags   = var.tags
}

resource "aws_s3_bucket_versioning" "docs" {
  bucket = aws_s3_bucket.docs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "docs" {
  bucket = aws_s3_bucket.docs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.kb.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "docs" {
  bucket                  = aws_s3_bucket.docs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "docs" {
  bucket = aws_s3_bucket.docs.id
  rule {
    id     = "noncurrent"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = var.docs_expiration_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_notification" "docs" {
  bucket      = aws_s3_bucket.docs.id
  eventbridge = true
}

# ---------- OpenSearch Serverless ----------
resource "aws_opensearchserverless_security_policy" "encryption" {
  name = "${local.collection}-enc"
  type = "encryption"
  policy = jsonencode({
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/${local.collection}"]
    }]
    AWSOwnedKey = false
    KmsARN      = aws_kms_key.kb.arn
  })
}

locals {
  network_rules = [
    { ResourceType = "collection", Resource = ["collection/${local.collection}"] },
    { ResourceType = "dashboard", Resource = ["collection/${local.collection}"] },
  ]
}

resource "aws_opensearchserverless_security_policy" "network" {
  name = "${local.collection}-net"
  type = "network"
  policy = var.collection_public_access ? jsonencode([{
    Rules           = local.network_rules
    AllowFromPublic = true
    }]) : jsonencode([{
    Rules           = local.network_rules
    AllowFromPublic = false
    SourceVPCEs     = var.vpce_ids
  }])
}

resource "aws_opensearchserverless_collection" "kb" {
  name             = local.collection
  type             = "VECTORSEARCH"
  standby_replicas = var.standby_replicas
  tags             = var.tags
  depends_on       = [aws_opensearchserverless_security_policy.encryption, aws_opensearchserverless_security_policy.network]
}

# ---------- KB service role ----------
data "aws_iam_policy_document" "kb_trust" {
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
      values   = ["arn:${local.partition}:bedrock:${local.region}:${local.account_id}:knowledge-base/*"]
    }
  }
}

data "aws_iam_policy_document" "kb" {
  statement {
    sid       = "Embed"
    actions   = ["bedrock:InvokeModel"]
    resources = ["arn:${local.partition}:bedrock:${local.region}::foundation-model/${var.embedding_model_id}"]
  }
  statement {
    sid       = "ReadDocs"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.docs.arn, "${aws_s3_bucket.docs.arn}/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceAccount"
      values   = [local.account_id]
    }
  }
  statement {
    sid       = "Kms"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [aws_kms_key.kb.arn]
  }
  statement {
    sid       = "Aoss"
    actions   = ["aoss:APIAccessAll"]
    resources = [aws_opensearchserverless_collection.kb.arn]
  }
}

resource "aws_iam_role" "kb" {
  name               = "${var.name_prefix}-kb-service"
  assume_role_policy = data.aws_iam_policy_document.kb_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "kb" {
  name   = "kb"
  role   = aws_iam_role.kb.id
  policy = data.aws_iam_policy_document.kb.json
}

resource "aws_opensearchserverless_access_policy" "data" {
  name = "${local.collection}-data"
  type = "data"
  policy = jsonencode([{
    Rules = [
      {
        ResourceType = "index"
        Resource     = ["index/${local.collection}/*"]
        Permission   = ["aoss:CreateIndex", "aoss:DeleteIndex", "aoss:UpdateIndex", "aoss:DescribeIndex", "aoss:ReadDocument", "aoss:WriteDocument"]
      },
      {
        ResourceType = "collection"
        Resource     = ["collection/${local.collection}"]
        Permission   = ["aoss:CreateCollectionItems", "aoss:DescribeCollectionItems", "aoss:UpdateCollectionItems"]
      },
    ]
    Principal = distinct(concat([aws_iam_role.kb.arn, local.deployer_arn], var.additional_reader_role_arns))
  }])
}

# The data access policy takes a little while to propagate before index creation succeeds.
resource "time_sleep" "policy_propagation" {
  depends_on      = [aws_opensearchserverless_access_policy.data, aws_opensearchserverless_collection.kb]
  create_duration = "60s"
}

provider "opensearch" {
  url               = aws_opensearchserverless_collection.kb.collection_endpoint
  aws_region        = local.region
  healthcheck       = false
  sign_aws_requests = true
}

resource "opensearch_index" "kb" {
  name                           = local.index_name
  index_knn                      = true
  index_knn_algo_param_ef_search = "512"
  number_of_shards               = "2"
  number_of_replicas             = "0"
  force_destroy                  = true
  mappings = jsonencode({
    properties = {
      "bedrock-knowledge-base-default-vector" = {
        type      = "knn_vector"
        dimension = var.embedding_dimensions
        method = {
          name       = "hnsw"
          engine     = "faiss"
          space_type = "l2"
          parameters = { ef_construction = 512, m = 16 }
        }
      }
      AMAZON_BEDROCK_TEXT_CHUNK = { type = "text", index = true }
      AMAZON_BEDROCK_METADATA   = { type = "text", index = false }
    }
  })

  depends_on = [time_sleep.policy_propagation]

  lifecycle {
    ignore_changes = [mappings]
  }
}

# ---------- Knowledge base + data source ----------
resource "aws_bedrockagent_knowledge_base" "this" {
  name        = "${var.name_prefix}-engineering-kb"
  description = "Team docs, ADRs, runbooks and code guides for Cline"
  role_arn    = aws_iam_role.kb.arn
  tags        = var.tags

  knowledge_base_configuration {
    type = "VECTOR"
    vector_knowledge_base_configuration {
      embedding_model_arn = "arn:${local.partition}:bedrock:${local.region}::foundation-model/${var.embedding_model_id}"
    }
  }

  storage_configuration {
    type = "OPENSEARCH_SERVERLESS"
    opensearch_serverless_configuration {
      collection_arn    = aws_opensearchserverless_collection.kb.arn
      vector_index_name = local.index_name
      field_mapping {
        vector_field   = "bedrock-knowledge-base-default-vector"
        text_field     = "AMAZON_BEDROCK_TEXT_CHUNK"
        metadata_field = "AMAZON_BEDROCK_METADATA"
      }
    }
  }

  depends_on = [opensearch_index.kb, aws_iam_role_policy.kb]
}

resource "aws_bedrockagent_data_source" "docs" {
  knowledge_base_id    = aws_bedrockagent_knowledge_base.this.id
  name                 = "s3-docs"
  data_deletion_policy = "DELETE"

  data_source_configuration {
    type = "S3"
    s3_configuration {
      bucket_arn = aws_s3_bucket.docs.arn
    }
  }

  server_side_encryption_configuration {
    kms_key_arn = aws_kms_key.kb.arn
  }

  vector_ingestion_configuration {
    chunking_configuration {
      chunking_strategy = "FIXED_SIZE"
      fixed_size_chunking_configuration {
        max_tokens         = var.chunking_max_tokens
        overlap_percentage = var.chunking_overlap_percentage
      }
    }
  }
}

# ---------- Ingestion trigger ----------
data "archive_file" "ingest" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/start_ingestion"
  output_path = "${path.module}/build/start_ingestion.zip"
  excludes    = ["__pycache__", "*.pyc"]
}

data "aws_iam_policy_document" "ingest_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "ingest" {
  statement {
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${var.name_prefix}-kb-ingest:*"]
  }
  statement {
    actions   = ["bedrock:StartIngestionJob", "bedrock:ListIngestionJobs", "bedrock:GetIngestionJob"]
    resources = [aws_bedrockagent_knowledge_base.this.arn]
  }
}

resource "aws_iam_role" "ingest" {
  name               = "${var.name_prefix}-kb-ingest"
  assume_role_policy = data.aws_iam_policy_document.ingest_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "ingest" {
  name   = "ingest"
  role   = aws_iam_role.ingest.id
  policy = data.aws_iam_policy_document.ingest.json
}

resource "aws_cloudwatch_log_group" "ingest" {
  name              = "/aws/lambda/${var.name_prefix}-kb-ingest"
  retention_in_days = 30
  tags              = var.tags
}

resource "aws_lambda_function" "ingest" {
  function_name    = "${var.name_prefix}-kb-ingest"
  role             = aws_iam_role.ingest.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.ingest.output_path
  source_code_hash = data.archive_file.ingest.output_base64sha256
  timeout          = 30
  architectures    = ["arm64"]
  tags             = var.tags

  environment {
    variables = {
      KNOWLEDGE_BASE_ID = aws_bedrockagent_knowledge_base.this.id
      DATA_SOURCE_ID    = aws_bedrockagent_data_source.docs.data_source_id
    }
  }

  depends_on = [aws_cloudwatch_log_group.ingest, aws_iam_role_policy.ingest]
}

resource "aws_cloudwatch_event_rule" "on_upload" {
  name        = "${var.name_prefix}-kb-on-upload"
  description = "Start KB ingestion when docs change"
  tags        = var.tags
  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created", "Object Deleted"]
    detail      = { bucket = { name = [aws_s3_bucket.docs.id] } }
  })
}

resource "aws_cloudwatch_event_rule" "scheduled" {
  name                = "${var.name_prefix}-kb-scheduled"
  schedule_expression = var.ingestion_schedule
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "on_upload" {
  rule = aws_cloudwatch_event_rule.on_upload.name
  arn  = aws_lambda_function.ingest.arn
}

resource "aws_cloudwatch_event_target" "scheduled" {
  rule = aws_cloudwatch_event_rule.scheduled.name
  arn  = aws_lambda_function.ingest.arn
}

resource "aws_lambda_permission" "on_upload" {
  statement_id  = "AllowEventBridgeUpload"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingest.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.on_upload.arn
}

resource "aws_lambda_permission" "scheduled" {
  statement_id  = "AllowEventBridgeSchedule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingest.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.scheduled.arn
}
