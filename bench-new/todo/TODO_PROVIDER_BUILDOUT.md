# Provider Buildout Plan

This document outlines the strategy for building out new providers (Azure, Heroku, GCP, etc.) with maximum testing and verifiability.

## Core Questions Each Provider Must Answer

1. **Can it start and run a task runner?**
   - Provision compute resources
   - Install dependencies (Docker, Ruby)
   - Start task runner container(s)
   - Scale appropriately for instance type

2. **Can it communicate with the AWS orchestrator?**
   - Outbound HTTPS to orchestrator endpoint
   - Outbound HTTPS to S3 for result uploads
   - Receive presigned URLs and use them correctly

## Current Architecture Analysis

The existing architecture has **no provider abstraction layer** - providers are string identifiers, and all infrastructure-specific logic lives in Terraform. This is actually a strength: the Ruby code is cloud-agnostic.

**What varies by provider:**
- Terraform module (compute, networking, IAM)
- Instance type naming conventions
- Architecture detection (ARM vs x86)
- User data/startup script format
- Networking/firewall rules

**What stays constant:**
- Task runner Docker image
- Orchestrator API contract
- S3 upload mechanism (presigned URLs)
- Heartbeat/claim/complete flow

## Testing Strategy: The Testing Pyramid

```
                    /\
                   /  \
                  / E2E \        <- Full benchmark runs (expensive, slow)
                 /--------\
                /Integration\    <- Cross-cloud connectivity tests
               /--------------\
              /   Contract     \  <- API contract verification
             /------------------\
            /       Unit         \ <- Component isolation tests
           /----------------------\
```

### Level 1: Unit Tests (Fast, Cheap, Run Always)

#### 1.1 Terraform Module Validation

For each provider module, create validation tests:

```hcl
# infrastructure/<provider>/tests/validation.tftest.hcl

run "instance_type_architecture_detection" {
  variables {
    instance_types = ["Standard_D2s_v3", "Standard_D2ps_v5"]  # Azure ARM example
  }

  assert {
    condition     = local.arm_instances["Standard_D2ps_v5"] == true
    error_message = "ARM instance type not detected"
  }
}

run "security_group_allows_outbound_https" {
  assert {
    condition     = contains(aws_security_group.task_runner.egress[*].to_port, 443)
    error_message = "HTTPS egress not allowed"
  }
}
```

**Tests to write for each provider:**
- [ ] Instance type -> architecture mapping (ARM vs x86)
- [ ] Instance type -> vCPU count mapping
- [ ] Security group/firewall allows outbound HTTPS (443)
- [ ] User data script template renders correctly
- [ ] Resource naming follows conventions

#### 1.2 User Data Script Testing

Create a test harness for user data scripts:

```ruby
# infrastructure/shared/test/user_data_test.rb

class UserDataTest < Minitest::Test
  def test_aws_user_data_sets_required_env_vars
    script = render_user_data("aws", {
      orchestrator_url: "https://example.com",
      api_key: "test-key",
      run_id: "12345",
      provider: "aws",
      instance_type: "c7g.medium"
    })

    assert_includes script, 'ORCHESTRATOR_URL="https://example.com"'
    assert_includes script, 'API_KEY="test-key"'
    assert_includes script, 'PROVIDER="aws"'
  end

  def test_azure_user_data_installs_docker
    script = render_user_data("azure", test_vars)
    assert_includes script, "apt-get install -y docker"
  end
end
```

#### 1.3 Task Runner Provider-Agnosticism Tests

Verify task runner has no provider-specific code paths:

```ruby
# task-runner/test/provider_agnostic_test.rb

class ProviderAgnosticTest < Minitest::Test
  PROVIDERS = %w[aws azure gcp heroku local].freeze

  PROVIDERS.each do |provider|
    define_method("test_worker_initializes_with_#{provider}_provider") do
      worker = Worker.new(
        orchestrator_url: "http://test",
        api_key: "key",
        run_id: "123",
        provider: provider,
        instance_type: "test-type"
      )

      assert_equal provider, worker.provider
      # No provider-specific initialization should occur
    end
  end
end
```

