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
}

# Fetch meta infrastructure state via data sources
data "terraform_remote_state" "meta" {
  backend = "local"

  config = {
    path = "${path.module}/../meta/terraform.tfstate"
  }
}

locals {
  vpc_id               = data.terraform_remote_state.meta.outputs.vpc_id
  subnet_id            = data.terraform_remote_state.meta.outputs.public_subnet_id
  bastion_sg_id        = data.terraform_remote_state.meta.outputs.bastion_security_group_id
  orchestrator_url     = data.terraform_remote_state.meta.outputs.orchestrator_url
  api_key              = data.terraform_remote_state.meta.outputs.api_key
}

# Security group for task runners
resource "aws_security_group" "task_runner" {
  name        = "railsbencher-task-runner-sg-${var.run_id}"
  description = "Security group for task runners"
  vpc_id      = local.vpc_id

  # SSH access from bastion (for debugging)
  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [local.bastion_sg_id]
  }

  # All outbound traffic (needed to reach orchestrator and S3)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name  = "railsbencher-task-runner-sg-${var.run_id}"
    RunId = var.run_id
  }
}

# Get the appropriate AMI based on architecture
# ARM64 for Graviton instances (c8g, c7g, c6g, etc.)
data "aws_ami" "amazon_linux_arm64" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# x86_64 for Intel/AMD instances (c8i, c7i, c6i, c8a, c7a, etc.)
data "aws_ami" "amazon_linux_x86_64" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Parse instance types from JSON variable
locals {
  instance_configs = var.instance_types

  # Determine architecture for each instance type
  # Graviton (arm64): contains 'g' after the generation number (c8g, c7g, c6g, m8g, r8g, etc.)
  # AMD: contains 'a' after the generation number (c8a, c7a, etc.) - uses x86_64
  # Intel: no letter after generation or 'i' (c8i, c7i, c6i, etc.) - uses x86_64
  instance_arch = {
    for config in local.instance_configs :
    config.alias => can(regex("^[a-z]+[0-9]+g", config.instance_type)) ? "arm64" : "x86_64"
  }
}

# Create EC2 instances for each instance type
resource "aws_instance" "task_runner" {
  for_each = { for config in local.instance_configs : config.alias => config }

  ami           = local.instance_arch[each.key] == "arm64" ? data.aws_ami.amazon_linux_arm64.id : data.aws_ami.amazon_linux_x86_64.id
  instance_type = each.value.instance_type
  key_name      = var.key_name
  subnet_id     = local.subnet_id

  vpc_security_group_ids = [aws_security_group.task_runner.id]

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  user_data = base64encode(templatefile("${path.module}/user-data.sh", {
    orchestrator_url = local.orchestrator_url
    api_key          = local.api_key
    run_id           = var.run_id
    provider_name    = "aws"
    instance_type    = each.value.instance_type
    ruby_version     = var.ruby_version
    mock_benchmark   = var.mock_benchmark
    debug_mode       = var.debug_mode
    vcpu_count       = var.vcpu_count[each.key]
  }))

  tags = {
    Name         = "railsbencher-task-runner-${each.key}-${var.run_id}"
    RunId        = var.run_id
    InstanceType = each.value.instance_type
    Alias        = each.key
  }

  # Longer timeout for ARM instances which can take longer to provision
  timeouts {
    create = "10m"
    delete = "5m"
  }
}
