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

# Random suffix for unique resource names
resource "random_id" "suffix" {
  byte_length = 4
}

# S3 bucket for benchmark results
resource "aws_s3_bucket" "results" {
  bucket        = "${var.s3_bucket_prefix}-${random_id.suffix.hex}"
  force_destroy = true

  tags = {
    Name        = "RailsBencher Results"
    Environment = "production"
  }
}

resource "aws_s3_bucket_public_access_block" "results" {
  bucket = aws_s3_bucket.results.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_cors_configuration" "results" {
  bucket = aws_s3_bucket.results.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["PUT", "GET"]
    allowed_origins = ["*"]
    max_age_seconds = 3600
  }
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "railsbencher-vpc"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "railsbencher-igw"
  }
}

# Public Subnet
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name = "railsbencher-public"
  }
}

# Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "railsbencher-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Security Group for Bastion Host
resource "aws_security_group" "bastion" {
  name        = "railsbencher-bastion-sg"
  description = "Security group for bastion host"
  vpc_id      = aws_vpc.main.id

  # SSH access from allowed CIDR
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  # All outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "railsbencher-bastion-sg"
  }
}

# EC2 Instance for Bastion Host
resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = "t3.micro"
  key_name               = var.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.bastion.id]

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
  }

  tags = {
    Name = "railsbencher-bastion"
  }

  # Wait for instance to be ready for SSH
  provisioner "remote-exec" {
    inline = ["echo 'Bastion host ready'"]

    connection {
      type        = "ssh"
      user        = "ec2-user"
      private_key = file(var.private_key_path)
      host        = self.public_ip
    }
  }
}

# Security Group for Orchestrator
resource "aws_security_group" "orchestrator" {
  name        = "railsbencher-orchestrator-sg"
  description = "Security group for orchestrator"
  vpc_id      = aws_vpc.main.id

  # HTTP access from anywhere
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH access only from bastion host
  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  # All outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "railsbencher-orchestrator-sg"
  }
}

# Note: We don't use IAM instance profile because the BenchmarkAgent user
# doesn't have IAM permissions. Instead, we pass AWS credentials directly
# to the orchestrator container via environment variables.

# Get latest Amazon Linux 2023 AMI
data "aws_ami" "amazon_linux_2023" {
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

# EC2 Instance for Orchestrator
resource "aws_instance" "orchestrator" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.orchestrator.id]

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  user_data = base64encode(templatefile("${path.module}/user-data.sh", {
    aws_region            = var.aws_region
    s3_bucket             = aws_s3_bucket.results.bucket
    api_key               = var.api_key
    rails_master_key      = var.rails_master_key
    postgres_password     = var.postgres_password
    aws_access_key_id     = var.aws_access_key_id
    aws_secret_access_key = var.aws_secret_access_key
  }))

  tags = {
    Name = "railsbencher-orchestrator"
  }

  # Ensure bastion is ready before provisioning orchestrator
  depends_on = [aws_instance.bastion]

  # Wait for instance to be ready
  provisioner "remote-exec" {
    inline = ["echo 'Waiting for cloud-init to complete...' && cloud-init status --wait"]

    connection {
      type                = "ssh"
      user                = "ec2-user"
      private_key         = file(var.private_key_path)
      host                = self.private_ip
      bastion_host        = aws_instance.bastion.public_ip
      bastion_user        = "ec2-user"
      bastion_private_key = file(var.private_key_path)
    }
  }

  # Copy orchestrator code as tarball (excludes tmp, log, .git)
  provisioner "local-exec" {
    command = "cd ${path.module}/../.. && tar --exclude='orchestrator/tmp' --exclude='orchestrator/log' --exclude='orchestrator/.git' --exclude='orchestrator/node_modules' -czf /tmp/orchestrator.tar.gz orchestrator"
  }

  provisioner "file" {
    source      = "/tmp/orchestrator.tar.gz"
    destination = "/tmp/orchestrator.tar.gz"

    connection {
      type                = "ssh"
      user                = "ec2-user"
      private_key         = file(var.private_key_path)
      host                = self.private_ip
      bastion_host        = aws_instance.bastion.public_ip
      bastion_user        = "ec2-user"
      bastion_private_key = file(var.private_key_path)
    }
  }

  # Build and start the orchestrator
  provisioner "remote-exec" {
    inline = [
      "cd /opt/orchestrator",
      "sudo tar -xzf /tmp/orchestrator.tar.gz",
      "cd /opt/orchestrator/orchestrator && sudo docker build --build-arg PRECOMPILE_ASSETS=true -t orchestrator:latest .",
      "cd /opt/orchestrator && sudo docker-compose up -d",
      "echo 'Waiting for services to start...'",
      "sleep 20",
      "sudo docker-compose ps",
      "sudo docker-compose logs --tail=30"
    ]

    connection {
      type                = "ssh"
      user                = "ec2-user"
      private_key         = file(var.private_key_path)
      host                = self.private_ip
      bastion_host        = aws_instance.bastion.public_ip
      bastion_user        = "ec2-user"
      bastion_private_key = file(var.private_key_path)
    }
  }
}