### Level 2: Contract Tests (Medium Speed, Provider-Independent)

#### 2.1 Orchestrator API Contract Tests

Define and verify the API contract that all task runners must implement:

```ruby
# orchestrator/test/contracts/task_runner_contract_test.rb

class TaskRunnerContractTest < ActionDispatch::IntegrationTest
  # These tests define the contract that task runners depend on

  test "claim endpoint returns assigned status with required fields" do
    run = create_run_with_pending_tasks

    post claim_run_tasks_path(run),
      params: { provider: "aws", instance_type: "c7g.medium" },
      headers: auth_headers

    assert_response :success
    json = JSON.parse(response.body)

    # Contract: assigned response MUST contain these fields
    assert_equal "assigned", json["status"]
    assert json.key?("task_id"), "Contract violation: missing task_id"
    assert json.key?("upload_url"), "Contract violation: missing upload_url"
    assert json.key?("run_number"), "Contract violation: missing run_number"
  end

  test "claim endpoint returns done status when no tasks remain" do
    run = create_run_with_all_completed_tasks

    post claim_run_tasks_path(run),
      params: { provider: "aws", instance_type: "c7g.medium" },
      headers: auth_headers

    json = JSON.parse(response.body)
    assert_equal "done", json["status"]
  end

  test "heartbeat endpoint accepts all valid heartbeat_status values" do
    task = create_claimed_task

    %w[boot provision running uploading finished error].each do |status|
      post heartbeat_task_path(task),
        params: { heartbeat_status: status },
        headers: auth_headers

      assert_response :success, "Heartbeat status '#{status}' should be valid"
    end
  end
end
```

#### 2.2 Task Runner Contract Compliance Tests

Test that task runner correctly implements the contract:

```ruby
# task-runner/test/contracts/orchestrator_contract_test.rb

class OrchestratorContractTest < Minitest::Test
  def test_claim_request_sends_required_parameters
    stub_request(:post, %r{/runs/.*/tasks/claim})
      .to_return(body: { status: "done" }.to_json)

    client = ApiClient.new("http://test", "key")
    client.claim_task("run-1", "aws", "c7g.medium")

    assert_requested(:post, %r{/runs/run-1/tasks/claim}) do |req|
      body = JSON.parse(req.body)
      body["provider"] == "aws" && body["instance_type"] == "c7g.medium"
    end
  end

  def test_heartbeat_sends_all_required_fields
    stub_request(:post, %r{/tasks/.*/heartbeat})
      .to_return(status: 200)

    client = ApiClient.new("http://test", "key")
    client.heartbeat("task-1", {
      heartbeat_status: "running",
      current_benchmark: "activerecord",
      progress_pct: 50
    })

    assert_requested(:post, %r{/tasks/task-1/heartbeat}) do |req|
      body = JSON.parse(req.body)
      body.key?("heartbeat_status")
    end
  end
end
```

### Level 3: Integration Tests (Slower, Require Infrastructure)

#### 3.1 Local Integration Test Environment

Create a docker-compose environment that simulates cross-provider communication:

```yaml
# test/integration/docker-compose.yml

services:
  orchestrator:
    build: ../../orchestrator
    environment:
      - API_KEY=test-key
      - AWS_ENDPOINT_URL=http://minio:9000
    networks:
      - orchestrator-net

  minio:
    image: quay.io/minio/minio
    networks:
      - orchestrator-net

  # Simulate task runner in isolated network (like different cloud)
  task-runner-isolated:
    build: ../../task-runner
    environment:
      - ORCHESTRATOR_URL=http://orchestrator:3000
      - API_KEY=test-key
    networks:
      - runner-net

  # Proxy to simulate cross-cloud connectivity
  cross-cloud-proxy:
    image: nginx
    networks:
      - orchestrator-net
      - runner-net

networks:
  orchestrator-net:
  runner-net:
```

#### 3.2 Connectivity Verification Script

