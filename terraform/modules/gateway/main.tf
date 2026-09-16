# Optional LiteLLM gateway on ECS Fargate. Adds server-side prompt-cache injection, mandatory
# guardrails, per-key budgets/rate limits (with the database), and an OpenAI-compatible API
# for tools that cannot talk to Bedrock directly. Everything stays inside the VPC.

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id
  port       = 4000

  # One LiteLLM model alias per engineer profile plus one shared alias per tier.
  model_list = concat(
    [
      for arn, meta in var.profile_index : {
        model_name = "${meta.owner}/${meta.tier}"
        litellm_params = merge(
          {
            model           = "bedrock/${arn}"
            aws_region_name = local.region
          },
          var.guardrail_id != "" ? { guardrailConfig = { guardrailIdentifier = var.guardrail_id, guardrailVersion = var.guardrail_version, trace = "disabled" } } : {}
        )
        model_info = { base_model = "bedrock/${meta.base_model}", owner = meta.owner, team = meta.team }
      }
    ],
    [
      for tier, m in var.model_tiers : {
        model_name     = tier
        litellm_params = { model = "bedrock/${m.cross_region ? "${local.partition == "aws-us-gov" ? "us-gov" : "us"}." : ""}${m.model_id}", aws_region_name = local.region }
      }
    ],
  )

  litellm_config = {
    model_list = local.model_list
    litellm_settings = {
      drop_params = true
      # Force prompt caching: inject cache breakpoints on the system prompt and the latest
      # user turn so every client benefits even if it never sets cache_control itself.
      cache_control_injection_points = [
        { location = "message", role = "system" },
        { location = "message", role = "user", index = -1 },
      ]
      success_callback = ["s3"]
    }
    general_settings = {
      master_key = "os.environ/LITELLM_MASTER_KEY"
    }
  }
}

# ---------- Secrets ----------
resource "random_password" "master" {
  length  = 40
  special = false
}

resource "aws_secretsmanager_secret" "master" {
  name                    = "${var.name_prefix}/gateway/master-key"
  recovery_window_in_days = 7
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "master" {
  secret_id     = aws_secretsmanager_secret.master.id
  secret_string = "sk-${random_password.master.result}"
}

resource "aws_ssm_parameter" "config" {
  name  = "/${var.name_prefix}/gateway/config.yaml"
  type  = "String"
  tier  = "Intelligent-Tiering"
  value = yamlencode(local.litellm_config)
  tags  = var.tags
}

# ---------- Optional database ----------
resource "random_password" "db" {
  count   = var.enable_database ? 1 : 0
  length  = 32
  special = false
}

resource "aws_db_subnet_group" "this" {
  count      = var.enable_database ? 1 : 0
  name       = "${var.name_prefix}-gateway"
  subnet_ids = var.private_subnet_ids
  tags       = var.tags
}

resource "aws_security_group" "db" {
  count       = var.enable_database ? 1 : 0
  name        = "${var.name_prefix}-gateway-db"
  description = "Postgres from gateway tasks"
  vpc_id      = var.vpc_id
  tags        = var.tags
  ingress {
    description     = "Postgres from gateway"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.task.id]
  }
  egress {
    description = "none needed"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["127.0.0.1/32"]
  }
}

resource "aws_db_instance" "this" {
  count                     = var.enable_database ? 1 : 0
  identifier                = "${var.name_prefix}-gateway"
  engine                    = "postgres"
  engine_version            = "16"
  instance_class            = "db.t4g.micro"
  allocated_storage         = 20
  storage_encrypted         = true
  db_name                   = "litellm"
  username                  = "litellm"
  password                  = random_password.db[0].result
  db_subnet_group_name      = aws_db_subnet_group.this[0].name
  vpc_security_group_ids    = [aws_security_group.db[0].id]
  multi_az                  = false
  publicly_accessible       = false
  backup_retention_period   = 7
  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name_prefix}-gateway-final"
  tags                      = var.tags
}

