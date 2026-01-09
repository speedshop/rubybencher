# Provider Implementation Guide

This guide defines the provider contract for task runners and documents the steps to add a new cloud provider.

The orchestrator always runs on AWS and is publicly reachable. Every task runner (regardless of provider) connects to the same orchestrator URL and uses the API key from the AWS meta Terraform outputs.

## Provider Contract (Master Script)

Providers integrate through the master script registry at:

`bench-new/master/lib/providers/registry.fish`

### Required functions

Each provider must be registered and implement a setup function:

- `provider_list`  
  Return a space-delimited list of providers (e.g., `aws azure local`).
- `provider_phase $provider`  
  Return `pre_orchestrator` for cloud providers that need infra created in advance, or `post_run` for providers that should start after the run is created (e.g., local Docker).
- `provider_validate $provider`  
  Validate provider-specific constraints (e.g., cloud providers must not run with `--local-orchestrator`).
- `provider_setup_task_runners $provider`  
  Dispatch to the provider's implementation.
- Provider implementation function name: `setup_<provider>_task_runners`

### Required behavior

- The provider must read its config from `CONFIG_FILE` (JSON).
- The provider must use `RUN_ID`, `ORCHESTRATOR_URL`, and `API_KEY` from the master script.
- If the provider is cloud-based, it must be able to run in parallel with `wait_for_orchestrator`.
- The provider must respect `task_runners.count` as a **cap** on containers per instance:
  - Default for cloud: **vCPU count**
  - Default for local: **1**
  - If `task_runners.count` is set, use `min(vCPU, count)` (never less than 1)

### Master flow

The master script:

1. Validates config and initializes the orchestrator.
2. Starts all `pre_orchestrator` providers in parallel.
3. Waits for the orchestrator.
4. Creates the run.
5. Starts all `post_run` providers.
6. Waits for provider setup to complete, then monitors the run.

## Provider Implementation Checklist

### 1) Add provider entry

- Add the provider to `provider_list` in:
  - `bench-new/master/lib/providers/registry.fish`
- Implement `setup_<provider>_task_runners` in:
  - `bench-new/master/lib/providers/<provider>.fish`
- Source the provider in:
  - `bench-new/master/run.fish`

### 2) Config schema

Add a provider array to config JSON:

```json
"<provider>": [
  { "instance_type": "your-instance-type", "alias": "short-name" }
]
```

Ensure `bench-new/config/example.json` includes:
- A provider block
- A brief comment describing instance types and aliases

### 3) Task runner count + instance math

Your provider must compute:

- `vCPU count` per instance type
- `effective_vcpu = max(1, min(vcpu, task_runners.count))`
- `instances_needed = ceil(runs_per_instance_type / effective_vcpu)`

This drives:
- `vcpu_count` map (containers per instance)
- `instance_count` map (number of VMs per alias)

### 4) Terraform module

Create `bench-new/infrastructure/<provider>/` with at least:

- `variables.tf`  
  - `run_id`, `ruby_version`, `instance_types`, `vcpu_count`, `instance_count`
  - provider auth inputs as needed
  - `mock_benchmark`, `debug_mode`
- `main.tf`  
  - compute resources (VMs / instances)
  - networking rules (allow outbound HTTPS; SSH only if required)
  - pulls orchestrator URL + API key from AWS meta:
    - `data.terraform_remote_state.meta.outputs.orchestrator_url`
    - `data.terraform_remote_state.meta.outputs.api_key`
- `user-data.sh` or cloud-init template  
  - install Docker + git
  - clone repo
  - build task runner image
  - run one container per `vcpu_count` (with CPU pinning)
- `outputs.tf`  
  - expose instance IPs for debug, e.g. `task_runner_instances`

### 5) Task runner user-data contract

All providers should pass the same core args to the task runner:

- `--orchestrator-url $ORCHESTRATOR_URL`
- `--api-key $API_KEY`
- `--run-id $RUN_ID`
- `--provider <provider>`
- `--instance-type <instance_type>`
- optionally `--mock`
- optionally `--debug --no-exit`

### 6) Credentials

Add provider-specific credential checks in `setup_<provider>_task_runners`.
Fail fast with a clear error if credentials are missing.

### 7) Cleanup (nuke)

Update the nuke scripts to destroy provider resources:

- `bench-new/nuke/lib/terraform.fish`
- `bench-new/nuke/lib/files.fish`
- `bench-new/nuke/nuke.fish` (warning text)

### 8) Documentation

- Update `README.md` with:
  - Example run command
  - Required env vars
  - Any optional overrides
- Add a minimal single-instance config in `bench-new/config/`.

## Provider Examples

Reference implementations:

- AWS: `bench-new/master/lib/providers/aws.fish`  
  `bench-new/infrastructure/aws`
- Azure: `bench-new/master/lib/providers/azure.fish`  
  `bench-new/infrastructure/azure`
- Local: `bench-new/master/lib/providers/local.fish`

## Common Pitfalls

- Forgetting to cap `vcpu_count` with `task_runners.count`
- Forgetting to add provider to `provider_list`
- Missing `terraform_remote_state` outputs for orchestrator URL / API key
- Running cloud provider with `--local-orchestrator`
- Not exposing outbound HTTPS (task runners need orchestrator + S3)

## Quick Provider Skeleton

```fish
# bench-new/master/lib/providers/<provider>.fish
function setup_<provider>_task_runners
    set -l instances (cat "$CONFIG_FILE" | jq -r '.<provider> // empty')
    if test -z "$instances"; or test "$instances" = "null"
        return 0
    end

    if test "$LOCAL_ORCHESTRATOR" = true
        log_error "<provider> task runners cannot be used with --local-orchestrator"
        exit 1
    end

    # validate credentials...
    # compute vcpu + instance_count...
    # terraform init/apply...
end
```
