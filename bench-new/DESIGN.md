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

These will all be contained in their respective directories:

- infrastructure
- master
- nuke
- orchestrator

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

See ./orchestrator/SPEC.md for more.

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
