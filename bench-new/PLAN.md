# Implementation Plan

This plan breaks the Ruby Cross Cloud Benchmark system into 4 phases, each handled by a sub-agent. We start with the `local` provider only, then add AWS support afterward.

## Phase 1: Orchestrator (Ruby on Rails + Postgres)

**Goal**: Build the central coordination service that manages tasks and results.

### Steps

1. Create Rails app in `orchestrator/` directory
   - Use `rails new orchestrator --database=postgresql`
   - Configure for containerized Postgres. Use containerized postgres in dev/test as well as production.

2. Create database schema
   - `tasks` table: id, provider, instance_type, run_number, status enum (pending/claimed/running/completed/failed), claimed_at, heartbeat_at, error_message
   - `runs` table: id, ruby_version, runs_per_instance_type, status (running/completed/cancelled), created_at, external_id (used by collaborators, format is a unix timestamp in seconds)

3. Implement API endpoints (see orchestrator/SPEC.md)

4. Implement task claiming with optimistic locking
   - Tasks matched by provider + instance_type
   - Return "done" when no more tasks for that provider/instance_type

5. Implement heartbeat timeout detection
   - Background job to mark tasks as failed if no heartbeat for 2 minutes

6. Implement HTML dashboard
   - Show all tasks grouped by instance type
   - Show status, last heartbeat, current benchmark
   - "End run early" button - deletes pending tasks, triggers gzip creation

7. Implement result gzipping
   - Collect all result files from S3
   - Create gzip with structure: `<instance-identifier>-<task-id>/output.txt`
   - Upload to S3, return presigned URL
   - Use a mock for testing this locally

8. Add S3 integration for presigned URLs
   - Generate presigned upload URLs for result.tar.gz and error.tar.gz
   - Return these URLs in `/claim` response

9. Write tests
   - Unit tests for task claiming logic
   - Integration tests for full claim/heartbeat/complete flow

### Local Provider Considerations
- For local provider, S3 will be mocked with local filesystem storage
- Presigned URLs become local file paths

---

## Phase 2: Task Runner

**Goal**: Build the script that runs on instances to execute benchmarks and report results.

### Steps

1. Create task runner script in `task-runner/` directory
   - Shell script (fish) that orchestrates the process

2. Implement orchestrator communication
   - Poll `/claim` with provider and instance_type
   - Retry for up to 10 minutes if no response
   - Handle "done" response (exit/shutdown)

3. Implement heartbeat loop
   - Send heartbeat every 30 seconds
   - Report status: boot → provision → running → uploading → finished/error
   - Include current benchmark name when running

4. Implement benchmark execution
   - Pull official Ruby docker image for specified version
   - Run ruby-bench inside container
   - Capture output to output.txt

5. Implement result upload
   - Create result.tar.gz with output.txt and metadata
   - Upload via presigned URL
   - Call `/complete` endpoint

6. Implement error handling
   - On failure, create error.tar.gz with logs
   - Upload via presigned error URL
   - Call `/fail` endpoint
   - If debug flag set, don't shutdown on failure

7. Implement task loop
   - After completing a task, call `/claim` again
   - Continue until "done" response or shutdown

8. Determine container count
   - Read instance type to determine CPU count
   - Spawn N containers in parallel, each claiming separate tasks

9. Write integration test
   - Test full flow against local orchestrator
   - Use local provider (docker on local machine)

### Local Provider Implementation
- Runs directly on local docker daemon
- No instance provisioning needed
- Single container for testing

---

## Phase 2a: test with local task runner

At this point, we should be able to start doing an integration test between a locally running orchestrator and a local running task runner. Try it.

---

## Phase 3: Infrastructure (Terraform)

**Goal**: Define infrastructure for orchestrator and task runners.

### Steps

1. Create `infrastructure/` directory structure
   - `meta/` - orchestrator, bastion, S3, networking
   - `providers/local/` - local provider config (minimal)
   - `providers/aws/` - AWS provider config (later)

2. Meta infrastructure (`infrastructure/meta/`)
   - VPC with public subnet for orchestrator
   - EC2 instance for orchestrator (runs docker-compose with Rails + Postgres)
   - S3 bucket for results
   - Security groups (allow HTTP to orchestrator, SSH via bastion)
   - SSH bastion host
   - Outputs: orchestrator URL, API key, S3 bucket name

