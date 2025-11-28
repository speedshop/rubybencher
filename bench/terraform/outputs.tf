output "instance_ips" {
  description = "Map of instance type to public IP"
  value = {
    for k, v in aws_instance.bench : k => v.public_ip
  }
}

output "instance_ids" {
  description = "Map of instance type to instance ID"
  value = {
    for k, v in aws_instance.bench : k => v.id
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
