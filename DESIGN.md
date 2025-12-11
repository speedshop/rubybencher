# Ruby Cross Cloud Benchmark

This repository contains a system for running the ruby-bench benchmark suite across multiple public clouds, and display the results in an HTML website.

Key components include:

1. The benchmark runner, in the bench folder. It creates infrastructure, runs the benchmarks, and produces an output gzip which contains the benchmark results.
2. The benchmark site builder. It consumes these benchmark results and uses them to create an HTML website.

## Contract: Runner → Site Builder

What is the benchmark runner trying to produce? A single gzip file which contains the following:

- `<instance-identifier>-<task-id>/output.txt`, which contains the output from ruby-bench. task-id increments from 1, where each id represents a single run of ruby-bench on a particular instance type.

The benchmark runner is responsible for placing this in the `results/<run-id>` directory.

## Runner: Architecture

The runner has several sub-parts:

1. A **master script**, which starts the benchmark, receives a final gzip from the orchestrator service and places it in the results directory.
2. A web **orchestrator service**, using Ruby and Postgres.
3. Infrastructure, provisioned by Terraform.
4. A **nuke script**, which runs terraform destroy and _also_ manually runs a command which deletes all infrastructure on the provider using that provider's CLI.


### Master Script

The master script will:

1. Decide on a run-id. The run-id will be the current timestamp in seconds since the unix epoch.
2. Pick up the instance type configuration from a config file
3. Stand up the infrastructure required for the run with Terraform, including bastion and orchestrator
4. Send the instance type configuration from the config file to the orchestrator as a POST.
5. Wait until the orchestrator's results endpoint returns a GZIP link
6. Download that gzip and unzip it into the results directory

It will be written in Fish.

#### Instance type config

A run can have 1 or many instance types across 1 or many providers.

Example:

```json
{
  "ruby_version": "3.4.7",
  "runs_per_instance_type": 3,
  "aws": [
    // These correspond to the actual names used in the provider's API
    "c8g.medium",
    "c7g.medium",
    "c6g.medium",
    "c8a.medium",
    "c7a.medium",
    "c8i.large",
    "c7i.large"
  ],
  "azure": [
    "Standard_D2pls_v6",
    "Standard_D2als_v6",
    "Standard_D2ls_v6",
    "Standard_F2als_v6"
  ]
}
```

There will also be a local provider, which just runs the benchmark on a local Docker instance. This will be used for testing and development, and it's the provider we'll implement first.

This config would correspond to the following tasks being created:

```json
[
  {"provider": "aws", "instance_type": "c8g.medium", "run": 1},
  {"provider": "aws", "instance_type": "c8g.medium", "run": 2},
  {"provider": "aws", "instance_type": "c8g.medium", "run": 3},
  {"provider": "aws", "instance_type": "c7g.medium", "run": 1},
  {"provider": "aws", "instance_type": "c7g.medium", "run": 2},
  {"provider": "aws", "instance_type": "c7g.medium", "run": 3},
  {"provider": "aws", "instance_type": "c6g.medium", "run": 1},
  {"provider": "aws", "instance_type": "c6g.medium", "run": 2},
  {"provider": "aws", "instance_type": "c6g.medium", "run": 3},
  {"provider": "aws", "instance_type": "c8a.medium", "run": 1},
  {"provider": "aws", "instance_type": "c8a.medium", "run": 2},
  {"provider": "aws", "instance_type": "c8a.medium", "run": 3},
  {"provider": "aws", "instance_type": "c7a.medium", "run": 1},
  {"provider": "aws", "instance_type": "c7a.medium", "run": 2},
  {"provider": "aws", "instance_type": "c7a.medium", "run": 3},
  {"provider": "aws", "instance_type": "c8i.large", "run": 1},
  {"provider": "aws", "instance_type": "c8i.large", "run": 2},
  {"provider": "aws", "instance_type": "c8i.large", "run": 3},
  {"provider": "aws", "instance_type": "c7i.large", "run": 1},
  {"provider": "aws", "instance_type": "c7i.large", "run": 2},
  {"provider": "aws", "instance_type": "c7i.large", "run": 3},
  {"provider": "azure", "instance_type": "Standard_D2pls_v6", "run": 1},
  {"provider": "azure", "instance_type": "Standard_D2pls_v6", "run": 2},
  {"provider": "azure", "instance_type": "Standard_D2pls_v6", "run": 3},
  {"provider": "azure", "instance_type": "Standard_D2als_v6", "run": 1},
  {"provider": "azure", "instance_type": "Standard_D2als_v6", "run": 2},
  {"provider": "azure", "instance_type": "Standard_D2als_v6", "run": 3},
  {"provider": "azure", "instance_type": "Standard_D2ls_v6", "run": 1},
  {"provider": "azure", "instance_type": "Standard_D2ls_v6", "run": 2},
  {"provider": "azure", "instance_type": "Standard_D2ls_v6", "run": 3},
  {"provider": "azure", "instance_type": "Standard_F2als_v6", "run": 1},
  {"provider": "azure", "instance_type": "Standard_F2als_v6", "run": 2},
  {"provider": "azure", "instance_type": "Standard_F2als_v6", "run": 3}
]
```

