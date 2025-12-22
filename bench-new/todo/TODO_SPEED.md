# Benchmark Speed Optimizations

Ideas for speeding up the benchmark run process, ranked by impact.

## High Impact

### 1. Parallelize AWS terraform with orchestrator startup

Currently the flow is sequential:
```
meta terraform → wait for orchestrator → AWS terraform
```

But AWS task runners don't need the orchestrator to be *ready*, they just need its IP (which exists right after meta terraform). Task runners will retry connecting until orchestrator is up. Change to:

```
meta terraform → [wait for orchestrator] in parallel with [AWS terraform]
```

This could save 2-3 minutes since AWS instance startup overlaps with orchestrator container startup.

**Implementation:** After `setup_infrastructure`, spawn `setup_aws_task_runners` in background, then `wait_for_orchestrator`, then wait for the background job.

### 2. Pre-baked AMI

The biggest time sink is user-data scripts installing Ruby, Docker, and dependencies on every instance launch. A custom AMI with everything pre-installed would cut instance startup from minutes to seconds.

**Implementation:**
- Create Packer template for task runner AMI
- Pre-install: Ruby (multiple versions?), Docker, benchmark dependencies
- User data just starts the task runner script with parameters
- Same approach for orchestrator AMI

### 3. Run multiple workers per instance with CPU pinning

The orchestrator already supports multiple concurrent tasks per `provider + instance_type` - each worker can claim and run tasks in parallel. However, we currently deploy one worker per EC2 instance. On multi-vCPU boxes, we could run multiple worker containers per instance to better utilize hardware.

**Implementation:**
- Add config like `task_runners.workers_per_instance` (default 1)
- In user-data, start N worker containers instead of 1
- Pin each container to a dedicated vCPU (`--cpuset-cpus=N`) so runs don't contend for CPU
- Trade-off: memory contention and cache effects may reduce benchmark accuracy

**Savings:** Reduces wall time roughly by the parallelism factor, but may affect benchmark consistency.

### 3. Persistent base infrastructure

VPC, subnets, S3 bucket, security groups, and bastion don't need to be recreated each run. Split terraform:

```
infrastructure/
  base/           # Create once, keep forever (VPC, S3, bastion, security groups)
  orchestrator/   # Per-run orchestrator
  task-runners/   # Per-run task runners
```

Run `terraform apply` on base once. Each benchmark run only creates orchestrator + task runners.

**Savings:** VPC/subnet/gateway creation is 30-60 seconds. S3 bucket creation adds more. Bastion instance startup adds 1-2 minutes.

### 4. Batch terraform output calls

Currently multiple `terraform output` calls in `get_orchestrator_config` and `setup_aws_task_runners`:

```fish
# Current: 6+ separate terraform calls
set -g ORCHESTRATOR_URL (terraform -chdir="$tf_dir" output -raw orchestrator_url)
set -g API_KEY (terraform -chdir="$tf_dir" output -raw api_key)
set -g S3_BUCKET (terraform -chdir="$tf_dir" output -raw s3_bucket_name)
set -l key_name (terraform -chdir="$meta_tf_dir" output -raw key_name)
set -l aws_region (terraform -chdir="$meta_tf_dir" output -raw aws_region)
set -l bastion_ip (terraform -chdir="$meta_tf_dir" output -raw bastion_public_ip)
```

Replace with single call:

```fish
# New: 1 terraform call
set -l outputs (terraform -chdir="$tf_dir" output -json)
set -g ORCHESTRATOR_URL (echo $outputs | jq -r '.orchestrator_url.value')
set -g API_KEY (echo $outputs | jq -r '.api_key.value')
set -g S3_BUCKET (echo $outputs | jq -r '.s3_bucket_name.value')
# ...
```

**Savings:** Each terraform output call takes 1-2 seconds (state file read). 6 calls = 6-12 seconds saved.

---

## Medium Impact

### 5. Push orchestrator image to ECR instead of building on-instance

Building the Docker image on the EC2 instance is slow (downloading base image, installing gems, etc.).

**Alternative approach:**
- Build orchestrator image locally (or in CI)
- Push to ECR
- Instance user-data just does `docker pull` and `docker compose up`

**Savings:** 1-2 minutes on orchestrator startup.

