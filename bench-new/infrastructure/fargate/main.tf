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

  container_definitions = jsonencode([
    {
      name      = "task-runner"
      image     = "ruby:${var.ruby_version}"
      essential = true
      environment = var.mock_benchmark ? [
        {
          name  = "MOCK_ALWAYS_SUCCEED"
          value = "1"
        }
      ] : []
      command = concat(
        [
          "bash",
          "-lc",
          join(" ", [
            "set -euo pipefail;",
            "apt-get update;",
            "apt-get install -y --no-install-recommends bash ca-certificates clang git libclang-dev nodejs npm sudo;",
            "rm -rf /var/lib/apt/lists/*;",
            "git clone --depth 1 https://github.com/speedshop/rubybencher.git /rubybencher;",
            "exec /rubybencher/bench-new/task-runner/run.sh \"$@\""
          ]),
          "bash"
        ],
        [
          "--orchestrator-url",
          local.orchestrator_url,
          "--api-key",
          local.api_key,
          "--run-id",
          var.run_id,
          "--provider",
          "fargate",
          "--instance-type",
          each.value.instance_type
        ],
        var.mock_benchmark ? ["--mock"] : [],
        var.debug_mode ? ["--debug"] : [],
        ["--no-exit"]
      )
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
