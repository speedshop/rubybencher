#!/usr/bin/env bash
# E2E test: Task Runner integration with Orchestrator
# Tests the complete flow: create run → claim task → run mock benchmark → complete task
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ORCHESTRATOR_DIR="$REPO_ROOT/bench-new/orchestrator"
TASK_RUNNER_DIR="$REPO_ROOT/bench-new/task-runner"
source "$REPO_ROOT/test/helpers.sh"

BASE_URL="${BASE_URL:-http://localhost:3000}"
API_KEY="${API_KEY:-dev_api_key_change_in_production}"

echo -e "\n${YELLOW}═══ Task Runner E2E Integration Test ═══${NC}\n"

# Ensure services are running
test_step "Verify orchestrator is running"
response=$(curl -sf "$BASE_URL/up" 2>/dev/null) || test_fail "Orchestrator not running at $BASE_URL"
test_pass

# Create a run with a local instance
test_step "Create run with local instance"
response=$(api_post "/runs" '{"ruby_version":"3.4.7","runs_per_instance_type":1,"local":["task-runner-test"]}')
RUN_ID=$(echo "$response" | jq -r '.run_id')
# The run_id returned is the external_id used for task claiming
EXTERNAL_ID="$RUN_ID"

assert_not_empty "$RUN_ID" "Run ID"
assert_equals "1" "$(echo "$response" | jq -r '.tasks_created')" "Tasks created count"
log_info "Created run with ID: $RUN_ID"
test_pass

# Run the task runner with mock mode
test_step "Execute task runner with mock benchmark"

cd "$TASK_RUNNER_DIR"

# Run task runner in a container with mock mode using command line args
log_info "Starting task runner container..."
docker run --rm \
    --network host \
    -e MOCK_ALWAYS_SUCCEED="1" \
    -v "$TASK_RUNNER_DIR":/app \
    -w /app \
    ruby:3.4 bash -c "bundle install --quiet && ruby lib/ruby/main.rb \
        --orchestrator-url '$BASE_URL' \
        --api-key '$API_KEY' \
        --run-id '$EXTERNAL_ID' \
        --provider 'local' \
        --instance-type 'task-runner-test' \
        --mock" 2>&1 | tail -30

RUNNER_EXIT=$?
if [ $RUNNER_EXIT -ne 0 ]; then
    log_warn "Task runner exited with code $RUNNER_EXIT (may be expected)"
fi

test_pass

# Verify task completed
test_step "Verify task completed successfully"

log_info "Waiting for task to complete..."
for i in $(seq 1 30); do
    response=$(api_get "/runs/$RUN_ID")
    status=$(echo "$response" | jq -r '.status')
    tasks_completed=$(echo "$response" | jq -r '.tasks.completed')

    if [ "$status" = "completed" ] || [ "$tasks_completed" = "1" ]; then
        break
    fi
    sleep 2
done

response=$(api_get "/runs/$RUN_ID")
status=$(echo "$response" | jq -r '.status')
tasks_completed=$(echo "$response" | jq -r '.tasks.completed')

assert_equals "1" "$tasks_completed" "Task completed count"
log_info "Run status: $status, Tasks completed: $tasks_completed"
test_pass

# Verify run finalized
test_step "Verify run is completed"

# Wait for background job to process
for i in $(seq 1 15); do
    status=$(api_get "/runs/$RUN_ID" | jq -r '.status')
    [ "$status" = "completed" ] && break
    sleep 2
done

assert_equals "completed" "$status" "Run status"
test_pass

print_summary
