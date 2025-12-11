# Unified provider registry used by the benchmark orchestrator
locals {
  provider_registry = {
    aws = {
      ssh_user     = "ec2-user"
      instance_ips = { for k, v in aws_instance.bench : k => v.private_ip }
      instance_ids = { for k, v in aws_instance.bench : k => v.id }
      instances_by_type = {
        for type_name in keys(local.instance_types) : type_name => {
          for k, v in aws_instance.bench : k => v.public_ip
          if local.instances[k].type_name == type_name
        }
      }
      metadata = {
        region            = var.aws_region
        availability_zone = var.availability_zone
      }
    }
    azure = {
      ssh_user     = "azureuser"
      instance_ips = { for k, v in azurerm_network_interface.bench : k => v.ip_configuration[0].private_ip_address }
      instance_ids = { for k, v in azurerm_linux_virtual_machine.bench : k => v.id }
      instances_by_type = {
        for type_name in keys(local.azure_instance_types) : type_name => {
          for k, nic in azurerm_network_interface.bench : k => nic.ip_configuration[0].private_ip_address
          if local.azure_instances[k].type_name == type_name
        }
      }
      metadata = {
        resource_group = azurerm_resource_group.bench.name
        region         = var.azure_region
        vm_name_prefix = "ruby-bench-"
      }
    }
  }

  all_instances_by_type = merge([
    for provider in values(local.provider_registry) : provider.instances_by_type
  ]...)

  all_instance_ips = merge([
    for provider in values(local.provider_registry) : provider.instance_ips
  ]...)
}

# Provider-scoped outputs (kept for compatibility and clarity)
output "instance_ips" {
  description = "Map of instance key to private IP (AWS)"
  value       = local.provider_registry.aws.instance_ips
}

output "instance_ids" {
  description = "Map of instance key to instance ID (AWS)"
  value       = local.provider_registry.aws.instance_ids
}

output "instances_by_type" {
  description = "Instances grouped by type (AWS)"
  value       = local.provider_registry.aws.instances_by_type
}

output "azure_instance_ips" {
  description = "Map of instance key to private IP (Azure)"
  value       = local.provider_registry.azure.instance_ips
}

output "azure_instance_ids" {
  description = "Map of instance key to VM ID (Azure)"
  value       = local.provider_registry.azure.instance_ids
}

output "azure_instances_by_type" {
  description = "Instances grouped by type (Azure)"
  value       = local.provider_registry.azure.instances_by_type
}

output "azure_resource_group" {
  description = "Azure resource group name"
  value       = azurerm_resource_group.bench.name
}

# Unified outputs
output "providers" {
  description = "Provider registry with instance metadata for each cloud"
  value       = local.provider_registry
}

output "all_instance_ips" {
  description = "Map of all instance keys to public IPs (all providers)"
  value       = local.all_instance_ips
}

output "all_instances_by_type" {
  description = "All instances grouped by type (all providers)"
  value       = local.all_instances_by_type
}

output "ssh_key_path" {
  description = "Path to the SSH private key"
  value       = local_file.private_key.filename
}

output "ssh_user" {
  description = "SSH username by provider"
  value = {
    for name, provider in local.provider_registry : name => provider.ssh_user
  }
}

output "instance_providers" {
  description = "Map of instance key to provider name"
  value = merge([
    for provider_name, provider in local.provider_registry : {
      for inst_key, _ in provider.instance_ips : inst_key => provider_name
    }
  ]...)
}

output "aws_replicas" {
  description = "Number of replicas per AWS instance type"
  value       = var.aws_replicas
}

output "azure_replicas" {
  description = "Number of replicas per Azure instance type"
  value       = var.azure_replicas
}

output "results_bucket" {
  description = "S3 bucket used for result uploads"
  value       = aws_s3_bucket.results.bucket
}

output "aws_bastion_public_ip" {
  description = "Public IP for the AWS bastion host"
  value       = aws_instance.bastion.public_ip
}

output "aws_bastion_private_ip" {
  description = "Private IP for the AWS bastion host"
  value       = aws_instance.bastion.private_ip
}

output "azure_bastion_public_ip" {
  description = "Public IP for the Azure bastion host"
  value       = azurerm_public_ip.bastion.ip_address
}

output "azure_bastion_private_ip" {
  description = "Private IP for the Azure bastion host"
  value       = azurerm_network_interface.bastion.ip_configuration[0].private_ip_address
}

# Instance type configuration outputs
output "configured_instance_types" {
  description = "All configured instance types from config file"
  value       = local.instance_types_config
}

output "aws_instance_type_names" {
  description = "List of AWS instance type names"
  value       = keys(local.instance_types)
}

output "azure_instance_type_names" {
  description = "List of Azure instance type names"
  value       = keys(local.azure_instance_types)
}

output "all_instance_type_names" {
  description = "List of all instance type names across providers"
  value = flatten([
    for provider in values(local.provider_registry) : keys(provider.instances_by_type)
  ])
}