### 6. Prebuild task runner image and pull from registry

Task runners currently `git clone` and `docker build` on every instance. Publish a versioned `task-runner` image (ECR or GHCR) and just `docker pull` in user-data.

**Implementation:** Build in CI or locally, push to registry; update `bench-new/infrastructure/aws/user-data.sh` to pull image instead of building.

**Savings:** 1-2 minutes per instance (plus less variance).

### 7. Cache ruby-bench between tasks

Each task clones ruby-bench from GitHub and throws it away. If a container runs multiple tasks, reuse the repo (or bake it into the image) and only `git fetch` if needed.

**Implementation:** Change `BenchmarkRunner` to keep `/tmp/ruby-bench` and skip `git clone` when present; optionally `git fetch --depth 1` + `git reset --hard`.

**Savings:** 10-30s per task (more if runs_per_instance_type is high).

### 6. Parallel local task runner startup

Current code starts task runners sequentially:

```fish
for i in (seq 0 (math (cat "$CONFIG_FILE" | jq '.local | length') - 1))
    # ... starts one at a time
end
```

Could parallelize with background jobs or single docker command with multiple containers.

### 7. Reduce orchestrator polling interval

```fish
# Current: 5 seconds between checks
gum spin --spinner dot --title "Waiting for orchestrator..." -- sleep 5

# Faster: 2 seconds
gum spin --spinner dot --title "Waiting for orchestrator..." -- sleep 2
```

**Savings:** If orchestrator takes 10 checks to come up, saves 30 seconds.

### 8. Skip orchestrator wait if already healthy

When using `--skip-infra` with existing infrastructure, do a single health check instead of polling loop. If healthy, continue immediately.

### 9. Skip OS package updates on every boot

`dnf update -y` is slow and runs on every instance. If the AMI is already recent (or you bake updates into the AMI), skip it during user-data.

**Implementation:** Add a `--skip-updates` flag or bake updates into AMI; adjust `bench-new/infrastructure/meta/user-data.sh` and `bench-new/infrastructure/aws/user-data.sh`.

**Savings:** 30-90s per instance.

### 10. Decouple run completion from gzip building

Run completion currently waits on `collect_all_results` (downloads/extracts/compresses). Mark runs complete as soon as tasks finish, and build gzip asynchronously (or let the master script skip/poll for gzip separately).

**Implementation:** Move status update earlier in `GzipBuilderJob`, add `--skip-download` / `--poll-gzip` in master, or let master download per-task results directly.

**Savings:** Saves the gzip build time on the critical path.

---

## Lower Impact (Easy Wins)

### 9. Spot instances for task runners

Won't speed things up but significantly reduces cost (60-90% cheaper) for the same performance. Task runners are ephemeral and can tolerate interruption.

```hcl
resource "aws_spot_instance_request" "task_runner" {
  # ...
  spot_type = "one-time"
  wait_for_fulfillment = true
}
```

### 10. `--reuse-orchestrator` flag

For iterative benchmark development, keep orchestrator running between runs:

```fish
run.fish -c config.json --reuse-orchestrator
```

Only creates/destroys task runners. Orchestrator persists.

**Use case:** Running multiple benchmark configs in sequence, or debugging task runner issues.

### 11. Terraform state in S3

Local state files require sequential access. Remote state in S3 with DynamoDB locking would enable:
- Parallel runs from different machines
- Faster state operations (sometimes)

### 12. Terraform plugin cache

Enable `TF_PLUGIN_CACHE_DIR` to avoid re-downloading providers on every run (especially on fresh machines).

### 13. Use a Docker-preinstalled AMI

Use ECS-optimized or Bottlerocket AMIs for task runners so you skip Docker install/start in user-data.

---

## Summary: Recommended Implementation Order

1. **Batch terraform outputs** - Easy, immediate 6-12 second savings
2. **Parallel AWS terraform + orchestrator wait** - Medium effort, 2-3 minute savings
3. **Prebuild task runner image** - Medium effort, 1-2 minutes per instance
4. **Parallel runs per instance type (opt-in)** - Big savings if runs_per_instance_type > 1
5. **Pre-baked AMI / persistent base infra** - Higher effort, biggest overall savings
