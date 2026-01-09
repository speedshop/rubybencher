function status_file_path
    echo "$REPO_ROOT/status.json"
end

function status_exists
    test -f (status_file_path)
end

function status_get
    set -l jq_path $argv[1]

    if not status_exists
        return 1
    end

    set -l value (jq -r "$jq_path // empty" (status_file_path) 2>/dev/null)
    if test -z "$value"; or test "$value" = "null"
        return 1
    end

    echo $value
end

function status_update
    set -l filter $argv[1]
    set -l jq_args $argv[2..-1]
    set -l status_file (status_file_path)
    set -l tmp (mktemp)

    if test -f "$status_file"
        jq $jq_args "$filter" "$status_file" > "$tmp"
    else
        echo '{}' | jq $jq_args "$filter" > "$tmp"
    end

    mv "$tmp" "$status_file"
end

function status_set_run
    set -l run_id $argv[1]
    set -l now (date -u +"%Y-%m-%dT%H:%M:%SZ")

    status_update \
        '(.created_at //= $created_at) | .last_run_id = $run_id' \
        --arg created_at "$now" \
        --arg run_id "$run_id"
end

function status_set_meta
    set -l orchestrator_url $argv[1]
    set -l api_key $argv[2]
    set -l bastion_public_ip $argv[3]
    set -l orchestrator_public_ip $argv[4]
    set -l aws_region $argv[5]
    set -l key_name $argv[6]
    set -l s3_bucket_name $argv[7]
    set -l now (date -u +"%Y-%m-%dT%H:%M:%SZ")

    status_update \
        '(.created_at //= $created_at) |
         .meta = {
           orchestrator_url: $orchestrator_url,
           api_key: $api_key,
           bastion_public_ip: $bastion_public_ip,
           orchestrator_public_ip: $orchestrator_public_ip,
           aws_region: $aws_region,
           key_name: $key_name,
           s3_bucket_name: $s3_bucket_name
         }' \
        --arg created_at "$now" \
        --arg orchestrator_url "$orchestrator_url" \
        --arg api_key "$api_key" \
        --arg bastion_public_ip "$bastion_public_ip" \
        --arg orchestrator_public_ip "$orchestrator_public_ip" \
        --arg aws_region "$aws_region" \
        --arg key_name "$key_name" \
        --arg s3_bucket_name "$s3_bucket_name"
end

function status_clear
    set -l status_file (status_file_path)
    if test -f "$status_file"
        rm -f "$status_file"
    end
end

function fetch_run_status
    set -l orchestrator_url $argv[1]
    set -l run_id $argv[2]

    if test -z "$orchestrator_url"; or test -z "$run_id"
        return 1
    end

    set -l tmp (mktemp)
    set -l http_code (curl -s -o "$tmp" -w "%{http_code}" "$orchestrator_url/runs/$run_id")

    if test "$http_code" != "200"
        rm -f "$tmp"
        return 1
    end

    set -l run_status (jq -r '.status // empty' "$tmp" 2>/dev/null)
    rm -f "$tmp"

    if test -z "$run_status"; or test "$run_status" = "null"
        return 1
    end

    echo $run_status
end

function maybe_resume_from_status
    if test "$LOCAL_ORCHESTRATOR" = true; or test "$SKIP_INFRA" = true
        return 1
    end

    if not status_exists
        return 1
    end

    set -l status_orchestrator_url (status_get '.meta.orchestrator_url')
    if test -z "$status_orchestrator_url"
        return 1
    end

    if not orchestrator_reachable "$status_orchestrator_url"
        log_warning "status.json found but orchestrator not reachable; reapplying meta infrastructure"
        return 1
    end

    set -g RESUME_META true
    set -g STATUS_ORCHESTRATOR_URL "$status_orchestrator_url"
    set -g STATUS_API_KEY (status_get '.meta.api_key')
    set -g STATUS_S3_BUCKET_NAME (status_get '.meta.s3_bucket_name')

    set -l last_run_id (status_get '.last_run_id')
    if test -n "$last_run_id"
        set -l run_status (fetch_run_status "$status_orchestrator_url" "$last_run_id")
        if test "$run_status" = "running"
            set -g RUN_ID "$last_run_id"
            set -g RESUME_RUN true
            log_info "Resuming run $RUN_ID from status.json"
        else if test -n "$run_status"
            log_info "Previous run $last_run_id status: $run_status"
        end
    end
end
