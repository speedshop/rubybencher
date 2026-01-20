variable "aws_region" {
  description = "AWS region to deploy to"
  type        = string
  default     = "us-east-1"
}

variable "key_name" {
  description = "SSH key pair name"
  type        = string
}

variable "run_id" {
  description = "Unique identifier for this benchmark run"
  type        = string

  validation {
    condition     = length(trimspace(var.run_id)) > 0
    error_message = "run_id must be set to a non-empty value."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the run VPC"
  type        = string
  default     = "10.1.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block for the run subnet"
  type        = string
  default     = "10.1.1.0/24"
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed to SSH to task runners"
  type        = string
  default     = "0.0.0.0/0"
}

variable "ruby_version" {
  description = "Ruby version to use for benchmarks"
  type        = string
}

variable "instance_types" {
  description = "List of instance type configurations"
  type = list(object({
    instance_type = string
    alias         = string
  }))
}

variable "vcpu_count" {
  description = "Map of instance alias to task runner count (containers per instance)"
  type        = map(number)
}

variable "instance_count" {
  description = "Map of instance alias to number of EC2 instances to create"
  type        = map(number)
}

variable "mock_benchmark" {
  description = "Whether to run mock benchmark instead of real benchmark"
  type        = bool
  default     = false
}

variable "debug_mode" {
  description = "Enable debug mode (keeps task runners alive on failure)"
  type        = bool
  default     = false
}
