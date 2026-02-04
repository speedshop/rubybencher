variable "aws_region" {
  description = "AWS region to deploy to"
  type        = string
  default     = "us-east-1"
}

variable "run_id" {
  description = "Unique identifier for this benchmark run"
  type        = string

  validation {
    condition     = length(trimspace(var.run_id)) > 0
    error_message = "run_id must be set to a non-empty value."
  }
}

variable "ruby_version" {
  description = "Ruby version to use for benchmarks"
  type        = string
}

variable "task_runner_image" {
  description = "ECR image URL for the task runner"
  type        = string
}

variable "instance_types" {
  description = "List of instance type configurations"
  type = list(object({
    instance_type = string
    alias         = string
  }))
}

variable "instance_count" {
  description = "Map of instance alias to number of tasks to create"
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
