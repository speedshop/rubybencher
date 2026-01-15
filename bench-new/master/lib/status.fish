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

function config_file_hash
    if not test -f "$CONFIG_FILE"
        return 1
    end

    set -l hash ""

    if command -q shasum
        set hash (shasum -a 256 "$CONFIG_FILE" | awk '{print $1}')
    else if command -q sha256sum
        set hash (sha256sum "$CONFIG_FILE" | awk '{print $1}')
    else if command -q openssl
        set hash (openssl dgst -sha256 "$CONFIG_FILE" | awk '{print $2}')
    else
        return 1
    end

    if test -z "$hash"
        return 1
    end

    echo $hash
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
    set -l config_path "$CONFIG_FILE"
    set -l config_hash (config_file_hash)

    if test -z "$config_hash"
        log_warning "Unable to hash config file for status.json"
        set config_hash ""
    end

    status_update \
        '(.created_at //= $created_at) |
         .last_run_id = $run_id |
         .config = { path: $config_path, sha256: $config_hash }' \
        --arg created_at "$now" \
        --arg run_id "$run_id" \
        --arg config_path "$config_path" \
        --arg config_hash "$config_hash"
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

function enforce_status_config_match
    if not status_exists
        return 0
    end

    set -l status_path (status_get '.config.path')
    set -l status_hash (status_get '.config.sha256')

    if test -n "$status_path"; and test "$status_path" != "$CONFIG_FILE"
        log_error "status.json was created with a different config file: $status_path"
        log_error "Current config: $CONFIG_FILE"
        log_error "Delete status.json or use the same config file."
        exit 1
    end

    if test -n "$status_hash"
        set -l current_hash (config_file_hash)
        if test -z "$current_hash"
            log_error "Unable to hash config file for resume check"
            exit 1
        end

        if test "$status_hash" != "$current_hash"
            log_error "status.json config hash does not match current config file"
            log_error "Delete status.json or revert config changes before resuming."
            exit 1
        end
    end

    if test -z "$status_path"; and test -z "$status_hash"
        log_warning "status.json missing config metadata; resume safety check skipped"
    end
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