### Orchestrator (Ruby HTTP service + Postgres)

The orchestrator has a few roles:

1. Display an HTML interface to humans to allow them to monitor the status of the run and take actions.
2. Coordinate with benchmark runner instances to claim tasks, receive heartbeats, receive benchmark results, error logs.
3. Gzip all results when done.

It will use Postgres for all data, in a container on the orchestrator host.

It will use Ruby on Rails.

It will have it's own test suite using Minitest.

Task claims (see later for more details) will be resolved with optimistic database locking. Note that task runners can only fulfill tasks which match their provider and instance type.

The orchestrator will also automatically mark tasks as failed if the heartbeat fails to report.

The orchestrator has a button to "end a run early", which causes the final gzip file to be created before all tasks have finished, and causes all tasks not yet in progress/claimed to be deleted.

#### Orchestrator API Specification

##### Authentication

All API endpoints (except the HTML dashboard) require an `Authorization: Bearer <API_KEY>` header. The API key is generated by Terraform and provided to task runners via userdata/cloud-init.

##### Endpoints

###### POST `/run/start`

**Purpose**: Receive instance type configuration from master script and create tasks. Creates a "run".

**Request Body**:
```json
{
  "ruby_version": "3.4.7",
  "runs_per_instance_type": 3,
  "aws": ["c8g.medium", "c7g.medium"],
  "azure": ["Standard_D2pls_v6"]
}
```

**Response** (201 Created):
```json
{
  "run_id": 1733945123,
  "tasks_created": 9,
  "tasks": [
    {"id": 1, "provider": "aws", "instance_type": "c8g.medium", "run": 1, "status": "pending"},
    {"id": 2, "provider": "aws", "instance_type": "c8g.medium", "run": 2, "status": "pending"}
  ]
}
```

**Errors**:
- 400: Invalid params (missing ruby_version, empty provider arrays, etc.)
- 409: A run is already in progress

###### POST `/tasks/claim`

**Purpose**: Task runner requests a task matching its provider/instance_type.

**Request Body**:
```json
{
  "provider": "aws",
  "instance_type": "c8g.medium",
  "runner_id": "i-0abc123def456"
}
```

**Response** (200 OK - task assigned):
```json
{
  "status": "assigned",
  "task": {
    "id": 42,
    "provider": "aws",
    "instance_type": "c8g.medium",
    "run": 2,
    "ruby_version": "3.4.7"
  },
  "presigned_urls": {
    "result": "https://s3.amazonaws.com/bucket/results/42/result.tar.gz?X-Amz-...",
    "error": "https://s3.amazonaws.com/bucket/results/42/error.tar.gz?X-Amz-..."
  }
}
```

**Response** (200 OK - no tasks available, but run not complete):
```json
{
  "status": "wait",
  "retry_after_seconds": 30
}
```

**Response** (200 OK - run complete, no more tasks):
```json
{
  "status": "done"
}
```

**Errors**:
- 400: Missing provider or instance_type
- 404: No run in progress

**Notes**: Uses optimistic locking - if two runners claim simultaneously, one gets the task, the other gets `wait` or another task.

###### POST `/tasks/:id/heartbeat`

**Purpose**: Task runner reports progress on a claimed task.

**Request Body**:
```json
{
  "runner_id": "i-0abc123def456",
  "status": "running",
  "current_benchmark": "optcarrot",
  "progress_pct": 45,
  "message": "Running optcarrot benchmark"
}
```

**Valid `status` values**:
- `boot` - Instance started, task runner initializing
- `provision` - Pulling docker image, setting up environment
- `running` - Benchmark in progress
- `uploading` - Uploading results to S3
- `finished` - Complete (use `/complete` instead)
- `error` - Failed (use `/fail` instead)

**Response** (200 OK):
```json
No response body
```

**Errors**:
- 400: Missing task_id or status
- 404: Task not found
- 409: Task not claimed by this runner (runner_id mismatch)

###### POST `/tasks/:id/complete`

**Purpose**: Task runner marks a task as successfully completed.

**Request Body**:
```json
{
  "runner_id": "i-0abc123def456",
  "s3_result_key": "results/42/result.tar.gz",
}
```

**Response** (200 OK):
```
No response body
```

**Errors**:
- 400: Missing required fields
- 404: Task not found
- 409: Task not claimed by this runner

###### POST `/tasks/:id/fail`

**Purpose**: Task runner marks a task as failed. Failed tasks are not automatically retried.

**Request Body**:
```json
{
  "runner_id": "i-0abc123def456",
  "error_type": "benchmark_crash",
  "error_message": "Segmentation fault in optcarrot",
  "s3_error_key": "results/42/error.tar.gz",
  "debug_mode": false
}
```

**Response** (200 OK):
```json
No response body
```

