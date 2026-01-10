terraform {
  required_version = ">= 1.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# Fetch meta infrastructure state via data sources
data "terraform_remote_state" "meta" {
  backend = "local"

  config = {
    path = "${path.module}/../meta/terraform.tfstate"
  }
}

locals {
  orchestrator_url = data.terraform_remote_state.meta.outputs.orchestrator_url
  api_key          = data.terraform_remote_state.meta.outputs.api_key

  # Common tags for all resources (per NUKE_SPEC.md)
  common_tags = {
    rb_managed = "true"
    rb_run_id  = var.run_id
  }
}

locals {
  instance_configs = var.instance_types

  # Flatten instance configs to create multiple VMs per alias
  flattened_instances = flatten([
    for config in local.instance_configs : [
      for i in range(var.instance_count[config.alias]) : {
        key           = "${config.alias}-${i + 1}"
        alias         = config.alias
        instance_type = config.instance_type
        index         = i + 1
      }
    ]
  ])

  # Convert to map for for_each
  instance_map = { for inst in local.flattened_instances : inst.key => inst }
}

resource "azurerm_resource_group" "main" {
  name     = "railsbencher-${var.run_id}"
  location = var.azure_region
  tags     = local.common_tags
}

resource "azurerm_virtual_network" "main" {
  name                = "railsbencher-vnet-${var.run_id}"
  address_space       = ["10.0.0.0/16"]
  location            = var.azure_region
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

resource "azurerm_subnet" "main" {
  name                 = "railsbencher-subnet-${var.run_id}"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_network_security_group" "task_runner" {
  name                = "railsbencher-nsg-${var.run_id}"
  location            = var.azure_region
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags

  security_rule {
    name                       = "AllowSSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.allowed_ssh_cidr
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "task_runner" {
  subnet_id                 = azurerm_subnet.main.id
  network_security_group_id = azurerm_network_security_group.task_runner.id
}

resource "azurerm_public_ip" "task_runner" {
  for_each            = local.instance_map
  name                = "railsbencher-ip-${each.key}-${var.run_id}"
  location            = var.azure_region
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.common_tags
}

resource "azurerm_network_interface" "task_runner" {
  for_each            = local.instance_map
  name                = "railsbencher-nic-${each.key}-${var.run_id}"
  location            = var.azure_region
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.main.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.task_runner[each.key].id
  }
}

resource "azurerm_linux_virtual_machine" "task_runner" {
  for_each            = local.instance_map
  name                = "railsbencher-vm-${each.key}-${var.run_id}"
  location            = var.azure_region
  resource_group_name = azurerm_resource_group.main.name
  size                = each.value.instance_type

  admin_username                  = var.admin_username
  disable_password_authentication = true

  network_interface_ids = [
    azurerm_network_interface.task_runner[each.key].id
  ]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  custom_data = base64encode(templatefile("${path.module}/user-data.sh", {
    orchestrator_url = local.orchestrator_url
    api_key          = local.api_key
    run_id           = var.run_id
    provider_name    = "azure"
    instance_type    = each.value.instance_type
    ruby_version     = var.ruby_version
    mock_benchmark   = var.mock_benchmark
    debug_mode       = var.debug_mode
    vcpu_count       = var.vcpu_count[each.value.alias]
  }))

  tags = merge(local.common_tags, {
    Name         = "railsbencher-task-runner-${each.key}-${var.run_id}"
    InstanceType = each.value.instance_type
    Alias        = each.value.alias
  })
}