```fish
# test/integration/verify_connectivity.fish

#!/usr/bin/env fish

# This script verifies a task runner can reach the orchestrator
# Run from within a task runner environment

set orchestrator_url $argv[1]
set api_key $argv[2]

echo "Testing orchestrator connectivity..."

# Test 1: Can reach orchestrator health endpoint
set health_response (curl -s -o /dev/null -w "%{http_code}" "$orchestrator_url/health")
if test $health_response -ne 200
    echo "FAIL: Cannot reach orchestrator health endpoint (HTTP $health_response)"
    exit 1
end
echo "PASS: Orchestrator reachable"

# Test 2: Can authenticate
set auth_response (curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $api_key" \
    "$orchestrator_url/runs")
if test $auth_response -ne 200
    echo "FAIL: Authentication failed (HTTP $auth_response)"
    exit 1
end
echo "PASS: Authentication working"

# Test 3: Can upload to S3 (get presigned URL and upload test data)
echo "Testing S3 upload capability..."
# This would need orchestrator support for a test upload endpoint

echo "All connectivity tests passed"
```

#### 3.3 Provider-Specific Integration Tests

For each provider, create a minimal integration test that:

```ruby
# test/integration/provider_integration_test.rb

class ProviderIntegrationTest < Minitest::Test
  # These tests actually spin up infrastructure
  # Run with: INTEGRATION=1 rake test:integration

  def setup
    skip unless ENV["INTEGRATION"]
    @orchestrator_url = ENV.fetch("ORCHESTRATOR_URL")
    @api_key = ENV.fetch("API_KEY")
  end

  def test_aws_task_runner_completes_mock_benchmark
    run_id = create_test_run(providers: { aws: ["t3.micro"] })

    # Wait for task runner to claim and complete
    assert_run_completes_within(run_id, timeout: 300)

    # Verify results were uploaded
    run_status = fetch_run_status(run_id)
    assert run_status["tasks"].all? { |t| t["status"] == "completed" }
  end

  def test_azure_task_runner_completes_mock_benchmark
    skip "Azure not yet implemented"
    run_id = create_test_run(providers: { azure: ["Standard_B1s"] })
    assert_run_completes_within(run_id, timeout: 300)
  end
end
```

### Level 4: End-to-End Tests (Expensive, Run Sparingly)

#### 4.1 Full Provider Smoke Test

```fish
# test/e2e/provider_smoke_test.fish

#!/usr/bin/env fish

# Full E2E test for a provider
# Usage: ./provider_smoke_test.fish <provider> <instance_type>

set provider $argv[1]
set instance_type $argv[2]

# Create minimal test config
set config_file (mktemp)
echo "{
  \"ruby_version\": \"3.3.0\",
  \"$provider\": [\"$instance_type\"],
  \"runs_per_instance_type\": 1,
  \"mock\": true
}" > $config_file

# Run the benchmark
set run_id (date +%s)
./master/run.fish --config $config_file --run-id $run_id

# Verify results exist
if test -d "results/$run_id"
    echo "PASS: Results directory created"

    # Check for expected files
    if test -f "results/$run_id/$instance_type-1/metadata.json"
        echo "PASS: Task results present"
    else
        echo "FAIL: Missing task results"
        exit 1
    end
else
    echo "FAIL: No results directory"
    exit 1
end

# Cleanup
rm $config_file
```

#### 4.2 Cross-Provider Benchmark Run

Test that multiple providers can participate in the same run:

```fish
# test/e2e/multi_provider_test.fish

# Test AWS + Azure in same run
set config_file (mktemp)
echo "{
  \"ruby_version\": \"3.3.0\",
  \"aws\": [\"t3.micro\"],
  \"azure\": [\"Standard_B1s\"],
  \"runs_per_instance_type\": 1,
  \"mock\": true
}" > $config_file

./master/run.fish --config $config_file

# Verify both providers' results present
```

## Provider Implementation Checklist

For each new provider, complete these items:

### Infrastructure (Terraform)

- [ ] Create `infrastructure/<provider>/` module
- [ ] Define compute resource (VM/container/dyno)
- [ ] Configure networking (allow outbound HTTPS)
- [ ] Create instance type -> architecture mapping
- [ ] Create instance type -> vCPU mapping
- [ ] Write user data script template
- [ ] Output task runner connection info
- [ ] Add Terraform validation tests

### Master Script Updates

