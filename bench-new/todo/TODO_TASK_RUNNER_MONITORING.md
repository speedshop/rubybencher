# Task Runner Monitoring

Design for showing task runner status on the orchestrator UI.

## Problem

Task runners are "fire and forget" - launched via EC2 user-data, and the orchestrator has no visibility into:
- Whether runners have started successfully
- Whether they're healthy or crashed
- Why tasks aren't being claimed

## Solution: Expected Runners + Heartbeat System

### Key Design Decisions

1. **Pre-populate expected runners from config** - Don't wait for heartbeats. When a run is created, immediately create TaskRunner records in `pending` state based on the config.

2. **Early heartbeat via curl in user-data** - Before the task runner app even starts, send a heartbeat from user-data to confirm the instance is alive. This catches boot failures early.

3. **60-second stale threshold** - Generous enough to handle transient network issues.

---

## Task Runner States

```
PENDING   → Expected but no heartbeat received yet (created from config)
STARTING  → First heartbeat received, runner is initializing
READY     → Idle, ready to claim tasks
BUSY      → Executing a task
ERROR     → Encountered an error (with message)
STALE     → No heartbeat in 60s (presumed dead)
SHUTDOWN  → Gracefully stopped
```

State transitions:
```
[Run Created] → PENDING
PENDING → STARTING (first heartbeat)
PENDING → STALE (no heartbeat after 60s)
STARTING → READY (runner reports ready)
READY → BUSY (task claimed)
BUSY → READY (task completed)
READY/BUSY → ERROR (runner reports error)
READY/BUSY → STALE (no heartbeat in 60s)
READY → SHUTDOWN (graceful exit)
```

---

## Database Schema

```ruby
create_table :task_runners do |t|
  t.string :runner_id, null: false        # Unique ID (instance-id or generated UUID)
  t.string :instance_id                    # AWS instance ID (if applicable)
  t.string :instance_type                  # e.g., "c5.xlarge"
  t.string :instance_alias                 # e.g., "c5-xl" (from config)
  t.string :provider                       # "aws", "local"
  t.string :ip_address
  t.string :status, default: 'pending'     # pending, starting, ready, busy, error, stale, shutdown
  t.references :current_task, foreign_key: { to_table: :tasks }
  t.references :run, null: false, foreign_key: true
  t.text :error_message
  t.datetime :first_heartbeat_at
  t.datetime :last_heartbeat_at
  t.timestamps

  t.index [:run_id, :runner_id], unique: true
  t.index [:run_id, :status]
end
```

---

## Run Creation: Pre-populate Expected Runners

When a run is created, create TaskRunner records immediately:

```ruby
# app/models/run.rb
class Run < ApplicationRecord
  has_many :task_runners, dependent: :destroy

  after_create :create_expected_runners

  private

  def create_expected_runners
    config = self.config  # The JSON config passed at creation

    # For each provider in config
    %w[aws local azure].each do |provider|
      next unless config[provider].present?

      config[provider].each do |instance_config|
        instance_type = instance_config['instance_type']
        instance_alias = instance_config['alias']
        runner_count = get_runner_count(provider)

        runner_count.times do |i|
          task_runners.create!(
            runner_id: "#{provider}-#{instance_alias}-#{i + 1}",  # Predictable ID
            instance_type: instance_type,
            instance_alias: instance_alias,
            provider: provider,
            status: 'pending'
          )
        end
      end
    end
  end

  def get_runner_count(provider)
    # Check provider-specific count first
    config.dig('task_runners', 'count', provider) ||
      # Then global count
      config.dig('task_runners', 'count') ||
      # Default to 1
      1
  end
end
```

---

## API Endpoints

### Heartbeat (primary endpoint)

