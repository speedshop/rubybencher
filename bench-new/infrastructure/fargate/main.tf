terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      rb_managed = "true"
      rb_run_id  = var.run_id
    }
  }
}

data "terraform_remote_state" "meta" {
  backend = "local"

  config = {
    path = "${path.module}/../meta/terraform.tfstate"
  }
}

locals {
  orchestrator_url = data.terraform_remote_state.meta.outputs.orchestrator_url
  api_key          = data.terraform_remote_state.meta.outputs.api_key
  vpc_id           = data.terraform_remote_state.meta.outputs.vpc_id
  public_subnet_id = data.terraform_remote_state.meta.outputs.public_subnet_id

  instance_configs = {
    for config in var.instance_types : config.alias => config
  }
}

resource "aws_ecs_cluster" "task_runner" {
  name = "rubybencher-fargate-${var.run_id}"
}

resource "aws_cloudwatch_log_group" "task_runner" {
  name              = "/rubybencher/fargate/${var.run_id}"
  retention_in_days = 7
}

resource "aws_iam_role" "task_execution" {
  name = "rubybencher-fargate-exec-${var.run_id}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_security_group" "task_runner" {
  name        = "rubybencher-fargate-sg-${var.run_id}"
  description = "Security group for Fargate task runners"
  vpc_id      = local.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_task_definition" "task_runner" {
  for_each = local.instance_configs

  family                   = "rubybencher-fargate-${each.key}-${var.run_id}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = aws_iam_role.task_execution.arn

  container_definitions = jsonencode([
    {
      name      = "task-runner"
      image     = var.task_runner_image
      essential = true
      command = compact([
        "--orchestrator-url", local.orchestrator_url,
        "--api-key", local.api_key,
        "--run-id", var.run_id,
        "--provider", "fargate",
        "--instance-type", each.value.instance_type,
        var.mock_benchmark ? "--mock" : null,
        var.debug_mode ? "--debug" : null,
        "--no-exit"
      ])
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.task_runner.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "task-runner"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "task_runner" {
  for_each = local.instance_configs

  name            = "rubybencher-fargate-${each.key}-${var.run_id}"
  cluster         = aws_ecs_cluster.task_runner.id
  task_definition = aws_ecs_task_definition.task_runner[each.key].arn
  desired_count   = var.instance_count[each.key]
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [local.public_subnet_id]
    security_groups  = [aws_security_group.task_runner.id]
    assign_public_ip = true
  }

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 200
}
