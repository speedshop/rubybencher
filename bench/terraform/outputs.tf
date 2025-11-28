output "instance_ips" {
  description = "Map of instance key to public IP"
  value = {
    for k, v in aws_instance.bench : k => v.public_ip
  }
}

output "instance_ids" {
  description = "Map of instance key to instance ID"
  value = {
    for k, v in aws_instance.bench : k => v.id
  }
}

output "instances_by_type" {
  description = "Instances grouped by type"
  value = {
    for type_name in keys(local.instance_types) : type_name => {
      for k, v in aws_instance.bench : k => v.public_ip
      if local.instances[k].type_name == type_name
    }
  }
}

output "ssh_key_path" {
  description = "Path to the SSH private key"
  value       = local_file.private_key.filename
}

output "ssh_user" {
  description = "SSH username"
  value       = "ec2-user"
}

output "replicas" {
  description = "Number of replicas per instance type"
  value       = var.replicas
}
