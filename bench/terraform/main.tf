terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
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

resource "aws_security_group" "bastion" {
  name        = "ruby-bench-bastion-sg"
  description = "Bastion SSH access"
  vpc_id      = aws_vpc.bench.id

  ingress {
    description = "SSH from allowed CIDRs"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.bastion_allowed_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ruby-bench-bastion-sg"
  }
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
# Public subnet (for NAT)
resource "aws_subnet" "bench_public" {
  vpc_id                  = aws_vpc.bench.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name = "ruby-bench-public"
  }
}

# Private subnet (instances have no public IPs)
resource "aws_subnet" "bench" {
  vpc_id                  = aws_vpc.bench.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = {
    Name = "ruby-bench-private"
  }
}

# Route Tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.bench.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.bench.id
  }

  tags = {
    Name = "ruby-bench-public"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.bench_public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "bench" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.bench_public.id
  depends_on    = [aws_internet_gateway.bench]

  tags = {
    Name = "ruby-bench-nat"
  }
}

resource "aws_route_table" "bench" {
  vpc_id = aws_vpc.bench.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.bench.id
  }

  tags = {
    Name = "ruby-bench-private"
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
    description     = "SSH from bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
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

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.al2023_x86.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.bench_public.id
  associate_public_ip_address = true
  key_name                    = aws_key_pair.bench.key_name
  vpc_security_group_ids      = [aws_security_group.bastion.id]

  tags = {
    Name = "ruby-bench-bastion"
  }
}

# Upload config + skip list (written by orchestrator)
locals {
  skip_types = fileexists("${path.module}/skip_types.json") ? jsondecode(file("${path.module}/skip_types.json")) : []
  normalized_skip_types = [
    for t in local.skip_types : (
      contains(t, ":") ? element(split(":", t), 1) : t
    )
  ]
  upload_config = fileexists("${path.module}/upload_config.json") ? jsondecode(file("${path.module}/upload_config.json")) : {
    instances = {},
    run_id    = "",
    bucket    = "",
    region    = ""
  }
}

# Load instance types from JSON config
locals {
  instance_types_config = jsondecode(file("${path.module}/../instance_types.json"))

  # AWS instance types with AMI mappings
  instance_types = {
    for name, config in local.instance_types_config.aws : name => {
      instance_type = name
      ami           = config.arch == "arm64" ? data.aws_ami.al2023_arm.id : data.aws_ami.al2023_x86.id
      arch          = config.arch
    } if !contains(local.normalized_skip_types, name)
  }

  # Create N replicas of each instance type
  instances = merge([
    for type_name, config in local.instance_types : {
      for i in range(1, var.aws_replicas + 1) : "${type_name}-${i}" => {
        instance_type = config.instance_type
        ami           = config.ami
        arch          = config.arch
        type_name     = type_name
        replica       = i
      }
    }
  ]...)
}

# EC2 Instances
resource "aws_instance" "bench" {
  for_each = local.instances

  ami                    = each.value.ami
  instance_type          = each.value.instance_type
  key_name               = aws_key_pair.bench.key_name
  subnet_id              = aws_subnet.bench.id
  vpc_security_group_ids = [aws_security_group.bench.id]
  user_data = templatefile("${path.module}/userdata-aws.sh.tpl", {
    run_id        = local.upload_config.run_id
    instance_key  = each.key
    instance_type = each.value.type_name
    result_url    = try(local.upload_config.instances[each.key].result_url, "")
    error_url     = try(local.upload_config.instances[each.key].error_url, "")
    heartbeat_url = try(local.upload_config.instances[each.key].heartbeat_url, "")
  })

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
