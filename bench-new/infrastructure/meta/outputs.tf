output "orchestrator_public_ip" {
  description = "Public IP address of the orchestrator"
  value       = aws_instance.orchestrator.public_ip
}

output "orchestrator_private_ip" {
  description = "Private IP address of the orchestrator (for SSH via bastion)"
  value       = aws_instance.orchestrator.private_ip
}

output "aws_region" {
  description = "AWS region where infrastructure is deployed"
  value       = var.aws_region
}

output "key_name" {
  description = "SSH key pair name"
  value       = var.key_name
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

output "bastion_public_ip" {
  description = "Public IP address of the bastion host"
  value       = aws_instance.bastion.public_ip
}

output "bastion_security_group_id" {
  description = "Security group ID of the bastion host (for task runner SG rules)"
  value       = aws_security_group.bastion.id
}

output "bastion_ssh_command" {
  description = "SSH command to connect directly to bastion"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ec2-user@${aws_instance.bastion.public_ip}"
}

output "ssh_helper_scripts" {
  description = "Helper scripts for SSH access (these read IPs from terraform dynamically)"
  value       = <<-EOT
    # SSH to orchestrator:
    ./infrastructure/meta/ssh-orchestrator.fish

    # SSH to task runner (get IPs from 'terraform output' in infrastructure/aws):
    ./infrastructure/meta/ssh-task-runner.fish <bastion_ip> <task_runner_ip>
  EOT
}

output "allowed_ssh_cidr" {
  description = "CIDR block allowed for SSH access"
  value       = var.allowed_ssh_cidr
}
