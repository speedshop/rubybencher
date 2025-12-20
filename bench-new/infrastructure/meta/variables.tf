variable "aws_region" {
  description = "AWS region to deploy to"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type for orchestrator"
  type        = string
  default     = "t3.small"
}

variable "key_name" {
  description = "SSH key pair name"
  type        = string
}

variable "private_key_path" {
  description = "Path to the private key file for SSH access"
  type        = string
}

variable "api_key" {
  description = "API key for task runner authentication"
  type        = string
  sensitive   = true
}

variable "rails_master_key" {
  description = "Rails master key for credentials decryption"
  type        = string
  sensitive   = true
}

variable "postgres_password" {
  description = "Password for PostgreSQL database"
  type        = string
  sensitive   = true
  default     = "orchestrator_prod_secure"
}

variable "s3_bucket_prefix" {
  description = "Prefix for S3 bucket name"
  type        = string
  default     = "railsbencher-results"
}

variable "aws_access_key_id" {
  description = "AWS access key ID for S3 access. Set TF_VAR_aws_access_key_id or pass -var"
  type        = string
  sensitive   = true
}

variable "aws_secret_access_key" {
  description = "AWS secret access key for S3 access. Set TF_VAR_aws_secret_access_key or pass -var"
  type        = string
  sensitive   = true
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed to SSH to the bastion host"
  type        = string
  default     = "0.0.0.0/0"
}
