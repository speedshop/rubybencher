output "task_runner_instances" {
  description = "Map of instance alias to task runner details"
  value = {
    for alias, service in aws_ecs_service.task_runner :
    alias => {
      instance_id   = service.id
      public_ip     = null
      private_ip    = null
      instance_type = local.instance_configs[alias].instance_type
    }
  }
end

output "task_runner_instance_ids" {
  description = "List of all task runner service IDs"
  value       = [for service in aws_ecs_service.task_runner : service.id]
}

output "run_id" {
  description = "Run ID for this deployment"
  value       = var.run_id
}
