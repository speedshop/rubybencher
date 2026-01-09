output "task_runner_instances" {
  description = "Map of task runner instances and their IPs"
  value = {
    for key, vm in azurerm_linux_virtual_machine.task_runner :
    key => {
      instance_type = vm.size
      public_ip     = azurerm_public_ip.task_runner[key].ip_address
      private_ip    = azurerm_network_interface.task_runner[key].private_ip_address
    }
  }
}

output "resource_group_name" {
  description = "Resource group name for Azure task runners"
  value       = azurerm_resource_group.main.name
}

output "azure_region" {
  description = "Azure region"
  value       = var.azure_region
}
