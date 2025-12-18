# Rails Bencher Orchestrator

The orchestrator is a Rails app that runs Ruby benchmarks on cloud servers. It sends work to benchmark runners on AWS and Azure. It collects and combines the results.

## Why Use This?

Ruby benchmarks need to run on the same hardware each time. Cloud servers give you that. But running benchmarks on many servers is hard to manage by hand. The orchestrator does this work for you.

When you start a benchmark run:
1. The orchestrator creates tasks for each server type
2. Runner scripts claim tasks and do the work
3. Runners send progress updates (heartbeats)
4. Results upload to S3
5. The orchestrator combines all results into one file

## Requirements

- Ruby 3.4.7
- Docker and Docker Compose
- PostgreSQL 16 (runs in Docker)

## Quick Start

### 1. Start the Services

```bash
docker compose up -d
```

This starts PostgreSQL and MinIO (S3-compatible storage for development).

### 2. Set Up the Database

```bash
bin/rails db:create db:migrate
```

### 3. Start the App

```bash
bin/dev
```

The app runs at:
- **Dashboard**: http://localhost:3000
- **API**: http://localhost:3000/runs

## Configuration

Create a `.env` file to change settings. All settings have defaults that work for development.

### Required for Production

| Variable | Description |
|----------|-------------|
| `API_KEY` | Secret key for API access |
| `AWS_ACCESS_KEY_ID` | AWS credentials |
| `AWS_SECRET_ACCESS_KEY` | AWS credentials |
| `AWS_REGION` | AWS region (default: us-east-1) |
| `S3_BUCKET_NAME` | Bucket for benchmark results |

### Optional Settings

| Variable | Description |
|----------|-------------|
| `S3_ENDPOINT` | Custom S3 endpoint (for MinIO) |
| `S3_UPLOAD_ENDPOINT` | Endpoint for uploads from Docker |
| `S3_DOWNLOAD_ENDPOINT` | Endpoint for downloads to host |

## API Reference

All API endpoints return JSON. Most require a Bearer token in the Authorization header.

### Runs

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/runs` | No | List all runs |
| POST | `/runs` | Yes | Create a new run |
| GET | `/runs/:id` | No | Get run status |
| POST | `/runs/:id/stop` | Yes | Cancel a run |

#### Create a Run

```bash
curl -X POST http://localhost:3000/runs \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "ruby_version": "3.4.1",
    "runs_per_instance_type": 3,
    "aws": ["c7g.medium", "c7g.large"],
    "azure": ["Standard_D2pls_v6"]
  }'
```

### Tasks

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/runs/:run_id/tasks` | No | List tasks for a run |
| POST | `/runs/:run_id/tasks/claim` | Yes | Claim a task |
| POST | `/tasks/:id/heartbeat` | Yes | Send progress update |
| POST | `/tasks/:id/complete` | Yes | Mark task done |
| POST | `/tasks/:id/fail` | Yes | Mark task failed |

## Task Lifecycle

Tasks move through these states:

```
pending → claimed → running → completed
                          ↘ failed
                          ↘ cancelled
```

- **pending**: Waiting for a runner to claim it
- **claimed**: A runner took the task
- **running**: The benchmark is in progress
- **completed**: The benchmark finished
- **failed**: Something went wrong
- **cancelled**: The run was stopped early

> [!IMPORTANT]
> Runners must send heartbeats every 2 minutes. Tasks without heartbeats are marked as failed.

## Running in Production

### With Docker Compose

```bash
docker compose -f docker-compose.production.yml up -d
```

### Without Docker

```bash
RAILS_ENV=production bin/rails assets:precompile
RAILS_ENV=production bin/rails server
```

Start the background worker in a separate process:

```bash
RAILS_ENV=production bin/jobs
```

## Directory Structure

| Path | Description |
|------|-------------|
| `app/controllers/` | API and dashboard controllers |
| `app/models/` | Run and Task models |
| `app/jobs/` | Background jobs (heartbeat monitor, gzip builder) |
| `app/services/` | S3 storage service |
| `app/views/` | Dashboard HTML and API JSON templates |
| `config/` | Rails configuration |
| `db/` | Database schema and migrations |

## Development

### Run Tests

```bash
docker compose up -d postgres
bin/rails test
```

## License

See the main Rails Bencher repository for license information.
