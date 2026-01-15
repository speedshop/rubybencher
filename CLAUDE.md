# Ruby Bencher

Distributed benchmarking system that runs Ruby benchmarks across arbitrary public clouds, as well as local Docker, to find the fastest and most cost-effective cloud instances for Ruby apps. Results published to https://speedshop.co/rubybench

## Architecture

- **Master** (`bench-new/master/run.fish`): Entry point. Provisions infra via Terraform, starts orchestrator, polls for completion, downloads results.
- **Orchestrator** (`bench-new/orchestrator/`): Rails 8.1 app. Creates/tracks tasks, serves claims to workers, collects results, provides dashboard.
- **Task Runner** (`bench-new/task-runner/`): Docker container on each cloud instance. Claims tasks, runs ruby-bench, uploads results to S3.
- **Site Generator** (`site/generate_report.rb`): Generates HTML report from results.

## Running Benchmarks

```fish
# Full run
./bench-new/master/run.fish -c bench-new/config/aws-full.json

# Local testing with mock benchmarks
./bench-new/master/run.fish -c bench-new/config/example.json --local-orchestrator --mock
```

Key flags: `-c CONFIG` (required), `--local-orchestrator`, `--skip-infra`, `--mock`, `--debug`

## Resume Behavior (status.json)

The master script writes `status.json` at the repo root and uses it to resume runs:

- If `status.json` exists and the orchestrator is reachable, meta Terraform is skipped.
- If the previous run is still `running`, the master resumes it instead of creating a new run.
- AWS/Azure task runners are only re-applied when Terraform state is missing or the stored run ID does not match.
- The current config file must match the one recorded in `status.json` (path + hash), or the run aborts.
- `status.json` is ignored by git and removed by `bench-new/nuke/nuke.fish`.

## Development

```fish
# Orchestrator
cd bench-new/orchestrator
docker compose up -d
bin/rails db:create db:migrate
bin/dev

# Task runner tests
cd bench-new/task-runner && bundle exec rake test

# Generate report
ruby site/generate_report.rb
```

## Infrastructure

- `bench-new/infrastructure/meta/`: Terraform for orchestrator, bastion, S3, VPC
- `bench-new/infrastructure/aws/`: Terraform for EC2 instances
- Cleanup: `./bench-new/nuke/nuke.fish`

## Config

- `fnox.toml`: Secrets via 1Password (AWS, Azure, Cloudflare creds)
- `mise.toml`: Tool versions (Ruby 3.4, Terraform 1.9)
- `bench-new/config/*.json`: Benchmark configurations

## Secrets (fnox + 1Password)

Secrets are managed with `fnox` (backed by 1Password):

- 1Password item: `rubybencher` in the `Private` vault (see `fnox.toml`)
- `mise.toml` manages tools only (no automatic secret loading)
- `fnox list` shows keys + sources, not values (by design)

**Important**: `mise` handles tool versions. `fnox exec` loads secrets. Never use `mise exec` - it's not needed.

```fish
# List configured secrets (no values shown)
fnox list

# Verify a secret can be fetched
fnox get ARM_SUBSCRIPTION_ID

# Run anything that needs secrets
fnox exec ./bench-new/master/run.fish -c bench-new/config/aws-full.json
fnox exec terraform plan
```

When adding new secrets, update the `rubybencher` 1Password item first, then reference it in `fnox.toml`. Never commit raw secrets.

## Testing

- Orchestrator: `cd bench-new/orchestrator && bin/rails test`
- Task runner: `cd bench-new/task-runner && bundle exec rake test`
