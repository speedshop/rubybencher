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

# Fetch meta infrastructure state via data sources
data "terraform_remote_state" "meta" {
  backend = "local"

  config = {
    path = "${path.module}/../meta/terraform.tfstate"
  }
}

locals {
  # Only need orchestrator connection info from meta
  orchestrator_url   = data.terraform_remote_state.meta.outputs.orchestrator_url
  api_key            = data.terraform_remote_state.meta.outputs.api_key
  ecr_repository_url = data.terraform_remote_state.meta.outputs.ecr_repository_url
}

# IAM role for task runner EC2 instances to pull from ECR
resource "aws_iam_role" "task_runner" {
  name = "railsbencher-task-runner-role-${var.run_id}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "railsbencher-task-runner-role-${var.run_id}"
  }
}

# IAM policy for ECR pull access
resource "aws_iam_role_policy" "task_runner_ecr" {
  name = "ecr-pull-policy"
  role = aws_iam_role.task_runner.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      }
    ]
  })
}

# Instance profile for task runner EC2 instances
resource "aws_iam_instance_profile" "task_runner" {
  name = "railsbencher-task-runner-profile-${var.run_id}"
  role = aws_iam_role.task_runner.name
}

# Dedicated VPC for this benchmark run (quarantine per NUKE_SPEC.md)
resource "aws_vpc" "run" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "railsbencher-vpc-${var.run_id}"
  }
}

resource "aws_internet_gateway" "run" {
  vpc_id = aws_vpc.run.id

  tags = {
    Name = "railsbencher-igw-${var.run_id}"
  }
}

resource "aws_subnet" "run" {
  vpc_id                  = aws_vpc.run.id
  cidr_block              = var.subnet_cidr
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name = "railsbencher-subnet-${var.run_id}"
  }
}

resource "aws_route_table" "run" {
  vpc_id = aws_vpc.run.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.run.id
  }

  tags = {
    Name = "railsbencher-rt-${var.run_id}"
  }
}

resource "aws_route_table_association" "run" {
  subnet_id      = aws_subnet.run.id
  route_table_id = aws_route_table.run.id
}

# Security group for task runners
resource "aws_security_group" "task_runner" {
  name        = "railsbencher-task-runner-sg-${var.run_id}"
  description = "Security group for task runners"
  vpc_id      = aws_vpc.run.id

  # SSH access from allowed CIDR (for debugging)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  # All outbound traffic (needed to reach orchestrator and S3)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "railsbencher-task-runner-sg-${var.run_id}"
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

  # Flatten instance configs to create multiple instances per alias
  # e.g., c6g with instance_count=3 becomes c6g-1, c6g-2, c6g-3
  flattened_instances = flatten([
    for config in local.instance_configs : [
      for i in range(var.instance_count[config.alias]) : {
        key           = "${config.alias}-${i + 1}"
        alias         = config.alias
        instance_type = config.instance_type
        index         = i + 1
      }
    ]
  ])

  # Convert to map for for_each
  instance_map = { for inst in local.flattened_instances : inst.key => inst }
}

# Create EC2 instances for each instance type
resource "aws_instance" "task_runner" {
  for_each = local.instance_map

  ami                  = local.instance_arch[each.value.alias] == "arm64" ? data.aws_ami.amazon_linux_arm64.id : data.aws_ami.amazon_linux_x86_64.id
  instance_type        = each.value.instance_type
  key_name             = var.key_name
  subnet_id            = aws_subnet.run.id
  iam_instance_profile = aws_iam_instance_profile.task_runner.name

  vpc_security_group_ids = [aws_security_group.task_runner.id]

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  user_data = base64encode(templatefile("${path.module}/user-data.sh", {
    orchestrator_url  = local.orchestrator_url
    api_key           = local.api_key
    run_id            = var.run_id
    provider_name     = "aws"
    instance_type     = each.value.instance_type
    ruby_version      = var.ruby_version
    task_runner_image = var.task_runner_image
    aws_region        = var.aws_region
    mock_benchmark    = var.mock_benchmark
    debug_mode        = var.debug_mode
    vcpu_count        = var.vcpu_count[each.value.alias]
  }))

  tags = {
    Name         = "railsbencher-task-runner-${each.key}-${var.run_id}"
    InstanceType = each.value.instance_type
    Alias        = each.value.alias
  }

  # Longer timeout for ARM instances which can take longer to provision
  timeouts {
    create = "10m"
    delete = "5m"
  }
}