- [ ] Add provider to `run.fish` provider list
- [ ] Handle provider-specific Terraform variables
- [ ] Add provider cleanup to nuke script

### Testing Artifacts

- [ ] Unit tests for Terraform module (`.tftest.hcl`)
- [ ] User data script rendering tests
- [ ] Local integration test with mock orchestrator
- [ ] Connectivity verification script
- [ ] Provider smoke test (E2E)

### Documentation

- [ ] Provider-specific setup instructions
- [ ] Required cloud credentials/permissions
- [ ] Instance type naming conventions
- [ ] Cost estimation for common instance types

## Detailed Provider Plans

### Azure Implementation

**Compute**: Azure VMs or Azure Container Instances

**Key differences from AWS:**
- Instance types: `Standard_D2s_v3`, `Standard_D2ps_v5` (ARM)
- ARM detection: Types containing `p` before `s` (e.g., `D2ps`) are ARM
- User data: cloud-init via `custom_data`
- Networking: NSG rules instead of security groups

**Terraform structure:**
```
infrastructure/azure/
├── main.tf           # Provider config, resource group
├── compute.tf        # VM definitions
├── network.tf        # VNet, subnet, NSG
├── variables.tf      # Instance types, orchestrator URL
├── outputs.tf        # Task runner IPs
├── user-data.sh      # Startup script template
└── tests/
    └── validation.tftest.hcl
```

**Architecture detection:**
```hcl
locals {
  # Azure ARM instances have 'p' in the size (e.g., Standard_D2ps_v5)
  arm_instances = {
    for type in var.instance_types :
    type => can(regex("Standard_[A-Z][0-9]+p", type))
  }
}
```

### Heroku Implementation

**Compute**: Heroku Dynos (Private Spaces for VPC peering, or public with HTTPS)

**Key differences:**
- No Terraform - use Heroku CLI or Platform API
- Instance types: `standard-1x`, `standard-2x`, `performance-m`, etc.
- No ARM support currently
- Networking: Heroku handles outbound; orchestrator must be publicly accessible

**Implementation approach:**
```fish
# infrastructure/heroku/deploy.fish

# Create Heroku app for task runner
heroku apps:create railsbencher-runner-$run_id --team $HEROKU_TEAM

# Set config vars
heroku config:set \
  ORCHESTRATOR_URL=$orchestrator_url \
  API_KEY=$api_key \
  RUN_ID=$run_id \
  PROVIDER=heroku \
  INSTANCE_TYPE=$dyno_type \
  --app railsbencher-runner-$run_id

# Deploy task runner container
heroku container:push worker --app railsbencher-runner-$run_id
heroku container:release worker --app railsbencher-runner-$run_id

# Scale to appropriate dyno type
heroku ps:scale worker=1:$dyno_type --app railsbencher-runner-$run_id
```

**Testing considerations:**
- Heroku apps take longer to start (cold start)
- May need longer heartbeat timeout
- Public orchestrator endpoint required (or Private Spaces)

### GCP Implementation

**Compute**: Compute Engine VMs or Cloud Run

**Key differences:**
- Instance types: `e2-micro`, `n2-standard-2`, `t2a-standard-1` (ARM)
- ARM detection: `t2a-*` types are ARM (Tau T2A)
- User data: startup-script metadata
- Networking: Firewall rules

### Local/Docker Implementation (Reference)

Already implemented. Useful as reference and for CI testing.

## CI/CD Integration

### PR Checks (Fast)

```yaml
# .github/workflows/pr-checks.yml

jobs:
  unit-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Orchestrator tests
        run: |
          cd bench-new/orchestrator
          bundle install
          rails test

      - name: Task runner tests
        run: |
          cd bench-new/task-runner
          bundle install
          rake test

      - name: Terraform validation
        run: |
          for provider in aws azure gcp; do
            if [ -d "bench-new/infrastructure/$provider" ]; then
              cd "bench-new/infrastructure/$provider"
              terraform init -backend=false
              terraform validate
              terraform test
              cd -
            fi
          done
```

### Nightly Integration Tests

