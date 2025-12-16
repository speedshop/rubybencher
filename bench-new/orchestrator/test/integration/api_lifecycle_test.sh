#!/usr/bin/env fish

# Integration test script for the orchestrator API
# Tests the full lifecycle of a benchmark run

set BASE_URL "http://localhost:3000"
set API_KEY "dev_api_key_change_in_production"
set RUNNER_ID "test-runner-"(date +%s)

# Colors for output
set GREEN (set_color green)
set RED (set_color red)
set YELLOW (set_color yellow)
set NC (set_color normal)

# Test counter
set total_tests 0
set passed_tests 0

function test_step
    set -l description $argv[1]
    set total_tests (math $total_tests + 1)
    echo ""
    echo $YELLOW"[TEST $total_tests]"$NC" $description"
end

function test_pass
    set passed_tests (math $passed_tests + 1)
    echo $GREEN"✓ PASS"$NC
end

function test_fail
    set -l message $argv[1]
    echo $RED"✗ FAIL"$NC": $message"
    exit 1
end

function assert_equals
    set -l expected $argv[1]
    set -l actual $argv[2]
    set -l description $argv[3]

    if test "$expected" = "$actual"
        echo "  "$GREEN"✓"$NC" $description"
    else
        test_fail "$description - expected '$expected', got '$actual'"
    end
end

function assert_not_empty
    set -l value $argv[1]
    set -l description $argv[2]

    if test -n "$value"
        echo "  "$GREEN"✓"$NC" $description"
    else
        test_fail "$description - value is empty"
    end
end

echo ""
echo $YELLOW"╔════════════════════════════════════════════════╗"$NC
echo $YELLOW"║   Orchestrator API Integration Test Suite     ║"$NC
echo $YELLOW"╚════════════════════════════════════════════════╝"$NC

# ============================================================================
# TEST 1: Health Check
# ============================================================================
test_step "Health check endpoint (GET /up)"

set status_code (curl -s -o /dev/null -w "%{http_code}" $BASE_URL/up)

assert_equals "200" "$status_code" "Health check returns 200"
test_pass

# ============================================================================
# TEST 2: Create a run
# ============================================================================
test_step "Create a run via POST /runs"

