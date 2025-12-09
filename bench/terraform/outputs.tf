# AWS Outputs
output "instance_ips" {
  description = "Map of instance key to public IP (AWS)"
  value = {
    for k, v in aws_instance.bench : k => v.public_ip
  }
}

output "instance_ids" {
  description = "Map of instance key to instance ID (AWS)"
  value = {
    for k, v in aws_instance.bench : k => v.id
  }
}

output "instances_by_type" {
  description = "Instances grouped by type (AWS)"
  value = {
    for type_name in keys(local.instance_types) : type_name => {
      for k, v in aws_instance.bench : k => v.public_ip
      if local.instances[k].type_name == type_name
    }
  }
}

# Azure Outputs
output "azure_instance_ips" {
  description = "Map of instance key to public IP (Azure)"
  value = {
    for k, v in azurerm_public_ip.bench : k => v.ip_address
  }
}

output "azure_instance_ids" {
  description = "Map of instance key to VM ID (Azure)"
  value = {
    for k, v in azurerm_linux_virtual_machine.bench : k => v.id
  }
}

output "azure_instances_by_type" {
  description = "Instances grouped by type (Azure)"
  value = {
    for type_name in keys(local.azure_instance_types) : type_name => {
      for k, pip in azurerm_public_ip.bench : k => pip.ip_address
      if local.azure_instances[k].type_name == type_name
    }
  }
}

output "azure_resource_group" {
  description = "Azure resource group name"
  value       = azurerm_resource_group.bench.name
}

# Combined Outputs
output "all_instance_ips" {
  description = "Map of all instance keys to public IPs (both AWS and Azure)"
  value = merge(
    { for k, v in aws_instance.bench : k => v.public_ip },
    { for k, v in azurerm_public_ip.bench : k => v.ip_address }
  )
}

output "all_instances_by_type" {
  description = "All instances grouped by type (both AWS and Azure)"
  value = merge(
    {
      for type_name in keys(local.instance_types) : type_name => {
        for k, v in aws_instance.bench : k => v.public_ip
        if local.instances[k].type_name == type_name
      }
    },
    {
      for type_name in keys(local.azure_instance_types) : type_name => {
        for k, pip in azurerm_public_ip.bench : k => pip.ip_address
        if local.azure_instances[k].type_name == type_name
      }
    }
  )
}

output "ssh_key_path" {
  description = "Path to the SSH private key"
  value       = local_file.private_key.filename
}

output "ssh_user" {
  description = "SSH username (use ec2-user for AWS, azureuser for Azure)"
  value = {
    aws   = "ec2-user"
    azure = "azureuser"
  }
}

output "replicas" {
  description = "Number of replicas per instance type"
  value       = var.replicas
}
