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

variable "run_id" {
  description = "Unique identifier for this benchmark run"
  type        = string
}