resource "aws_secretsmanager_secret" "db_url" {
  count                   = var.enable_database ? 1 : 0
  name                    = "${var.name_prefix}/gateway/database-url"
  recovery_window_in_days = 7
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "db_url" {
  count         = var.enable_database ? 1 : 0
  secret_id     = aws_secretsmanager_secret.db_url[0].id
  secret_string = "postgresql://litellm:${random_password.db[0].result}@${aws_db_instance.this[0].address}:5432/litellm"
}

# ---------- ECS ----------
resource "aws_ecs_cluster" "this" {
  name = "${var.name_prefix}-gateway"
  tags = var.tags
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_cloudwatch_log_group" "task" {
  name              = "/ecs/${var.name_prefix}-gateway"
  retention_in_days = 30
  tags              = var.tags
}

data "aws_iam_policy_document" "ecs_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name_prefix}-gateway-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution_secrets" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = concat([aws_secretsmanager_secret.master.arn], var.enable_database ? [aws_secretsmanager_secret.db_url[0].arn] : [])
  }
  statement {
    actions   = ["ssm:GetParameters", "ssm:GetParameter"]
    resources = [aws_ssm_parameter.config.arn]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

resource "aws_iam_role" "task" {
  name               = "${var.name_prefix}-gateway-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "task" {
  statement {
    sid     = "Invoke"
    actions = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream", "bedrock:Converse", "bedrock:ConverseStream"]
    resources = concat(
      keys(var.profile_index),
      ["arn:${local.partition}:bedrock:*::foundation-model/anthropic.*", "arn:${local.partition}:bedrock:*:${local.account_id}:inference-profile/*"],
    )
  }
  dynamic "statement" {
    for_each = var.guardrail_id != "" ? [1] : []
    content {
      sid       = "Guardrail"
      actions   = ["bedrock:ApplyGuardrail"]
      resources = ["arn:${local.partition}:bedrock:${local.region}:${local.account_id}:guardrail/${var.guardrail_id}"]
    }
  }
  statement {
    sid       = "ConfigAtRuntime"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.config.arn]
  }
}

resource "aws_iam_role_policy" "task" {
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}

resource "aws_security_group" "task" {
  name        = "${var.name_prefix}-gateway-task"
  description = "Gateway tasks"
  vpc_id      = var.vpc_id
  tags        = var.tags
  ingress {
    description     = "From ALB"
    from_port       = local.port
    to_port         = local.port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    description = "To AWS endpoints"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-gateway-alb"
  description = "Internal ALB for the gateway"
  vpc_id      = var.vpc_id
  tags        = var.tags
  ingress {
    description = "HTTPS from allowed ranges"
    from_port   = var.acm_certificate_arn != "" ? 443 : local.port
    to_port     = var.acm_certificate_arn != "" ? 443 : local.port
    protocol    = "tcp"
    cidr_blocks = var.allowed_ingress_cidrs
  }
  egress {
    description = "To tasks"
    from_port   = local.port
    to_port     = local.port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_task_definition" "this" {
  family                   = "${var.name_prefix}-gateway"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  tags                     = var.tags

  runtime_platform {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([{
    name      = "litellm"
    image     = var.image
    essential = true
    # Fetch the config from SSM at start so config changes only need a new deployment.
    entryPoint   = ["/bin/sh", "-c"]
    command      = ["echo \"$LITELLM_CONFIG_YAML\" > /tmp/config.yaml && litellm --config /tmp/config.yaml --port ${local.port} --num_workers 2"]
    portMappings = [{ containerPort = local.port, protocol = "tcp" }]
    environment = [
      { name = "AWS_REGION_NAME", value = local.region },
      { name = "LITELLM_LOG", value = "INFO" },
      { name = "STORE_MODEL_IN_DB", value = var.enable_database ? "True" : "False" },
    ]
    secrets = concat(
      [
        { name = "LITELLM_MASTER_KEY", valueFrom = aws_secretsmanager_secret.master.arn },
        { name = "LITELLM_CONFIG_YAML", valueFrom = aws_ssm_parameter.config.arn },
      ],
      var.enable_database ? [{ name = "DATABASE_URL", valueFrom = aws_secretsmanager_secret.db_url[0].arn }] : [],
    )
    healthCheck = {
      command     = ["CMD-SHELL", "wget -qO- http://localhost:${local.port}/health/liveliness || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.task.name
        awslogs-region        = local.region
        awslogs-stream-prefix = "litellm"
      }
    }
  }])
}

resource "aws_lb" "this" {
  name                       = substr("${var.name_prefix}-gateway", 0, 32)
  internal                   = true
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = var.private_subnet_ids
  drop_invalid_header_fields = true
  tags                       = var.tags
}

resource "aws_lb_target_group" "this" {
  name        = substr("${var.name_prefix}-gateway", 0, 32)
  port        = local.port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id
  tags        = var.tags
  health_check {
    path                = "/health/liveliness"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "https" {
  count             = var.acm_certificate_arn != "" ? 1 : 0
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

resource "aws_lb_listener" "http" {
  count             = var.acm_certificate_arn == "" ? 1 : 0
  load_balancer_arn = aws_lb.this.arn
  port              = local.port
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

resource "aws_ecs_service" "this" {
  name            = "${var.name_prefix}-gateway"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"
  tags            = var.tags

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = "litellm"
    container_port   = local.port
  }

  depends_on = [aws_lb_listener.https, aws_lb_listener.http]
}