```ruby
# PATCH /api/task_runners/:runner_id/heartbeat
# Called by task runners every 10 seconds

class Api::TaskRunnersController < ApiController
  def heartbeat
    runner = find_or_initialize_runner

    was_pending = runner.pending?

    runner.assign_attributes(
      status: params[:status] || 'starting',
      ip_address: params[:ip_address] || request.remote_ip,
      instance_id: params[:instance_id],
      current_task_id: params[:current_task_id],
      error_message: params[:error_message],
      last_heartbeat_at: Time.current
    )

    runner.first_heartbeat_at ||= Time.current
    runner.save!

    render json: { status: 'ok', runner_status: runner.status }
  end

  private

  def find_or_initialize_runner
    # Try to find by runner_id within this run
    runner = TaskRunner.find_by(run_id: params[:run_id], runner_id: params[:runner_id])

    # If not found (unexpected runner), create a new record
    runner ||= TaskRunner.new(
      run_id: params[:run_id],
      runner_id: params[:runner_id],
      provider: params[:provider],
      instance_type: params[:instance_type],
      instance_alias: params[:instance_alias]
    )

    runner
  end
end
```

### Shutdown

```ruby
# DELETE /api/task_runners/:runner_id
def destroy
  runner = TaskRunner.find_by!(run_id: params[:run_id], runner_id: params[:runner_id])
  runner.update!(status: 'shutdown')
  render json: { status: 'ok' }
end
```

### List (for UI)

```ruby
# GET /api/task_runners?run_id=xxx
def index
  runners = TaskRunner.where(run_id: params[:run_id]).order(:provider, :instance_alias, :runner_id)
  render json: runners
end
```

---

## Early Heartbeat in User-Data

Send heartbeat immediately when instance boots, before app starts:

```bash
#!/bin/bash
# user-data.sh for task runner instances

# Variables passed in
ORCHESTRATOR_URL="${orchestrator_url}"
API_KEY="${api_key}"
RUN_ID="${run_id}"
RUNNER_ID="${runner_id}"
INSTANCE_TYPE="${instance_type}"
INSTANCE_ALIAS="${instance_alias}"
PROVIDER="aws"

# Get instance metadata
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
IP_ADDRESS=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)

# Send immediate heartbeat - instance is alive!
curl -s -X PATCH "$ORCHESTRATOR_URL/api/task_runners/$RUNNER_ID/heartbeat" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"run_id\": \"$RUN_ID\",
    \"status\": \"starting\",
    \"instance_id\": \"$INSTANCE_ID\",
    \"instance_type\": \"$INSTANCE_TYPE\",
    \"instance_alias\": \"$INSTANCE_ALIAS\",
    \"provider\": \"$PROVIDER\",
    \"ip_address\": \"$IP_ADDRESS\"
  }"

# Now do the slow stuff (install deps, pull image, etc.)
# ...

# Start task runner (which will send its own heartbeats)
docker run ... task-runner ...
```

---

## Stale Detection Background Job

```ruby
# app/jobs/stale_runner_detection_job.rb
class StaleRunnerDetectionJob < ApplicationJob
  queue_as :default

  STALE_THRESHOLD = 60.seconds

  def perform
    # Mark runners as stale if no heartbeat in 60 seconds
    TaskRunner
      .where(status: %w[starting ready busy])
      .where('last_heartbeat_at < ?', STALE_THRESHOLD.ago)
      .find_each do |runner|
        runner.update!(status: 'stale')

        # If runner was busy, the task may need attention
        if runner.current_task.present?
          Rails.logger.warn "Runner #{runner.runner_id} went stale while working on task #{runner.current_task_id}"
        end
      end

    # Also mark pending runners as stale if created > 60s ago and never heartbeated
    TaskRunner
      .where(status: 'pending')
      .where('created_at < ?', STALE_THRESHOLD.ago)
      .where(first_heartbeat_at: nil)
      .update_all(status: 'stale', updated_at: Time.current)
  end
end
```

Schedule via Solid Queue (every 15 seconds):

```ruby
# config/recurring.yml
stale_runner_detection:
  class: StaleRunnerDetectionJob
  schedule: every 15 seconds
```

---

## Task Runner Script Changes

