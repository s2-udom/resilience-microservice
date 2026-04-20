terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket         = "resilience-tf-state-udom"
    key            = "resilience/terraform.tfstate"
    region         = "eu-west-2"
    encrypt        = true
  }
}

provider "aws" {
  region = "eu-west-2"
}

# Resolve current AWS account ID without hardcoding
data "aws_caller_identity" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  ecr_image    = "${local.account_id}.dkr.ecr.eu-west-2.amazonaws.com/resilience-microservice:latest"
  cluster_name = "resilience-cluster"
  service_name = "resilience-service"

  tags = {
    Project     = "resilience-microservice"
    Author      = "Samuel Udom"
    Module      = "UFCFFF-30-3"
    Environment = "dissertation"
  }
}


# NETWORKING


resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = merge(local.tags, { Name = "resilience-vpc" })
}

# Two public subnets across two AZs.
# Multi-AZ is required to demonstrate meaningful blast radius containment (RQ3):
# a failure in eu-west-2a should not affect traffic served from eu-west-2b.
resource "aws_subnet" "public_1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "eu-west-2a"
  tags                    = merge(local.tags, { Name = "resilience-public-1" })
}

resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "eu-west-2b"
  tags                    = merge(local.tags, { Name = "resilience-public-2" })
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "resilience-igw" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
  tags = merge(local.tags, { Name = "resilience-public-rt" })
}

resource "aws_route_table_association" "public_1" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}


# ECR REPOSITORY


resource "aws_ecr_repository" "resilience_app" {
  name                 = "resilience-microservice"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  tags                 = local.tags
}


# ECS CLUSTER AND SERVICE


resource "aws_ecs_cluster" "main" {
  name = local.cluster_name

  # Enable CloudWatch Container Insights for enhanced metrics
  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = local.tags
}

resource "aws_security_group" "ecs_sg" {
  name   = "resilience-ecs-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS out — required for ECR image pulls and CloudWatch Logs
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name = "resilience-execution-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
  tags = local.tags
}

data "aws_iam_policy" "ecs_task_execution" {
  name = "AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = data.aws_iam_policy.ecs_task_execution.arn
}

# CloudWatch log group for container output
resource "aws_cloudwatch_log_group" "ecs_logs" {
  name              = "/ecs/resilience-service"
  retention_in_days = 7
  tags              = local.tags
}

resource "aws_ecs_task_definition" "app" {
  family                   = "resilience-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([{
    name      = "resilience-app"
    image     = local.ecr_image
    essential = true

    portMappings = [{
      containerPort = 8000
      hostPort      = 8000
    }]

    # Health check — ECS will mark the task unhealthy if /health returns non-200.
    # This feeds the RunningTaskCount metric used by the CloudWatch alarm below.
    healthCheck = {
      command     = ["CMD-SHELL", "curl -f http://localhost:8000/health || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 15
    }

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ecs_logs.name
        "awslogs-region"        = "eu-west-2"
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  tags = local.tags
}

resource "aws_ecs_service" "main" {
  name                               = local.service_name
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.app.arn
  desired_count                      = 1
  launch_type                        = "FARGATE"
  health_check_grace_period_seconds  = 30

  network_configuration {
    subnets          = [aws_subnet.public_1.id, aws_subnet.public_2.id]
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = true
  }

  # Ignore desired_count changes in state — the healer Lambda will modify
  # this during hard reset remediation. Without this, Terraform would
  # revert the healer's scale-down action on the next terraform apply,
  # creating a conflict between IaC state and autonomous remediation.
  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = local.tags
}


# MAPE-K KNOWLEDGE BASE — DynamoDB


resource "aws_dynamodb_table" "healer_knowledge" {
  name         = "resilience-healer-knowledge"
  billing_mode = "PAY_PER_REQUEST"  # no provisioned capacity needed at dissertation scale
  hash_key     = "service_name"

  attribute {
    name = "service_name"
    type = "S"
  }

  tags = local.tags
}


# MAPE-K EXECUTE PHASE — Lambda Healer


# IAM role for the Lambda healer function
resource "aws_iam_role" "lambda_exec" {
  name = "resilience-lambda-exec-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
  tags = local.tags
}

# Custom policy granting healer the minimum permissions required
resource "aws_iam_role_policy" "lambda_healer_policy" {
  name = "resilience-healer-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # ECS permissions — describe and update the target service
        Sid    = "ECSAccess"
        Effect = "Allow"
        Action = [
          "ecs:DescribeServices",
          "ecs:UpdateService",
          "ecs:ListTasks",
          "ecs:DescribeTasks"
        ]
        Resource = "*"
      },
      {
        # CloudWatch Logs — Lambda execution logs
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:eu-west-2:${local.account_id}:*"
      },
      {
        # DynamoDB — read/write remediation history (Knowledge base)
        Sid    = "DynamoDBAccess"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem"
        ]
        Resource = aws_dynamodb_table.healer_knowledge.arn
      },
      {
        # SNS — publish escalation alerts
        Sid      = "SNSPublish"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.healer_alerts.arn
      }
    ]
  })
}