set tmpfile (mktemp)
set status_code (curl -s -o $tmpfile -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{
        "ruby_version": "3.4.7",
        "runs_per_instance_type": 1,
        "local": ["test-instance"]
    }' \
    $BASE_URL/runs)
set body (cat $tmpfile)
rm -f $tmpfile

assert_equals "201" "$status_code" "Create run returns 201"

set RUN_ID (echo $body | jq -r '.run_id')
set tasks_created (echo $body | jq -r '.tasks_created')

assert_not_empty "$RUN_ID" "Run ID is present"
assert_equals "1" "$tasks_created" "One task was created"
test_pass

# ============================================================================
# TEST 3: Verify run exists and tasks exist
# ============================================================================
test_step "Verify run status (GET /runs/$RUN_ID)"

set tmpfile (mktemp)
set status_code (curl -s -o $tmpfile -w "%{http_code}" $BASE_URL/runs/$RUN_ID)
set body (cat $tmpfile)
rm -f $tmpfile

assert_equals "200" "$status_code" "Get run returns 200"

set run_status (echo $body | jq -r '.status')
set total_tasks (echo $body | jq -r '.tasks.total')
set pending_tasks (echo $body | jq -r '.tasks.pending')

assert_equals "running" "$run_status" "Run status is running"
assert_equals "1" "$total_tasks" "Total tasks is 1"
assert_equals "1" "$pending_tasks" "Pending tasks is 1"
test_pass

# ============================================================================
# TEST 4: Claim a task
# ============================================================================
test_step "Claim a task (POST /runs/$RUN_ID/tasks/claim)"

set tmpfile (mktemp)
set status_code (curl -s -o $tmpfile -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{
        \"provider\": \"local\",
        \"instance_type\": \"test-instance\",
        \"runner_id\": \"$RUNNER_ID\"
    }" \
    $BASE_URL/runs/$RUN_ID/tasks/claim)
set body (cat $tmpfile)
rm -f $tmpfile

assert_equals "200" "$status_code" "Claim task returns 200"

set claim_status (echo $body | jq -r '.status')
set TASK_ID (echo $body | jq -r '.task.id')
set task_provider (echo $body | jq -r '.task.provider')
set task_instance_type (echo $body | jq -r '.task.instance_type')

assert_equals "assigned" "$claim_status" "Claim status is 'assigned'"
assert_not_empty "$TASK_ID" "Task ID is present"
assert_equals "local" "$task_provider" "Task provider is 'local'"
assert_equals "test-instance" "$task_instance_type" "Task instance type is 'test-instance'"
test_pass

# ============================================================================
# TEST 5: Send heartbeat
# ============================================================================
test_step "Send heartbeat (POST /tasks/$TASK_ID/heartbeat)"

set tmpfile (mktemp)
set status_code (curl -s -o $tmpfile -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{
        \"runner_id\": \"$RUNNER_ID\",
        \"status\": \"running\",
        \"current_benchmark\": \"activerecord\",
        \"progress_pct\": 50,
        \"message\": \"Running benchmarks\"
    }" \
    $BASE_URL/tasks/$TASK_ID/heartbeat)
set body (cat $tmpfile)
rm -f $tmpfile

assert_equals "200" "$status_code" "Heartbeat returns 200"

set message (echo $body | jq -r '.message')
assert_equals "Heartbeat received" "$message" "Heartbeat acknowledged"
test_pass

# ============================================================================
# TEST 6: Complete the task
# ============================================================================
test_step "Complete task (POST /tasks/$TASK_ID/complete)"

set tmpfile (mktemp)
set status_code (curl -s -o $tmpfile -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{
        \"runner_id\": \"$RUNNER_ID\",
        \"s3_result_key\": \"test-results/test-key.json\"
    }" \
    $BASE_URL/tasks/$TASK_ID/complete)
set body (cat $tmpfile)
rm -f $tmpfile

assert_equals "200" "$status_code" "Complete task returns 200"

set message (echo $body | jq -r '.message')
assert_equals "Task marked as completed" "$message" "Task completion acknowledged"
test_pass

# ============================================================================
# TEST 7: Verify run status becomes completed
# ============================================================================
test_step "Verify run is completed (GET /runs/$RUN_ID)"

# Give the system a moment to process the completion
sleep 1

set tmpfile (mktemp)
set status_code (curl -s -o $tmpfile -w "%{http_code}" $BASE_URL/runs/$RUN_ID)
set body (cat $tmpfile)
rm -f $tmpfile

assert_equals "200" "$status_code" "Get run returns 200"

set completed_tasks (echo $body | jq -r '.tasks.completed')
set pending_tasks (echo $body | jq -r '.tasks.pending')

assert_equals "1" "$completed_tasks" "One task is completed"
assert_equals "0" "$pending_tasks" "No pending tasks"
test_pass

# ============================================================================
# TEST 8: Error case - Claiming when no tasks available
# ============================================================================
test_step "Error case: Claim when no tasks available (should get 'done' status)"

set tmpfile (mktemp)
set status_code (curl -s -o $tmpfile -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{
        \"provider\": \"local\",
        \"instance_type\": \"test-instance\",
        \"runner_id\": \"$RUNNER_ID\"
    }" \
    $BASE_URL/runs/$RUN_ID/tasks/claim)
set body (cat $tmpfile)
rm -f $tmpfile

assert_equals "200" "$status_code" "Claim returns 200"

set claim_status (echo $body | jq -r '.status')
assert_equals "done" "$claim_status" "Claim status is 'done' when no tasks available"
test_pass

# ============================================================================
# TEST 9: Error case - Invalid API key
# ============================================================================
test_step "Error case: Invalid API key (should get 401)"

set tmpfile (mktemp)
set status_code (curl -s -o $tmpfile -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer invalid_key_12345" \
    -H "Content-Type: application/json" \
    -d '{
        "ruby_version": "3.4.7",
        "runs_per_instance_type": 1,
        "local": ["test"]
    }' \
    $BASE_URL/runs)
set body (cat $tmpfile)
rm -f $tmpfile

assert_equals "401" "$status_code" "Invalid API key returns 401"

set error (echo $body | jq -r '.error')
assert_equals "Unauthorized" "$error" "Error message is 'Unauthorized'"
test_pass

# ============================================================================
# TEST 10: Error case - Heartbeat with wrong runner_id
# ============================================================================
test_step "Error case: Heartbeat with wrong runner_id (should get 403)"

# Create a new run and claim a task for this test
set tmpfile (mktemp)
curl -s -o $tmpfile \
    -X POST \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{
        "ruby_version": "3.4.7",
        "runs_per_instance_type": 1,
        "local": ["test-instance"]
    }' \
    $BASE_URL/runs
set response (cat $tmpfile)
rm -f $tmpfile

set new_run_id (echo $response | jq -r '.run_id')

set tmpfile (mktemp)
curl -s -o $tmpfile \
    -X POST \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{
        \"provider\": \"local\",
        \"instance_type\": \"test-instance\",
        \"runner_id\": \"$RUNNER_ID\"
    }" \
    $BASE_URL/runs/$new_run_id/tasks/claim
set response (cat $tmpfile)
rm -f $tmpfile

set new_task_id (echo $response | jq -r '.task.id')

# Try to send heartbeat with wrong runner_id
set tmpfile (mktemp)
set status_code (curl -s -o $tmpfile -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{
        "runner_id": "wrong-runner-id",
        "status": "running"
    }' \
    $BASE_URL/tasks/$new_task_id/heartbeat)
set body (cat $tmpfile)
rm -f $tmpfile

assert_equals "403" "$status_code" "Wrong runner_id returns 403"

set error (echo $body | jq -r '.error')
assert_equals "Invalid runner_id" "$error" "Error message is 'Invalid runner_id'"
test_pass

# ============================================================================
# Final Summary
# ============================================================================
echo ""
echo $YELLOW"╔════════════════════════════════════════════════╗"$NC
echo $YELLOW"║              Test Summary                      ║"$NC
echo $YELLOW"╚════════════════════════════════════════════════╝"$NC
echo ""
echo $GREEN"Total Tests: $total_tests"$NC
echo $GREEN"Passed: $passed_tests"$NC
echo $GREEN"Failed: "(math $total_tests - $passed_tests)$NC

if test $passed_tests -eq $total_tests
    echo ""
    echo $GREEN"✓ All tests passed!"$NC
    echo ""
    exit 0
else
    echo ""
    echo $RED"✗ Some tests failed"$NC
    echo ""
    exit 1
end
