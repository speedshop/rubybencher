variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "availability_zone" {
  description = "Availability zone for instances"
  type        = string
  default     = "us-east-1a"
}

variable "budget_alert_email" {
  description = "Email address for budget alerts (set via TF_VAR_budget_alert_email env var)"
  type        = string
  default     = null
}

variable "budget_limit" {
  description = "Monthly budget limit in USD (set via TF_VAR_budget_limit env var)"
  type        = number
  default     = null
}

variable "replicas" {
  description = "Number of instances per instance type (for reducing variance)"
  type        = number
  default     = 3
}