3. Local provider infrastructure (`infrastructure/providers/local/`)
   - Minimal config - just validates local docker is available
   - No cloud resources needed
   - Assume that the docker host is running, dont need to create. Just create the container.
   - Outputs: confirmation that local docker is ready

4. Create docker-compose for orchestrator
   - Rails app container
   - Postgres container
   - Nginx container (optional, for SSL later)

5. Create provisioning scripts
   - User data script for orchestrator instance
   - Install docker, docker-compose
   - Pull and start orchestrator containers

6. Write terraform outputs
   - Orchestrator public URL
   - API key for authentication
   - SSH key path for bastion

### Local Provider Focus
- Phase 3 starts with local only
- Provider infra runs locally via docker-compose (no EC2)
- At the end of this phase, we should be able to run the orchestrator live in AWS with a local docker task runner and have it complete successfully.

---

## Phase 4: Master Script + Nuke Script

**Goal**: Build the entry point that orchestrates the entire benchmark run.

### Steps

1. Create master script in `master/run.fish`
   - Parse command line arguments (config file path, provider filter)

2. Implement run ID generation
   - Use current unix timestamp

3. Implement config file parsing
   - Read JSON config with instance types per provider.
   - Config files live in a config directory (bench-new/config)
   - Only start infra for a provider if it was requested in the config

4. Implement infrastructure standup
   - Run terraform for meta infrastructure
   - Capture outputs (orchestrator URL, API key)
   - Run terraform for each provider (as needed) in parallel

5. Implement orchestrator initialization
   - POST instance type config to `/run`
   - Wait for 200 response

6. Implement status polling
   - Poll `/run/:id` endpoint
   - Display progress to terminal using gum
   - Show which instances are running, completed, failed

7. Implement result retrieval
   - When `/run/:id` returns complete, get gzip URL
   - Download and extract to `results/<run-id>/`

8. Create nuke script in `nuke/nuke.fish`
   - Run `terraform destroy` for all provider infra
   - Run `terraform destroy` for meta infra
   - Run provider CLI commands to ensure all resources deleted
     - AWS: `aws ec2 describe-instances` + terminate any stragglers
     - Azure: similar cleanup
   - Use gum for confirmation prompts

9. Add cleanup on interrupt
   - Trap SIGINT in master script
   - Offer to run nuke script (gum confirm)

### Local Provider Focus
- Master script starts with local provider only
- No terraform needed for local - just docker-compose up
- Nuke is just docker-compose down

---

## Implementation Order

```
1. Orchestrator (Phase 1)
   └── Get Rails app running with all endpoints
   └── Test with curl/httpie locally

2. Task Runner (Phase 2)
   └── Build against running orchestrator
   └── Test full loop locally

3. Infrastructure - Local Only (Phase 3)
   └── docker-compose for orchestrator
   └── Local task runner integration

4. Master + Nuke Scripts (Phase 4)
   └── Wire everything together
   └── Full local end-to-end test

5. [Future] AWS Provider
   └── Add AWS terraform configs
   └── Add AWS instance type detection
   └── Test on actual EC2 instances
```

---

## Directory Structure

```
bench-new/
├── DESIGN.md
├── PLAN.md
├── config/
│   └── example.json          # Example instance type config
├── infrastructure/
│   ├── meta/                  # Orchestrator infra
│   ├── providers/local/                 # Local provider (docker)
│   └── providers/aws/                   # AWS provider (future)
├── master/
│   └── run.fish               # Main entry point
├── nuke/
│   └── nuke.fish              # Cleanup script
├── orchestrator/
│   ├── SPEC.md                # Detailed API spec
│   └── [rails app]
├── task-runner/
│   ├── run.fish               # Task runner script
│   └── Dockerfile             # For running ruby-bench
└── results/                   # Output directory
    └── <run-id>/
        └── <instance>-<task>/
            └── output.txt
```

---

## Sub-Agent Assignments

| Component | Sub-Agent Focus |
|-----------|-----------------|
| **Orchestrator** | Rails app, API endpoints, database, HTML dashboard, tests |
| **Task Runner** | Fish scripts, docker integration, orchestrator communication |
| **Infrastructure** | Terraform configs, docker-compose, local provider setup |
| **Master/Nuke** | Fish scripts, terraform orchestration, gum UI |

Each sub-agent can work semi-independently once the API contract (defined in orchestrator SPEC.md) is established.
