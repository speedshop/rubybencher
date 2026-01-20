function create_run
    log_info "Creating benchmark run..."

    set -l config_json (cat "$CONFIG_FILE")

    # Add the pre-generated run_id to the config
    set -l config_with_run_id (echo $config_json | jq --arg run_id "$RUN_ID" '. + {run_id: $run_id}')

    if test "$DEBUG" = true
        echo "Config being sent:"
        echo $config_with_run_id | jq .
    end

    set -l response (curl -s -X POST "$ORCHESTRATOR_URL/runs" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -d "$config_with_run_id")

    if test "$DEBUG" = true
        echo "Response:"
        echo $response | jq .
    end

    # Parse response
    set -l response_run_id (echo $response | jq -r '.run_id // empty')
    set -l tasks_created (echo $response | jq -r '.tasks_created // 0')
    set -l error_msg (echo $response | jq -r '.error // empty')

    if test -z "$response_run_id"
        log_error "Failed to create run: $error_msg"
        exit 1
    end

    log_success "Created run $RUN_ID with $tasks_created tasks"
end

function display_progress
    set -l run_id $argv[1]

    set -l response (curl -s "$ORCHESTRATOR_URL/runs/$run_id" \
        -H "Authorization: Bearer $API_KEY")

    set -l run_status (echo $response | jq -r '.status')
    set -l total (echo $response | jq -r '.tasks.total')
    set -l pending (echo $response | jq -r '.tasks.pending')
    set -l claimed (echo $response | jq -r '.tasks.claimed')
    set -l running (echo $response | jq -r '.tasks.running')
    set -l completed (echo $response | jq -r '.tasks.completed')
    set -l failed (echo $response | jq -r '.tasks.failed')

    # Calculate progress percentage
    set -l done_count (math $completed + $failed)
    set -l progress 0
    if test $total -gt 0
        set progress (math "round($done_count * 100 / $total)")
    end

    # Build status line
    set -l status_line "[$progress%] "
    set status_line "$status_line""Pending: $pending | "
    set status_line "$status_line""Running: "(math $claimed + $running)" | "
    set status_line "$status_line""✓ $completed | "
    set status_line "$status_line""✗ $failed"

    echo $status_line

    echo $run_status
end

function poll_run_status
    log_info "Waiting for benchmark to complete..."

    set -l poll_interval 10

    while true
        set -l response (curl -s "$ORCHESTRATOR_URL/runs/$RUN_ID" \
            -H "Authorization: Bearer $API_KEY")

        set -l run_status (echo $response | jq -r '.status // "unknown"')
        set -l total (echo $response | jq -r '.tasks.total // 0')
        set -l pending (echo $response | jq -r '.tasks.pending // 0')
        set -l claimed (echo $response | jq -r '.tasks.claimed // 0')
        set -l running (echo $response | jq -r '.tasks.running // 0')
        set -l completed (echo $response | jq -r '.tasks.completed // 0')
        set -l failed (echo $response | jq -r '.tasks.failed // 0')

        # Update status file for monitoring/automation
        set -l now (date -u +"%Y-%m-%dT%H:%M:%SZ")
        run_status_update \
            '.updated_at = $updated_at |
             .orchestrator_url = $orchestrator_url |
             .run = { status: $status, tasks: { total: $total, pending: $pending, claimed: $claimed, running: $running, completed: $completed, failed: $failed } }' \
            --arg updated_at "$now" \
            --arg orchestrator_url "$ORCHESTRATOR_URL" \
            --arg status "$run_status" \
            --argjson total $total \
            --argjson pending $pending \
            --argjson claimed $claimed \
            --argjson running $running \
            --argjson completed $completed \
            --argjson failed $failed

        # Emit a stable, single-line progress status
        set -l done_count (math $completed + $failed)
        set -l progress 0
        if test $total -gt 0
            set progress (math "round($done_count * 100 / $total)")
        end

        echo "[$progress%] Pending: $pending | Running: "(math $claimed + $running)" | ✓ $completed | ✗ $failed"

        if test "$run_status" = "completed"; or test "$run_status" = "cancelled"; or test "$run_status" = "failed"
            if test "$run_status" = "failed"
                log_error "Run failed"
            else
                log_success "Run $run_status"
            end
            break
        end

        sleep $poll_interval
    end
end

function download_results
    log_info "Downloading results..."

    set -l response (curl -s "$ORCHESTRATOR_URL/runs/$RUN_ID" \
        -H "Authorization: Bearer $API_KEY")

    set -l gzip_url (echo $response | jq -r '.gzip_url // empty')

    if test -z "$gzip_url"; or test "$gzip_url" = "null"
        log_warning "No results gzip available yet"
        if test "$DEBUG" = true
            echo "API response:"
            echo $response | jq .
        end
        return 1
    end

    # Create results directory
    set -l run_results_dir "$RESULTS_DIR/$RUN_ID"
    mkdir -p "$run_results_dir"

    log_info "Downloading results archive..."
    if test "$DEBUG" = true
        log_info "Download URL: $gzip_url"
    end

    set -l http_code (curl -s -w "%{http_code}" -o "$run_results_dir/results.tar.gz" "$gzip_url")

    if test "$http_code" != "200"
        log_error "Failed to download results (HTTP $http_code)"
        log_error "URL: $gzip_url"
        if test -f "$run_results_dir/results.tar.gz"
            set -l error_content (cat "$run_results_dir/results.tar.gz" 2>/dev/null | head -c 500)
            if test -n "$error_content"
                log_error "Response body: $error_content"
            end
            rm -f "$run_results_dir/results.tar.gz"
        end
        return 1
    end

    if not test -f "$run_results_dir/results.tar.gz"
        log_error "Failed to download results: file not created"
        return 1
    end

    # Verify it's a valid gzip file
    if not gzip -t "$run_results_dir/results.tar.gz" 2>/dev/null
        log_error "Downloaded file is not a valid gzip archive"
        if test "$DEBUG" = true
            log_error "File contents:"
            head -c 200 "$run_results_dir/results.tar.gz"
        end
        return 1
    end

    log_info "Extracting results..."

    tar -xzf "$run_results_dir/results.tar.gz" -C "$run_results_dir"
    if test $status -ne 0
        log_error "Failed to extract results archive"
        return 1
    end

    rm "$run_results_dir/results.tar.gz"
    log_success "Results saved to: $run_results_dir"
end

function cleanup_on_interrupt
    echo ""
    log_warning "Interrupted!"

    log_info "Skipping cleanup; run nuke if needed"
    exit 130
end