```yaml
# .github/workflows/nightly-integration.yml

on:
  schedule:
    - cron: '0 4 * * *'  # 4am UTC

jobs:
  provider-integration:
    strategy:
      matrix:
        provider: [aws, azure]
        include:
          - provider: aws
            instance_type: t3.micro
          - provider: azure
            instance_type: Standard_B1s

    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup cloud credentials
        run: |
          # Provider-specific credential setup

      - name: Run provider smoke test
        run: |
          ./test/e2e/provider_smoke_test.fish ${{ matrix.provider }} ${{ matrix.instance_type }}
        timeout-minutes: 15
```

## Verification Runbook

When adding a new provider, verify each of these manually before considering it complete:

### Pre-Deploy Verification

1. [ ] Terraform plan shows expected resources
2. [ ] User data script contains correct environment variables
3. [ ] Security group/firewall allows outbound 443
4. [ ] Instance type mapping is correct for all types

### Post-Deploy Verification

1. [ ] Task runner VM/container starts successfully
2. [ ] Docker is installed and running
3. [ ] Task runner container starts
4. [ ] Task runner logs show successful orchestrator connection
5. [ ] Task is claimed successfully
6. [ ] Heartbeats are received by orchestrator
7. [ ] Benchmark runs (even mock)
8. [ ] Results uploaded to S3
9. [ ] Task marked as completed
10. [ ] Cleanup destroys all resources

### Failure Mode Verification

1. [ ] What happens if orchestrator is unreachable at boot?
2. [ ] What happens if S3 upload fails?
3. [ ] What happens if task runner crashes mid-benchmark?
4. [ ] What happens if heartbeat stops being sent?
5. [ ] Are resources cleaned up on failure?

## Network Topology Considerations

```
┌─────────────────────────────────────────────────────────────┐
│                         AWS                                  │
│  ┌──────────────────┐     ┌──────────────────┐             │
│  │   Orchestrator   │     │    S3 Bucket     │             │
│  │   (Rails App)    │     │   (Results)      │             │
│  │   Port 443       │     │   Port 443       │             │
│  └────────┬─────────┘     └────────┬─────────┘             │
│           │                        │                        │
│           │ HTTPS                  │ HTTPS (presigned)      │
└───────────┼────────────────────────┼────────────────────────┘
            │                        │
   ┌────────┴────────────────────────┴────────┐
   │              Public Internet             │
   └────────┬────────────────────────┬────────┘
            │                        │
┌───────────┼────────────────────────┼────────────────────────┐
│           │        Azure           │                        │
│  ┌────────┴─────────┐    ┌────────┴─────────┐             │
│  │   Task Runner    │    │   Task Runner    │             │
│  │   (Docker)       │    │   (Docker)       │             │
│  │   Outbound 443   │    │   Outbound 443   │             │
│  └──────────────────┘    └──────────────────┘             │
└─────────────────────────────────────────────────────────────┘
```

**Key requirements:**
- Orchestrator must be reachable from task runners (HTTPS)
- S3 bucket must be reachable from task runners (HTTPS presigned URLs)
- No inbound connections required to task runners
- All communication is task-runner-initiated

## Monitoring & Observability

### Per-Provider Metrics to Track

- Task claim latency (time from boot to first claim)
- Task completion rate (completed / total)
- Average task duration
- Heartbeat reliability (missed heartbeats / total)
- S3 upload success rate
- Boot time (provider-specific)

### Alerting

- Task stuck in "claimed" for > 5 minutes without heartbeat
- Provider has 100% failure rate for > 10 minutes
- No tasks claimed from provider for > expected boot time + 2 min

## Cost Considerations

Each provider has different pricing models. Track and document:

- Minimum billable time (AWS: 1 minute, some clouds: 1 hour)
- Startup time (affects minimum cost)
- Data egress costs (results upload to S3)
- Storage costs for task runner images

## Summary: Testing Priority Order

1. **Always run**: Unit tests, Terraform validation, contract tests
2. **On PR**: Mock integration tests (docker-compose)
3. **Nightly**: Real provider smoke tests with cheapest instances
4. **Weekly**: Full multi-provider integration tests
5. **On release**: Full E2E with production-like instance types
