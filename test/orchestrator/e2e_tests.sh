#!/usr/bin/env bash
# E2E tests verifying background jobs work correctly
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ORCHESTRATOR_DIR="$REPO_ROOT/bench-new/orchestrator"
source "$REPO_ROOT/test/helpers.sh"

BASE_URL="${BASE_URL:-http://localhost:3000}"
API_KEY="${API_KEY:-dev_api_key_change_in_production}"

echo -e "\n${YELLOW}═══ E2E Tests: Background Jobs ═══${NC}\n"

# Test 1: Task completion triggers GzipBuilderJob
test_step "Task completion triggers run finalization"

response=$(api_post "/runs" '{"ruby_version":"3.4.7","runs_per_instance_type":1,"local":["e2e-instance"]}')
RUN_ID=$(echo "$response" | jq -r '.run_id')
RUNNER_ID="e2e-$(date +%s)"

response=$(api_post "/runs/$RUN_ID/tasks/claim" "{\"provider\":\"local\",\"instance_type\":\"e2e-instance\",\"runner_id\":\"$RUNNER_ID\"}")
TASK_ID=$(echo "$response" | jq -r '.task.id')
RESULT_KEY=$(echo "$response" | jq -r '.presigned_urls.result_key')

api_post "/tasks/$TASK_ID/complete" "{\"runner_id\":\"$RUNNER_ID\",\"s3_result_key\":\"$RESULT_KEY\"}" >/dev/null

log_info "Waiting for GzipBuilderJob..."
for i in $(seq 1 15); do
    status=$(api_get "/runs/$RUN_ID" | jq -r '.status')
    [ "$status" = "completed" ] && break
    sleep 2
done

assert_equals "completed" "$status" "Run completed after task completion"
test_pass

# Test 2: Heartbeat timeout triggers task failure
test_step "Heartbeat timeout fails task and completes run"

response=$(api_post "/runs" '{"ruby_version":"3.4.7","runs_per_instance_type":1,"local":["timeout-instance"]}')
TIMEOUT_RUN_ID=$(echo "$response" | jq -r '.run_id')
TIMEOUT_RUNNER="timeout-$(date +%s)"

response=$(api_post "/runs/$TIMEOUT_RUN_ID/tasks/claim" "{\"provider\":\"local\",\"instance_type\":\"timeout-instance\",\"runner_id\":\"$TIMEOUT_RUNNER\"}")
TIMEOUT_TASK_ID=$(echo "$response" | jq -r '.task.id')

log_info "Simulating stale heartbeat..."
rails_runner "Task.find($TIMEOUT_TASK_ID).update!(heartbeat_at: 3.minutes.ago)"

log_info "Triggering HeartbeatMonitorJob..."
rails_runner "HeartbeatMonitorJob.perform_now"

task_status=$(rails_runner "puts Task.find($TIMEOUT_TASK_ID).status" | tr -d '\n')
task_error=$(rails_runner "puts Task.find($TIMEOUT_TASK_ID).error_type" | tr -d '\n')

assert_equals "failed" "$task_status" "Task is failed"
assert_equals "timeout" "$task_error" "Error type is timeout"

log_info "Waiting for run to complete..."
for i in $(seq 1 15); do
    status=$(api_get "/runs/$TIMEOUT_RUN_ID" | jq -r '.status')
    [ "$status" = "completed" ] && break
    sleep 2
done

assert_equals "completed" "$status" "Run completed after timeout"
test_pass

# Test 3: Mixed task outcomes
test_step "Multiple tasks: complete some, timeout others"

response=$(api_post "/runs" '{"ruby_version":"3.4.7","runs_per_instance_type":2,"local":["multi-instance"]}')
MULTI_RUN_ID=$(echo "$response" | jq -r '.run_id')
assert_equals "2" "$(echo "$response" | jq -r '.tasks_created')" "Two tasks created"

# Complete first task
RUNNER1="multi1-$(date +%s)"
response=$(api_post "/runs/$MULTI_RUN_ID/tasks/claim" "{\"provider\":\"local\",\"instance_type\":\"multi-instance\",\"runner_id\":\"$RUNNER1\"}")
TASK1=$(echo "$response" | jq -r '.task.id')
RESULT_KEY1=$(echo "$response" | jq -r '.presigned_urls.result_key')
api_post "/tasks/$TASK1/complete" "{\"runner_id\":\"$RUNNER1\",\"s3_result_key\":\"$RESULT_KEY1\"}" >/dev/null

# Timeout second task
RUNNER2="multi2-$(date +%s)"
response=$(api_post "/runs/$MULTI_RUN_ID/tasks/claim" "{\"provider\":\"local\",\"instance_type\":\"multi-instance\",\"runner_id\":\"$RUNNER2\"}")
TASK2=$(echo "$response" | jq -r '.task.id')

rails_runner "Task.find($TASK2).update!(heartbeat_at: 3.minutes.ago)"
rails_runner "HeartbeatMonitorJob.perform_now"

t1_status=$(rails_runner "puts Task.find($TASK1).status" | tr -d '\n')
t2_status=$(rails_runner "puts Task.find($TASK2).status" | tr -d '\n')

assert_equals "completed" "$t1_status" "Task 1 completed"
assert_equals "failed" "$t2_status" "Task 2 failed"

for i in $(seq 1 15); do
    status=$(api_get "/runs/$MULTI_RUN_ID" | jq -r '.status')
    [ "$status" = "completed" ] && break
    sleep 2
done

assert_equals "completed" "$status" "Run with mixed outcomes completed"
test_pass

# Test 4: Verify recurring job is registered (with retry for timing)
test_step "HeartbeatMonitorJob is registered as recurring"

for i in $(seq 1 10); do
    tasks=$(rails_runner "puts SolidQueue::RecurringTask.pluck(:key).join(',')" | tr -d '\n')
    [[ "$tasks" == *"heartbeat_monitor"* ]] && break
    sleep 1
done
assert_contains "$tasks" "heartbeat_monitor" "Recurring task registered"
test_pass

# Test 5: Worker is running
test_step "Solid Queue worker is active"

count=$(rails_runner "puts SolidQueue::Process.where('last_heartbeat_at > ?', 1.minute.ago).count" | tr -d '\n')
[ "$count" -gt "0" ] && echo -e "  ${GREEN}✓${NC} $count active process(es)" || test_fail "No active workers"
test_pass

print_summary
