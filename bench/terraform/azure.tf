# Azure Provider Configuration
provider "azurerm" {
  features {}
  subscription_id = var.azure_subscription_id
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
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# Azure instance type configurations
locals {
  azure_instance_types = {
    # ARM (Ampere Altra)
    "Standard_D32pls_v5" = {
      vm_size = "Standard_D32pls_v5"
      arch    = "arm64"
    }
    "Standard_D32pls_v6" = {
      vm_size = "Standard_D32pls_v6"
      arch    = "arm64"
    }
    # AMD
    "Standard_D32als_v6" = {
      vm_size = "Standard_D32als_v6"
      arch    = "x86_64"
    }
    "Standard_D32als_v7" = {
      vm_size = "Standard_D32als_v7"
      arch    = "x86_64"
    }
    "Standard_F32als_v6" = {
      vm_size = "Standard_F32als_v6"
      arch    = "x86_64"
    }
    "Standard_F32als_v7" = {
      vm_size = "Standard_F32als_v7"
      arch    = "x86_64"
    }
    # Intel
    "Standard_D32ls_v5" = {
      vm_size = "Standard_D32ls_v5"
      arch    = "x86_64"
    }
    "Standard_D32ls_v6" = {
      vm_size = "Standard_D32ls_v6"
      arch    = "x86_64"
    }
  }

  # Create N replicas of each Azure instance type
  azure_instances = merge([
    for type_name, config in local.azure_instance_types : {
      for i in range(1, var.replicas + 1) : "${type_name}-${i}" => {
        vm_size   = config.vm_size
        arch      = config.arch
        type_name = type_name
        replica   = i
      }
    }
  ]...)
}

# Public IPs for Azure VMs
resource "azurerm_public_ip" "bench" {
  for_each = local.azure_instances

  name                = "ruby-bench-pip-${each.key}"
  location            = azurerm_resource_group.bench.location
  resource_group_name = azurerm_resource_group.bench.name
  allocation_method   = "Static"
  sku                 = "Standard"
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
    public_ip_address_id          = azurerm_public_ip.bench[each.key].id
  }
}

# Associate NSG with NICs
resource "azurerm_network_interface_security_group_association" "bench" {
  for_each = local.azure_instances

  network_interface_id      = azurerm_network_interface.bench[each.key].id
  network_security_group_id = azurerm_network_security_group.bench.id
}

# User data script for Azure (cloud-init)
locals {
  azure_user_data = <<-EOF
    #cloud-config
    package_update: true
    packages:
      - docker.io
      - git
      - at
    runcmd:
      - systemctl enable docker atd
      - systemctl start docker atd
      - usermod -aG docker azureuser
      - echo "sudo shutdown -h now" | at now + 60 minutes
      - touch /home/azureuser/.setup_complete
  EOF
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
    offer     = each.value.arch == "arm64" ? "ubuntu-24_04-lts-arm64" : "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  custom_data = base64encode(local.azure_user_data)

  tags = {
    Name = "ruby-bench-${each.key}"
  }
}