**Errors**:
- 400: Missing required fields
- 404: Task not found
- 409: Task not claimed by this runner

###### GET `/run`

**Purpose**: Get current run status (used by master script polling). Returns result gzip URL when run is complete.

**Response** (200 OK - run in progress):
```json
{
  "run_id": 1733945123,
  "status": "running",
  "ruby_version": "3.4.7",
  "created_at": "2024-12-11T10:30:00Z",
  "tasks": {
    "total": 33,
    "pending": 12,
    "claimed": 3,
    "completed": 15,
    "failed": 3
  },
  "gzip_url": null
}
```

**Response** (200 OK - run complete):
```json
{
  "run_id": 1733945123,
  "status": "complete",
  "ruby_version": "3.4.7",
  "created_at": "2024-12-11T10:30:00Z",
  "completed_at": "2024-12-11T14:45:00Z",
  "tasks": {
    "total": 33,
    "pending": 0,
    "claimed": 0,
    "completed": 30,
    "failed": 3
  },
  "gzip_url": "https://s3.amazonaws.com/bucket/runs/1733945123/results.tar.gz?X-Amz-..."
}
```

**Response** (404 - no run):
```json
No response body
```

###### POST `/run/stop`

**Purpose**: End the run early (from dashboard button). Creates gzip from completed results, deletes unclaimed tasks.

**Request Body**:
```json
None
```

**Response** (200 OK):
```json
None
```

**Errors**:
- 404: No run in progress

###### GET `/` (HTML Dashboard)

**Purpose**: Human-readable dashboard showing run status.

**Response**: HTML page displaying:
- Current run status (idle/running/complete)
- Task summary counts by status
- Task breakdown by provider/instance_type
- Live task list with heartbeat status
- "End Run Early" button
- Link to download final gzip (when complete)

Uses Turbo and Hotwire for a frontend framework.

##### Background Jobs

###### Heartbeat Timeout Checker

- Runs every 60 seconds
- Marks tasks as `failed` if no heartbeat received in 2 minutes
- Failed tasks are not re-queued (no automatic retries)

###### Gzip Builder

- Triggered when all tasks are `completed` or `failed`
- Downloads all `result.tar.gz` files from S3
- Repackages into single `results.tar.gz` with structure: `<instance_type>-<run>/output.txt`
- Uploads to S3 and updates run status with `gzip_url`

### Task Runner (and Task Structure)

At an abstract level:

1. The orchestrator receives an instance type config from the master script via POST.
2. The orchestrator turns this into a task list, each task representing one run of the ruby-bench benchmark which is complete when we have an output.txt for that task uploaded to S3.
3. When they come online, task runners (see Infrastructure) poll the orchestrator to claim tasks.
4. The orchestrator receives heartbeats/progress updates as the tasks are completing.
5. The tasks are completed when the orchestrator receives an output.txt for that task.

Task runners should have an integration test that runs locally/not on a provider but on our local docker host.

#### Architecture

Task runners are docker hosts which run the ruby-bench script (see https://github.com/ruby/ruby-bench) from inside a docker container running the official ruby image of the version specified in the config.

They start up and start polling /claim to try to get a task. If they receive no response from the orchestrator, they will keep trying for up to 10 minutes.

The orchestrator can also send a "done" response in response to a /claim POST, which means there are no further tasks for the task runner to complete. The task runner then exits and the instance shuts down.

#### Task Runner Flow
1) `/claim` with provider/instance_key → get task + presigned URLs (result/error).
2) Heartbeat loop (`boot/provision/running/uploading/finished/error`) every 30s to `/heartbeat`. Include which benchmark is being run at the current time if running status.
3) Run benchmark container; capture logs/meta.
4) Upload `result.tar.gz` or `error.tar.gz` to S3 via presigned url.
5) `/complete` or `/fail` with meta/error; if debug flag + failure, skip shutdown.
6) `claim` again and loop. Shutdown possible if orchestrator says no more tasks.


### Infra (Terraform)

There are two types of terraform infra:

1. Meta infra. This contains the orchestrator, an SSH bastion host for sshing into all the instances we stand up in the per-provider step, and all services needed to support the orchestrator (Postgres, S3 for result storage). Terraform outputs here would be the publicly accessible URL of the orchestrator, an API key for the task runners to use, and presigned URLs for result and error uploads. We will create new buckets each time.
2. Per-provider infra. This includes vpc/nat, task runners (instances with docker running).

When the master script stands up infra, it stands up the meta infra first, and then the per-provider infra can all be stood up in parallel.

Other than task runners self-terminating when told so by `/claim`, all other infra stays online until destroyed by the nuke script.

#### Per-Provider Distinction: docker containers per host

We want to run 1 docker container per available CPU on the host. For Azure, for example, we should run 2 containers on `D2` and `F2` type instances. For aws, we should only run 1 container on a `c6g.medium` but 2 containers on a `c7i.large`. These containers will run in parallel and thus claim separate tasks.
