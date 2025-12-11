# Azure Provider Configuration
# Use subscription from Azure CLI if not explicitly set
provider "azurerm" {
  features {}
  subscription_id                 = var.azure_subscription_id != "" ? var.azure_subscription_id : null
  use_cli                         = true
  resource_provider_registrations = "none"
}

# Resource Group
resource "azurerm_resource_group" "bench" {
  name     = "ruby-bench-rg"
  location = var.azure_region
}

# Virtual Network
resource "azurerm_virtual_network" "bench" {
  name                = "ruby-bench-vnet"
  address_space       = ["10.1.0.0/16"]
  location            = azurerm_resource_group.bench.location
  resource_group_name = azurerm_resource_group.bench.name

  timeouts {
    create = "15m"
    read   = "5m"
  }
}

# Subnet
resource "azurerm_subnet" "bench" {
  name                 = "ruby-bench-subnet"
  resource_group_name  = azurerm_resource_group.bench.name
  virtual_network_name = azurerm_virtual_network.bench.name
  address_prefixes     = ["10.1.1.0/24"]
}

# Network Security Group
resource "azurerm_network_security_group" "bench" {
  name                = "ruby-bench-nsg"
  location            = azurerm_resource_group.bench.location
  resource_group_name = azurerm_resource_group.bench.name

  security_rule {
    name                       = "allow-ssh-from-vnet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }
}

# Bastion NSG (isolated from workload NSG)
resource "azurerm_network_security_group" "bastion" {
  name                = "ruby-bench-bastion-nsg"
  location            = azurerm_resource_group.bench.location
  resource_group_name = azurerm_resource_group.bench.name

  security_rule {
    name                       = "allow-ssh-from-allowed-cidrs"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefixes    = var.azure_bastion_allowed_cidrs
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "egress-all"
    priority                   = 400
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# Azure instance type configurations (reads from shared config)
locals {
  azure_instance_types = {
    for name, config in local.instance_types_config.azure : name => {
      vm_size = name
      arch    = config.arch
    } if !contains(local.normalized_skip_types, name)
  }

  # Create N replicas of each Azure instance type
  azure_instances = merge([
    for type_name, config in local.azure_instance_types : {
      for i in range(1, var.azure_replicas + 1) : "${type_name}-${i}" => {
        vm_size   = config.vm_size
        arch      = config.arch
        type_name = type_name
        replica   = i
      }
    }
  ]...)
}

# NAT public IP for outbound access
resource "azurerm_public_ip" "nat" {
  name                = "ruby-bench-nat-pip"
  location            = azurerm_resource_group.bench.location
  resource_group_name = azurerm_resource_group.bench.name
  allocation_method   = "Static"
  sku                 = "Standard"

  timeouts {
    create = "15m"
    read   = "5m"
  }
}

resource "azurerm_nat_gateway" "bench" {
  name                = "ruby-bench-nat"
  location            = azurerm_resource_group.bench.location
  resource_group_name = azurerm_resource_group.bench.name
  sku_name            = "Standard"

  timeouts {
    create = "15m"
    read   = "5m"
  }
}

resource "azurerm_nat_gateway_public_ip_association" "bench" {
  nat_gateway_id       = azurerm_nat_gateway.bench.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "bench" {
  subnet_id      = azurerm_subnet.bench.id
  nat_gateway_id = azurerm_nat_gateway.bench.id
}

# Bastion public IP and NIC
resource "azurerm_public_ip" "bastion" {
  name                = "ruby-bench-bastion-pip"
  location            = azurerm_resource_group.bench.location
  resource_group_name = azurerm_resource_group.bench.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "bastion" {
  name                = "ruby-bench-bastion-nic"
  location            = azurerm_resource_group.bench.location
  resource_group_name = azurerm_resource_group.bench.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.bench.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.bastion.id
  }
}

resource "azurerm_network_interface_security_group_association" "bastion" {
  network_interface_id      = azurerm_network_interface.bastion.id
  network_security_group_id = azurerm_network_security_group.bastion.id
}

# Network Interfaces for Azure VMs
resource "azurerm_network_interface" "bench" {
  for_each = local.azure_instances

  name                = "ruby-bench-nic-${each.key}"
  location            = azurerm_resource_group.bench.location
  resource_group_name = azurerm_resource_group.bench.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.bench.id
    private_ip_address_allocation = "Dynamic"
  }
}

# Associate NSG with NICs
resource "azurerm_network_interface_security_group_association" "bench" {
  for_each = local.azure_instances

  network_interface_id      = azurerm_network_interface.bench[each.key].id
  network_security_group_id = azurerm_network_security_group.bench.id
}

# Bastion VM
resource "azurerm_linux_virtual_machine" "bastion" {
  name                = "ruby-bench-bastion"
  resource_group_name = azurerm_resource_group.bench.name
  location            = azurerm_resource_group.bench.location
  size                = "Standard_D2ls_v6"
  admin_username      = "azureuser"

  network_interface_ids = [
    azurerm_network_interface.bastion.id,
  ]

  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.bench.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  tags = {
    Name = "ruby-bench-bastion"
  }
}

# Azure VMs
resource "azurerm_linux_virtual_machine" "bench" {
  for_each = local.azure_instances

  name                = "ruby-bench-${replace(each.key, "_", "-")}"
  resource_group_name = azurerm_resource_group.bench.name
  location            = azurerm_resource_group.bench.location
  size                = each.value.vm_size
  admin_username      = "azureuser"

  network_interface_ids = [
    azurerm_network_interface.bench[each.key].id,
  ]

  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.bench.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 30
  }

  # Use Ubuntu for Azure (better cloud-init support and ARM image availability)
  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = each.value.arch == "arm64" ? "server-arm64" : "server"
    version   = "latest"
  }

  custom_data = base64encode(templatefile("${path.module}/cloud-init-azure.tpl", {
    run_id        = local.upload_config.run_id
    instance_key  = each.key
    instance_type = each.value.type_name
    result_url    = try(local.upload_config.instances[each.key].result_url, "")
    error_url     = try(local.upload_config.instances[each.key].error_url, "")
    heartbeat_url = try(local.upload_config.instances[each.key].heartbeat_url, "")
  }))

  tags = {
    Name = "ruby-bench-${each.key}"
  }
}
