output "task_runner_instances" {
  description = "Map of instance alias to instance details"
  value = {
    for alias, instance in aws_instance.task_runner :
    alias => {
      instance_id  = instance.id
      public_ip    = instance.public_ip
      private_ip   = instance.private_ip
      instance_type = instance.instance_type
    }
  }
}

output "task_runner_instance_ids" {
  description = "List of all task runner instance IDs"
  value       = [for instance in aws_instance.task_runner : instance.id]
}

output "security_group_id" {
  description = "Security group ID for task runners"
  value       = aws_security_group.task_runner.id
}

output "run_id" {
  description = "Run ID for this deployment"
  value       = var.run_id
}
