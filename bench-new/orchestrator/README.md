# Rails Bencher Orchestrator

The orchestrator is a Ruby on Rails application that coordinates benchmark runs across multiple cloud providers and instance types.

## Features

- **Run Management**: Create and manage benchmark runs with configurable Ruby versions and instance types
- **Task Coordination**: Automatic task claiming and distribution to benchmark runners
- **Heartbeat Monitoring**: Automatic timeout detection for stale tasks (2 minute timeout)
- **HTML Dashboard**: Real-time monitoring dashboard with Turbo auto-refresh
- **S3 Integration**: Support for both AWS S3 and local filesystem storage
- **Result Aggregation**: Automatic gzip creation when all tasks complete
- **API Authentication**: Bearer token authentication for all API endpoints

## Requirements

- Ruby 3.4.7 (or compatible version)
- PostgreSQL 16 (via Docker)
- Docker and Docker Compose

## Setup

### 1. Start PostgreSQL

```bash
docker-compose up -d
```

### 2. Install Dependencies

```bash
bundle install
```

### 3. Setup Database

```bash
rails db:create db:migrate
```

### 4. Configure Environment Variables

Create a `.env` file (optional, defaults work for development):

```bash
# API Authentication
API_KEY=dev_api_key_change_in_production

# PostgreSQL (already configured in database.yml for development)
POSTGRES_HOST=localhost
POSTGRES_PORT=5432

# AWS S3 (optional, only needed in production)
AWS_REGION=us-east-1
AWS_ACCESS_KEY_ID=your_key
AWS_SECRET_ACCESS_KEY=your_secret
S3_BUCKET_NAME=railsbencher-results
```

## Running the Application

### Development Mode

Start the Rails server:

```bash
bin/dev
```

Or separately:

```bash
# Terminal 1: Rails server
rails server

# Terminal 2: Background jobs (Solid Queue)
bin/jobs
```

The application will be available at:
- Dashboard: http://localhost:3000
- API: http://localhost:3000/run, etc.

### Production Mode

```bash
RAILS_ENV=production rails assets:precompile
RAILS_ENV=production rails server
```

## API Endpoints

All API endpoints (except dashboard and GET /run) require Bearer token authentication:

```bash
Authorization: Bearer <API_KEY>
```

### POST /run/start

Create a new benchmark run.

**Request:**
```json
{
  "ruby_version": "3.4.7",
  "runs_per_instance_type": 3,
  "aws": ["c8g.medium", "c8g.large"],
  "azure": ["Standard_D2pls_v6"]
}
```

**Response (201):**
```json
{
  "run_id": 1733945123,
  "tasks_created": 9,
  "tasks": [
    {
      "id": 1,
      "provider": "aws",
      "instance_type": "c8g.medium",
      "run_number": 1,
      "status": "pending"
    }
  ]
}
```

**Errors:**
- 400: Invalid parameters or missing instance types
- 409: A run is already in progress

### GET /run

Get current run status (no authentication required).

**Response (200):**
```json
{
  "run_id": 1733945123,
  "status": "running",
  "ruby_version": "3.4.7",
  "runs_per_instance_type": 3,
  "tasks": {
    "total": 9,
    "pending": 3,
    "claimed": 2,
    "running": 2,
    "completed": 2,
    "failed": 0
  },
  "gzip_url": null
}
```

### POST /run/stop

Cancel the current run early.

**Response (200):**
```json
{
  "message": "Run cancelled successfully"
}
```

### POST /tasks/claim

Task runner claims a task to execute.

**Request:**
```json
{
  "provider": "aws",
  "instance_type": "c8g.medium",
  "runner_id": "i-0abc123def456"
}
```

**Responses:**

Assigned (200):
```json
{
  "status": "assigned",
  "task": {
    "id": 1,
    "provider": "aws",
    "instance_type": "c8g.medium",
    "run_number": 1,
    "ruby_version": "3.4.7"
  },
  "presigned_urls": {
    "result_upload_url": "...",
    "error_upload_url": "...",
    "result_key": "results/123/task_1_result.tar.gz",
    "error_key": "results/123/task_1_error.tar.gz"
  }
}
```

Wait (200):
```json
{
  "status": "wait",
  "retry_after_seconds": 30
}
```

Done (200):
```json
{
  "status": "done"
}
```

