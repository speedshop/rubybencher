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