```ruby
# task_runner.rb

class TaskRunner
  HEARTBEAT_INTERVAL = 10  # seconds

  def initialize(orchestrator_url:, api_key:, run_id:, runner_id:, **options)
    @orchestrator_url = orchestrator_url
    @api_key = api_key
    @run_id = run_id
    @runner_id = runner_id
    @options = options
    @current_task = nil
  end

  def run
    start_heartbeat_thread

    send_heartbeat(status: 'ready')

    loop do
      task = claim_task
      break unless task

      @current_task = task
      send_heartbeat(status: 'busy', current_task_id: task['id'])

      begin
        execute_benchmark(task)
      rescue => e
        send_heartbeat(status: 'error', error_message: e.message)
        raise
      end

      @current_task = nil
      send_heartbeat(status: 'ready')
    end

    send_shutdown
  end

  private

  def start_heartbeat_thread
    Thread.new do
      loop do
        sleep HEARTBEAT_INTERVAL
        send_heartbeat(
          status: @current_task ? 'busy' : 'ready',
          current_task_id: @current_task&.dig('id')
        )
      end
    end
  end

  def send_heartbeat(status:, current_task_id: nil, error_message: nil)
    uri = URI("#{@orchestrator_url}/api/task_runners/#{@runner_id}/heartbeat")

    body = {
      run_id: @run_id,
      status: status,
      provider: @options[:provider],
      instance_type: @options[:instance_type],
      instance_alias: @options[:instance_alias],
      current_task_id: current_task_id,
      error_message: error_message
    }.compact

    http = Net::HTTP.new(uri.host, uri.port)
    request = Net::HTTP::Patch.new(uri.path)
    request['Authorization'] = "Bearer #{@api_key}"
    request['Content-Type'] = 'application/json'
    request.body = body.to_json

    http.request(request)
  rescue => e
    # Log but don't crash on heartbeat failure
    warn "Heartbeat failed: #{e.message}"
  end

  def send_shutdown
    uri = URI("#{@orchestrator_url}/api/task_runners/#{@runner_id}")
    # ... DELETE request
  end
end
```

---

## UI Display

```
Task Runners                           Run: abc123
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Summary: 5 expected │ 4 online │ 1 pending │ 0 stale

┌───────────────────┬──────────────┬───────────┬─────────────┬────────────┐
│ Runner            │ Instance     │ Status    │ Task        │ Last Seen  │
├───────────────────┼──────────────┼───────────┼─────────────┼────────────┤
│ aws-c5-xl-1       │ i-abc123     │ 🔵 BUSY   │ Task #42    │ 5s ago     │
│ aws-c5-xl-2       │ i-def456     │ 🟢 READY  │ -           │ 3s ago     │
│ aws-c5-2xl-1      │ i-ghi789     │ 🔵 BUSY   │ Task #43    │ 8s ago     │
│ aws-c5-2xl-2      │ i-jkl012     │ 🟡 STARTING│ -          │ 15s ago    │
│ aws-c5-4xl-1      │ -            │ ⚪ PENDING │ -           │ never      │
└───────────────────┴──────────────┴───────────┴─────────────┴────────────┘

⚠️  aws-c5-4xl-1 has not sent a heartbeat yet (expected 45s ago)
```

### Status Icons

- ⚪ `PENDING` - Expected, waiting for first heartbeat
- 🟡 `STARTING` - First heartbeat received, initializing
- 🟢 `READY` - Healthy, waiting for tasks
- 🔵 `BUSY` - Currently executing a task
- 🔴 `STALE` - No heartbeat in 60s, presumed dead
- 🔴 `ERROR` - Reported an error
- ⚫ `SHUTDOWN` - Gracefully stopped

---

## Implementation Checklist

1. [ ] Add `task_runners` migration
2. [ ] Add `TaskRunner` model with state machine
3. [ ] Update `Run` model to create expected runners on creation
4. [ ] Add `Api::TaskRunnersController` with heartbeat/shutdown endpoints
5. [ ] Add `StaleRunnerDetectionJob` and schedule it
6. [ ] Update AWS user-data to send early heartbeat via curl
7. [ ] Update task runner script to send periodic heartbeats
8. [ ] Add UI component showing runner status on run page
9. [ ] Update local task runner startup to use predictable runner IDs

---

## Edge Cases

1. **Unexpected runner registers** - Create a new TaskRunner record (runner_id not in expected list). Mark as "unplanned" in UI.

2. **Runner registers for wrong run** - Reject with 404.

3. **Orchestrator restarts** - Runners should continue heartbeating; they'll just update existing records.

4. **Network partition** - 60s threshold handles transient issues. If truly partitioned, runner goes stale.

5. **Runner crashes mid-task** - Goes stale after 60s. Task has its own timeout and will be requeued.

6. **Duplicate runner IDs** - Unique index on `[run_id, runner_id]` prevents this.