# Package healer.py as a ZIP for Lambda deployment
data "archive_file" "healer_zip" {
  type        = "zip"
  source_file = "${path.module}/healer.py"
  output_path = "${path.module}/healer.zip"
}

resource "aws_lambda_function" "healer" {
  filename         = data.archive_file.healer_zip.output_path
  function_name    = "resilience-healer"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "healer.lambda_handler"
  runtime          = "python3.12"
  timeout          = 60   # hard reset waits 15s for scale-down — needs headroom
  source_code_hash = data.archive_file.healer_zip.output_base64sha256

  environment {
    variables = {
      CLUSTER_NAME  = local.cluster_name
      SERVICE_NAME  = local.service_name
      SNS_TOPIC_ARN = aws_sns_topic.healer_alerts.arn
      HEALER_TABLE  = aws_dynamodb_table.healer_knowledge.name
    }
  }

  tags = local.tags
}

# Allow CloudWatch Alarms to invoke the Lambda
resource "aws_lambda_permission" "cloudwatch_invoke" {
  statement_id  = "AllowCloudWatchAlarmInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.healer.function_name
  principal     = "lambda.alarms.cloudwatch.amazonaws.com"
  source_arn    = aws_cloudwatch_metric_alarm.ecs_task_stopped.arn
}


# MAPE-K MONITOR PHASE — CloudWatch Alarms

# Primary alarm: triggers healer when no ECS tasks are running.
# This is the core signal for the crash failure mode tested in experiments.
resource "aws_cloudwatch_metric_alarm" "ecs_task_stopped" {
  alarm_name          = "resilience-task-stopped"
  alarm_description   = "MAPE-K Monitor: ECS running task count dropped to zero. Triggers autonomous healer."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "RunningTaskCount"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  treat_missing_data  = "breaching"  # missing = task not running = alarm

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.main.name
  }

  # Invoke Lambda directly on alarm state transition
  alarm_actions = [aws_lambda_function.healer.arn]

  tags = local.tags
}

# Secondary alarm: CPU utilisation spike — triggers healer for cpu chaos type.
resource "aws_cloudwatch_metric_alarm" "ecs_cpu_high" {
  alarm_name          = "resilience-cpu-high"
  alarm_description   = "MAPE-K Monitor: ECS task CPU utilisation exceeded 80% for 2 consecutive minutes."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.main.name
  }

  alarm_actions = [aws_lambda_function.healer.arn]
  tags          = local.tags
}

# Tertiary alarm: memory utilisation — triggers healer for memory chaos type.
resource "aws_cloudwatch_metric_alarm" "ecs_memory_high" {
  alarm_name          = "resilience-memory-high"
  alarm_description   = "MAPE-K Monitor: ECS task memory utilisation exceeded 80%."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.main.name
  }

  alarm_actions = [aws_lambda_function.healer.arn]
  tags          = local.tags
}

##############################################################################
# SNS ESCALATION TOPIC
##############################################################################

resource "aws_sns_topic" "healer_alerts" {
  name = "resilience-healer-alerts"
  tags = local.tags
}

# Receive Level 3 escalation notifications
resource "aws_sns_topic_subscription" "healer_email" {
  topic_arn = aws_sns_topic.healer_alerts.arn
  protocol  = "email"
  endpoint  = "samuel2.udom@live.uwe.ac.uk"  
}

##############################################################################
# OUTPUTS
##############################################################################

output "repository_url" {
  description = "ECR repository URL for docker push commands"
  value       = aws_ecr_repository.resilience_app.repository_url
}

output "ecs_cluster_name" {
  description = "ECS cluster name — used in healer Lambda environment variables"
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "ECS service name"
  value       = aws_ecs_service.main.name
}

output "healer_lambda_arn" {
  description = "ARN of the healer Lambda function"
  value       = aws_lambda_function.healer.arn
}

output "dynamodb_table_name" {
  description = "MAPE-K Knowledge base table name"
  value       = aws_dynamodb_table.healer_knowledge.name
}

output "sns_topic_arn" {
  description = "SNS topic ARN for escalation alerts"
  value       = aws_sns_topic.healer_alerts.arn
}

output "cloudwatch_log_group" {
  description = "CloudWatch log group for ECS container logs"
  value       = aws_cloudwatch_log_group.ecs_logs.name
}
