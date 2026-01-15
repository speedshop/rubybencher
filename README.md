# A Cross-Cloud Ruby Benchmark

<img width="664" height="495" alt="Screenshot 2025-12-16 at 10 59 07" src="https://github.com/user-attachments/assets/f99bd8b9-d9fd-4a63-a057-0ecd91873ebf" />

This project runs Ruby benchmarks on different cloud providers. Use
it to find the fastest cloud instance for your Ruby apps.

Results are posted to [https://speedshop.co/rubybench](https://speedshop.co/rubybench).

## Why?

Cloud providers offer many instance types. These instance types can vary _significantly_ in single thread "straight line" performance. These instance types also vary quite a bit in cost: it may be worth it run a slower, older instance type if it's significantly cheaper.

This project is designed to help you answer a couple of different questions:

- **What instance type is the fastest on my chosen cloud?** And by how much?
- **How does my cloud stack up against others?** - Test AWS, Azure, and other clouds side by side
- **Is my instance type cost-performant?** - Is it worth upgrading or downgrading to slower or faster instances to get a big cost savings?

The tool runs [ruby-bench](https://github.com/ruby/ruby-bench) on each instance type. This is the official Ruby benchmark suite. It then creates an HTML report with charts and tables.

## How It Works

1. You create a config file listing which instance types to test
2. The tool spins up cloud instances via Terraform
3. Each instance runs the ruby-bench suite
4. Results upload to S3
5. The tool generates an HTML report comparing all results

## Requirements

- Ruby 3.4+
- Fish shell
- Terraform
- Docker
- `gum` (for pretty output)
- Cloud provider credentials (AWS, Azure)

## Quick Start

### Run Locally (for testing)

Test the system on your local machine using Docker:

```fish
./bench-new/master/run.fish -c bench-new/config/example.json --local-orchestrator
```

This runs benchmarks in a local Docker container. Use it to test before spinning up real cloud servers.

### Example: Run on AWS

Create a config file (see `bench-new/config/aws-full.json` for an example):

```json
{
  "ruby_version": "3.4.7",
  "runs_per_instance_type": 3,
  "aws": [
    {
      "instance_type": "c8g.medium",
      "alias": "c8g"
    },
    {
      "instance_type": "c7g.medium",
      "alias": "c7g"
    },
    {
      "instance_type": "c6g.medium",
      "alias": "c6g"
    }
  ]
}
```

Each instance is an object with `instance_type` (the cloud provider's instance type name) and `alias` (a short name used in results folders and reports).

You'll then need to provide environment variables to get your AWS credentials working. See the Terraform for more information.

Then run:

```fish
./bench-new/master/run.fish -c your-config.json
```

The tool creates all needed cloud resources. Results appear in the `results/` folder when done.

### Generate the Report

After a benchmark run completes:

```bash
ruby site/generate_report.rb
```

This creates `site/public/index.html` with your results.

## Resume Behavior (orchestrator.json + status/)

The master script writes `orchestrator.json` at the repo root and per-run status files under `status/<run_id>.json`:

- `--reuse-orchestrator` loads `orchestrator.json` and skips meta Terraform.
- `--resume-run <id|latest>` resumes an existing run; `latest` uses the newest status file.
- AWS/Azure task runners are only re-applied when Terraform state is missing or the stored run ID does not match.
- The config file must match the one recorded for the run when resuming.
- `orchestrator.json` and `status/` are ignored by git and removed by `bench-new/nuke/nuke.fish`.

## Configuration

The config file controls what gets benchmarked:

| Field | Description |
|-------|-------------|
| `ruby_version` | Ruby version to test (e.g., "3.4.7") |
| `runs_per_instance_type` | How many times to run benchmarks per instance |
| `aws` | Array of AWS instance objects |
| `azure` | Array of Azure instance objects |
| `local` | Array of local Docker instance objects |
| `task_runners.count` | Max task runners per instance (local defaults to 1; cloud defaults to vCPU count) |

Each instance object has:
- `instance_type`: The cloud provider's instance type name (or "docker" for local)
- `alias`: A short name used in results folders and reports

### Example: Multiple Providers

```json
{
  "ruby_version": "3.4.7",
  "runs_per_instance_type": 3,
  "aws": [
    { "instance_type": "c8g.medium", "alias": "c8g" },
    { "instance_type": "c7g.medium", "alias": "c7g" }
  ],
  "azure": [
    { "instance_type": "Standard_D2pls_v6", "alias": "d2pls-v6" },
    { "instance_type": "Standard_D2als_v6", "alias": "d2als-v6" }
  ]
}
```

### Key Components

**Master Script** (`bench-new/master/run.fish`)
The main entry point. It sets up infrastructure, starts the orchestrator, and collects results.

**Orchestrator** (`bench-new/orchestrator/`)
A Rails app that gives tasks to workers and tracks progress. Workers ask it for work and send back results.

**Task Runner** (`bench-new/task-runner/`)
Runs on each cloud instance. Claims tasks, runs benchmarks, and uploads results.

**Site Generator** (`site/generate_report.rb`)
Reads result files and creates an HTML report with charts.

## Output

Results land in `results/<run-id>/`. Each instance gets its own folder named `<alias>-<run-number>/` containing:

- `output.json` - Structured benchmark results
- `output.csv` - CSV format of results
- `output.txt` - Raw benchmark output
- `metadata.json` - Info about the run (provider, instance type, ruby version)

The HTML report shows:

- A summary table ranking instances by total time
- Charts showing individual benchmark times
- 95% confidence intervals for each measurement

## Cleanup

The master script cleans up infrastructure when done. If something goes wrong, run:

```fish
cd bench-new/nuke
./nuke.fish
```

This destroys all cloud resources created by the tool.

## Contributing

1. Fork this repo
2. Create a feature branch
3. Make your changes
4. If you changed the orchestrator, run the orchestrator's tests: `cd bench-new/orchestrator && bin/rails test`
5. Open a pull request