### POST /tasks/:id/heartbeat

Report task progress.

**Request:**
```json
{
  "runner_id": "i-0abc123def456",
  "status": "running",
  "current_benchmark": "optcarrot",
  "progress_pct": 45,
  "message": "Running benchmark suite"
}
```

**Valid status values:**
- `boot`: Instance is booting
- `provision`: Provisioning environment
- `running`: Running benchmarks
- `uploading`: Uploading results
- `finished`: Task completed
- `error`: Error occurred

### POST /tasks/:id/complete

Mark task as completed.

**Request:**
```json
{
  "runner_id": "i-0abc123def456",
  "s3_result_key": "results/123/task_1_result.tar.gz"
}
```

### POST /tasks/:id/fail

Mark task as failed.

**Request:**
```json
{
  "runner_id": "i-0abc123def456",
  "error_type": "benchmark_error",
  "error_message": "Benchmark suite failed to execute",
  "s3_error_key": "results/123/task_1_error.tar.gz"
}
```

## Storage

The orchestrator supports two storage backends:

### Local Storage (Development/Test)

Files are stored in `tmp/storage/` directory. Presigned URLs are local file paths.

### S3 Storage (Production)

Configured via environment variables:
- `AWS_REGION`
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `S3_BUCKET_NAME`

The storage service automatically switches based on environment and AWS configuration.

## Background Jobs

### Heartbeat Monitor

Runs every minute to check for stale tasks. Any task in `claimed` or `running` status without a heartbeat for 2 minutes is automatically marked as failed.

### Gzip Builder

Triggered automatically when all tasks in a run complete. Collects all result files and creates a combined gzip archive.

## Testing

Run the test suite:

```bash
rails test
```

All 33 tests cover:
- Model validations and business logic
- API endpoint functionality
- Authentication
- Task claiming with race conditions
- Heartbeat monitoring
- Error handling

## Database Schema

### runs
- `id`: Primary key
- `ruby_version`: Ruby version for the run
- `runs_per_instance_type`: How many times to run each instance type
- `status`: running, completed, cancelled
- `external_id`: Unix timestamp used as external run_id
- `gzip_url`: URL to download combined results
- `created_at`, `updated_at`

### tasks
- `id`: Primary key
- `run_id`: Foreign key to runs
- `provider`: aws, azure, etc.
- `instance_type`: Instance type identifier
- `run_number`: Which iteration (1 to N)
- `status`: pending, claimed, running, completed, failed
- `runner_id`: ID of the runner that claimed the task
- `claimed_at`: When task was claimed
- `heartbeat_at`: Last heartbeat timestamp
- `heartbeat_status`: Current heartbeat status
- `heartbeat_message`: Progress message
- `current_benchmark`: Current benchmark being run
- `progress_pct`: Completion percentage (0-100)
- `s3_result_key`: S3 key for results
- `s3_error_key`: S3 key for error logs
- `error_type`: Type of error if failed
- `error_message`: Error details if failed
- `created_at`, `updated_at`

## Architecture Notes

### Optimistic Locking for Task Claims

Task claiming uses database row-level locking to prevent race conditions when multiple runners try to claim the same task:

```ruby
Task.lock.where(status: 'pending').first
```

### Heartbeat Timeout

The `HeartbeatMonitorJob` runs every minute and marks tasks as failed if they haven't sent a heartbeat in 2 minutes. This ensures stuck runners don't block progress.

### Run Completion Detection

When a task is completed or failed, the system checks if all tasks are done. If so, it triggers the `GzipBuilderJob` to aggregate results and mark the run as completed.

## Development Tips

### Viewing Logs

```bash
# Rails logs
tail -f log/development.log

# Background job logs
# Jobs output to the same log file
```

### Database Console

```bash
rails dbconsole
```

### Rails Console

```bash
rails console
```

### Resetting Database

```bash
rails db:reset
```

## Deployment

The application includes:
- Dockerfile for containerized deployment
- Kamal configuration for deployment
- GitHub Actions CI workflow

For production deployment, ensure:
1. Set `ORCHESTRATOR_DATABASE_PASSWORD` environment variable
2. Configure AWS credentials for S3 storage
3. Set a secure `API_KEY`
4. Run migrations: `rails db:migrate`
5. Precompile assets: `rails assets:precompile`

## License

See main project LICENSE file.
