mock_provider "azurerm" {}

override_data {
  target = data.terraform_remote_state.meta
  values = {
    outputs = {
      orchestrator_url = "https://orchestrator.example.com"
      api_key          = "test-api-key"
    }
  }
}

run "validation" {
  command = plan

  variables {
    azure_region  = "northcentralus"
    run_id        = "test-run"
    ruby_version  = "3.4.0"
    ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDtestkey"

    instance_types = [
      {
        instance_type = "Standard_D2ps_v5"
        alias         = "arm"
        arch          = "arm64"
      },
      {
        instance_type = "Standard_D2s_v5"
        alias         = "x86"
      }
    ]

    instance_count = {
      arm = 1
      x86 = 1
    }

    vcpu_count = {
      arm = 2
      x86 = 2
    }
  }

  assert {
    condition     = azurerm_resource_group.main.name == "railsbencher-test-run"
    error_message = "Resource group naming convention is incorrect"
  }

  assert {
    condition     = azurerm_network_security_group.task_runner.name == "railsbencher-nsg-test-run"
    error_message = "Network security group naming convention is incorrect"
  }

  assert {
    condition     = azurerm_linux_virtual_machine.task_runner["arm-1"].source_image_reference[0].sku == "22_04-lts-arm64"
    error_message = "ARM instance image SKU is incorrect"
  }

  assert {
    condition     = azurerm_linux_virtual_machine.task_runner["x86-1"].source_image_reference[0].sku == "22_04-lts-gen2"
    error_message = "x86 instance image SKU is incorrect"
  }

  assert {
    condition     = strcontains(base64decode(azurerm_linux_virtual_machine.task_runner["arm-1"].custom_data), "VCPU_COUNT=\"2\"")
    error_message = "vCPU count missing from ARM user data"
  }

  assert {
    condition     = strcontains(base64decode(azurerm_linux_virtual_machine.task_runner["arm-1"].custom_data), "INSTANCE_TYPE=\"Standard_D2ps_v5\"")
    error_message = "Instance type missing from ARM user data"
  }

  assert {
    condition     = anytrue([
      for rule in azurerm_network_security_group.task_runner.security_rule :
      rule.name == "AllowHttpsOut" && rule.direction == "Outbound" && rule.destination_port_range == "443"
    ])
    error_message = "Outbound HTTPS rule missing"
  }

  assert {
    condition     = azurerm_linux_virtual_machine.task_runner["arm-1"].name == "railsbencher-vm-arm-1-test-run"
    error_message = "VM naming convention is incorrect"
  }
}
