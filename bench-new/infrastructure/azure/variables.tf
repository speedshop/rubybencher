variable "azure_region" {
  description = "Azure region to deploy to"
  type        = string
  default     = "northcentralus"
}

variable "run_id" {
  description = "Unique identifier for this benchmark run"
  type        = string
}

variable "ruby_version" {
  description = "Ruby version to use for benchmarks"
  type        = string
}

variable "instance_types" {
  description = "List of Azure VM size configurations"
  type = list(object({
    instance_type = string
    alias         = string
    arch          = optional(string, "amd64")
  }))
}

variable "vcpu_count" {
  description = "Map of instance alias to task runner count (containers per instance)"
  type        = map(number)
}

variable "instance_count" {
  description = "Map of instance alias to number of VMs to create"
  type        = map(number)
}

variable "mock_benchmark" {
  description = "Whether to run mock benchmark instead of real benchmark"
  type        = bool
  default     = false
}

variable "debug_mode" {
  description = "Enable debug mode (keeps task runners alive on failure)"
  type        = bool
  default     = false
}

variable "ssh_public_key" {
  description = "SSH public key for VM access"
  type        = string
}

variable "admin_username" {
  description = "Admin username for Azure VMs"
  type        = string
  default     = "azureuser"
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed to SSH to the task runners"
  type        = string
  default     = "0.0.0.0/0"
}
