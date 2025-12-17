#!/usr/bin/env bash
# Orchestrator API integration tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/test/helpers.sh"

BASE_URL="${BASE_URL:-http://localhost:3000}"
API_KEY="${API_KEY:-dev_api_key_change_in_production}"
RUNNER_ID="test-runner-$(date +%s)"

echo -e "\n${YELLOW}═══ Orchestrator API Tests ═══${NC}\n"

# Health check
test_step "Health check (GET /up)"
assert_equals "200" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/up")" "Returns 200"
test_pass

# Create run
test_step "Create run (POST /runs)"
response=$(api_post "/runs" '{"ruby_version":"3.4.7","runs_per_instance_type":1,"local":["test-instance"]}')
RUN_ID=$(echo "$response" | jq -r '.run_id')
assert_not_empty "$RUN_ID" "Run ID present"
assert_equals "1" "$(echo "$response" | jq -r '.tasks_created')" "One task created"
test_pass

# Verify run
test_step "Verify run status (GET /runs/$RUN_ID)"
response=$(api_get "/runs/$RUN_ID")
assert_equals "running" "$(echo "$response" | jq -r '.status')" "Status is running"
assert_equals "1" "$(echo "$response" | jq -r '.tasks.pending')" "One pending task"
test_pass

# Claim task
test_step "Claim task (POST /runs/$RUN_ID/tasks/claim)"
response=$(api_post "/runs/$RUN_ID/tasks/claim" "{\"provider\":\"local\",\"instance_type\":\"test-instance\",\"runner_id\":\"$RUNNER_ID\"}")
TASK_ID=$(echo "$response" | jq -r '.task.id')
assert_equals "assigned" "$(echo "$response" | jq -r '.status')" "Status is assigned"
assert_not_empty "$TASK_ID" "Task ID present"
test_pass

# Heartbeat
test_step "Send heartbeat (POST /tasks/$TASK_ID/heartbeat)"
response=$(api_post "/tasks/$TASK_ID/heartbeat" "{\"runner_id\":\"$RUNNER_ID\",\"status\":\"running\",\"progress_pct\":50}")
assert_equals "Heartbeat received" "$(echo "$response" | jq -r '.message')" "Heartbeat acknowledged"
test_pass

# Complete task
test_step "Complete task (POST /tasks/$TASK_ID/complete)"
response=$(api_post "/tasks/$TASK_ID/complete" "{\"runner_id\":\"$RUNNER_ID\",\"s3_result_key\":\"results/$RUN_ID/task.tar.gz\"}")
assert_equals "Task marked as completed" "$(echo "$response" | jq -r '.message')" "Completion acknowledged"
test_pass

# Verify completion
test_step "Verify task completed"
sleep 1
response=$(api_get "/runs/$RUN_ID")
assert_equals "1" "$(echo "$response" | jq -r '.tasks.completed')" "One task completed"
assert_equals "0" "$(echo "$response" | jq -r '.tasks.pending')" "No pending tasks"
test_pass

# Claim when done
test_step "Claim when no tasks available"
response=$(api_post "/runs/$RUN_ID/tasks/claim" "{\"provider\":\"local\",\"instance_type\":\"test-instance\",\"runner_id\":\"$RUNNER_ID\"}")
assert_equals "done" "$(echo "$response" | jq -r '.status')" "Returns done"
test_pass

# Invalid API key
test_step "Invalid API key returns 401"
tmpfile=$(mktemp)
code=$(curl -s -o "$tmpfile" -w "%{http_code}" -X POST \
    -H "Authorization: Bearer invalid" -H "Content-Type: application/json" \
    -d '{"ruby_version":"3.4.7","runs_per_instance_type":1,"local":["test"]}' "$BASE_URL/runs")
assert_equals "401" "$code" "Returns 401"
rm -f "$tmpfile"
test_pass

# Wrong runner_id
test_step "Wrong runner_id returns 403"
response=$(api_post "/runs" '{"ruby_version":"3.4.7","runs_per_instance_type":1,"local":["test-instance"]}')
new_run_id=$(echo "$response" | jq -r '.run_id')
response=$(api_post "/runs/$new_run_id/tasks/claim" "{\"provider\":\"local\",\"instance_type\":\"test-instance\",\"runner_id\":\"$RUNNER_ID\"}")
new_task_id=$(echo "$response" | jq -r '.task.id')

tmpfile=$(mktemp)
code=$(curl -s -o "$tmpfile" -w "%{http_code}" -X POST \
    -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
    -d '{"runner_id":"wrong","status":"running"}' "$BASE_URL/tasks/$new_task_id/heartbeat")
assert_equals "403" "$code" "Returns 403"
rm -f "$tmpfile"
test_pass

print_summary
