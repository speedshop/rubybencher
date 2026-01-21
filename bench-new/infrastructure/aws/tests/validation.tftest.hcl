mock_provider "aws" {
  mock_data "aws_ami" {
    defaults = {
      id = "ami-test"
    }
  }
}

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
    aws_region   = "us-east-1"
    key_name     = "test-key"
    run_id       = "test-run"
    ruby_version = "3.4.0"

    instance_types = [
      {
        instance_type = "c7g.medium"
        alias         = "c7g"
      },
      {
        instance_type = "c7i.large"
        alias         = "c7i"
      }
    ]

    instance_count = {
      c7g = 1
      c7i = 1
    }

    vcpu_count = {
      c7g = 2
      c7i = 4
    }
  }

  assert {
    condition     = local.instance_arch["c7g"] == "arm64"
    error_message = "ARM instance type not detected"
  }

  assert {
    condition     = local.instance_arch["c7i"] == "x86_64"
    error_message = "x86 instance type not detected"
  }

  assert {
    condition     = strcontains(base64decode(aws_instance.task_runner["c7g-1"].user_data), "VCPU_COUNT=\"2\"")
    error_message = "vCPU count missing from ARM user data"
  }

  assert {
    condition     = strcontains(base64decode(aws_instance.task_runner["c7i-1"].user_data), "VCPU_COUNT=\"4\"")
    error_message = "vCPU count missing from x86 user data"
  }

  assert {
    condition     = strcontains(base64decode(aws_instance.task_runner["c7g-1"].user_data), "ORCHESTRATOR_URL=\"https://orchestrator.example.com\"")
    error_message = "User data did not render orchestrator URL"
  }

  assert {
    condition     = anytrue([
      for rule in aws_security_group.task_runner.egress :
      rule.protocol == "-1" && contains(rule.cidr_blocks, "0.0.0.0/0")
    ])
    error_message = "Security group does not allow outbound HTTPS"
  }

  assert {
    condition     = aws_vpc.run.tags["Name"] == "railsbencher-vpc-test-run"
    error_message = "VPC naming convention is incorrect"
  }

  assert {
    condition     = aws_instance.task_runner["c7g-1"].tags["Name"] == "railsbencher-task-runner-c7g-1-test-run"
    error_message = "Task runner naming convention is incorrect"
  }
}
