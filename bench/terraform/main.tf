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
  key_name   = "ruby-bench"
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
    Name = "ruby-bench-vpc"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "bench" {
  vpc_id = aws_vpc.bench.id

  tags = {
    Name = "ruby-bench-igw"
  }
}

# Public Subnet
resource "aws_subnet" "bench" {
  vpc_id                  = aws_vpc.bench.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name = "ruby-bench-subnet"
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
    Name = "ruby-bench-rt"
  }
}

resource "aws_route_table_association" "bench" {
  subnet_id      = aws_subnet.bench.id
  route_table_id = aws_route_table.bench.id
}

# Security Group
resource "aws_security_group" "bench" {
  name        = "ruby-bench-sg"
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
    Name = "ruby-bench-sg"
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

    # Failsafe: terminate instance after 1 hour no matter what
    echo "sudo shutdown -h now" | at now + 60 minutes

    dnf install -y docker git at
    systemctl enable docker atd
    systemctl start docker atd
    usermod -aG docker ec2-user

    # Re-schedule shutdown after at daemon is running (in case first one failed)
    echo "sudo shutdown -h now" | at now + 60 minutes

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

  # When instance shuts itself down, terminate it (don't just stop)
  instance_initiated_shutdown_behavior = "terminate"

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = {
    Name = "ruby-bench-${each.key}"
  }
}
