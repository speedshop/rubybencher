output "orchestrator_public_ip" {
  description = "Public IP address of the orchestrator"
  value       = aws_instance.orchestrator.public_ip
}

output "orchestrator_url" {
  description = "URL of the orchestrator"
  value       = "http://${aws_instance.orchestrator.public_ip}"
}

output "s3_bucket_name" {
  description = "Name of the S3 bucket for results"
  value       = aws_s3_bucket.results.bucket
}

output "s3_bucket_arn" {
  description = "ARN of the S3 bucket"
  value       = aws_s3_bucket.results.arn
}

output "api_key" {
  description = "API key for task runner authentication"
  value       = var.api_key
  sensitive   = true
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "Public subnet ID"
  value       = aws_subnet.public.id
}

output "ssh_command" {
  description = "SSH command to connect to orchestrator"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ec2-user@${aws_instance.orchestrator.public_ip}"
}
