terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# SSH Key Pair
resource "tls_private_key" "bench" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "bench" {
  key_name   = "ruby-bench-${var.run_id}"
  public_key = tls_private_key.bench.public_key_openssh
}

resource "local_file" "private_key" {
  content         = tls_private_key.bench.private_key_pem
  filename        = "${path.module}/bench-key.pem"
  file_permission = "0600"
}

# VPC
resource "aws_vpc" "bench" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "ruby-bench-vpc-${var.run_id}"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "bench" {
  vpc_id = aws_vpc.bench.id

  tags = {
    Name = "ruby-bench-igw-${var.run_id}"
  }
}

# Public Subnet
resource "aws_subnet" "bench" {
  vpc_id                  = aws_vpc.bench.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name = "ruby-bench-subnet-${var.run_id}"
  }
}

# Route Table
resource "aws_route_table" "bench" {
  vpc_id = aws_vpc.bench.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.bench.id
  }

  tags = {
    Name = "ruby-bench-rt-${var.run_id}"
  }
}

resource "aws_route_table_association" "bench" {
  subnet_id      = aws_subnet.bench.id
  route_table_id = aws_route_table.bench.id
}

# Security Group
resource "aws_security_group" "bench" {
  name        = "ruby-bench-sg-${var.run_id}"
  description = "Security group for Ruby benchmarking"
  vpc_id      = aws_vpc.bench.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ruby-bench-sg-${var.run_id}"
  }
}

# AMI Data Sources - Amazon Linux 2023
data "aws_ami" "al2023_x86" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_ami" "al2023_arm" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# User data script to install Docker
locals {
  user_data = <<-EOF
    #!/bin/bash
    set -e
    dnf install -y docker git
    systemctl enable docker
    systemctl start docker
    usermod -aG docker ec2-user
    # Signal that setup is complete
    touch /home/ec2-user/.setup_complete
  EOF
}

# Instance configurations
locals {
  instances = {
    "c8g.medium" = {
      instance_type = "c8g.medium"
      ami           = data.aws_ami.al2023_arm.id
      arch          = "arm64"
    }
    "c6g.medium" = {
      instance_type = "c6g.medium"
      ami           = data.aws_ami.al2023_arm.id
      arch          = "arm64"
    }
    "m8a.medium" = {
      instance_type = "m8a.medium"
      ami           = data.aws_ami.al2023_x86.id
      arch          = "x86_64"
    }
    "c8i.large" = {
      instance_type = "c8i.large"
      ami           = data.aws_ami.al2023_x86.id
      arch          = "x86_64"
    }
  }
}

# EC2 Instances
resource "aws_instance" "bench" {
  for_each = local.instances

  ami                    = each.value.ami
  instance_type          = each.value.instance_type
  key_name               = aws_key_pair.bench.key_name
  subnet_id              = aws_subnet.bench.id
  vpc_security_group_ids = [aws_security_group.bench.id]
  user_data              = local.user_data

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = {
    Name = "ruby-bench-${each.key}-${var.run_id}"
  }
}
